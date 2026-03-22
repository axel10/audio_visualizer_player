import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'player_models.dart';
import 'rust/api/simple_api.dart';

/// Manages the actual audio engine session and transitions.
class PlayerController extends ChangeNotifier {
  PlayerController({
    required AudioVisualizerParent parent,
  }) : _parent = parent;

  final AudioVisualizerParent _parent;

  String? _selectedPath;
  String? _error;
  Duration _duration = Duration.zero;
  Duration _position = Duration.zero;
  bool _isPlaying = false;
  double _volume = 1.0;
  
  Duration _fadeDuration = Duration.zero;
  FadeMode _fadeMode = FadeMode.sequential;
  int _fadeSequence = 0;
  bool _trackFadeTransitionActive = false;
  PlayerState _playerState = PlayerState.idle;
  DateTime _lastCommandTime = DateTime.fromMillisecondsSinceEpoch(0);

  // --- Getters ---
  String? get currentPath => _selectedPath;
  String? get error => _error;
  Duration get duration => _duration;
  Duration get position => _position;
  bool get isPlaying => _isPlaying;
  double get volume => _volume;
  PlayerState get currentState => _playerState;
  Duration get fadeDuration => _fadeDuration;
  FadeMode get fadeMode => _fadeMode;
  bool get isFadeActive => _trackFadeTransitionActive;
  int get fadeSequence => _fadeSequence;

  void nextFadeSequence() => _fadeSequence++;

  // --- Public Actions ---

  Future<void> performTransition({
    required String uri,
    required bool autoPlay,
    Duration? position,
    required void Function(bool progressing) onStateChanged,
  }) async {
    final switchingTracks = _selectedPath != null && _selectedPath != uri;
    
    PlaybackTransition strategy = const ImmediateTransition();

    if (switchingTracks && _fadeDuration > Duration.zero) {
      if (_fadeMode == FadeMode.crossfade && isPlaying && autoPlay && position == null) {
        strategy = CrossfadeTransition(duration: _fadeDuration);
      } else {
        strategy = SequentialFadeTransition(
          duration: _fadeDuration,
          targetVolume: _volume,
        );
      }
    }

    onStateChanged(true);
    try {
      await strategy.execute(
        player: this,
        uri: uri,
        autoPlay: autoPlay,
        position: position,
      );
    } finally {
      onStateChanged(false);
    }
  }

  Future<void> load(String path, {double? nativeVolume}) async {
    _error = null;
    if (path.isEmpty) {
      setError('Selected file path is unavailable.');
      return;
    }

    _playerState = PlayerState.buffering;
    _notify();

    try {
      await loadAudioFile(path: path);
      await applyNativeVolume(nativeVolume ?? _volume);
      final durationMs = await getAudioDurationMs();
      _selectedPath = path;
      _position = Duration.zero;
      _duration = Duration(milliseconds: durationMs.toInt());
      _lastCommandTime = DateTime.now();
      _isPlaying = false;
      _playerState = PlayerState.ready;
    } catch (e) {
      setError('Load failed: $e');
    }
    _notify();
  }

  Future<void> play() async {
    if (_selectedPath == null) return;

    if (_playerState == PlayerState.completed) {
      final handled = await _parent.handlePlayRequested();
      if (handled) return;
    }

    try {
      if (_playerState == PlayerState.completed) {
        await seek(Duration.zero);
      }
      await playAudio();
      _lastCommandTime = DateTime.now();
      _isPlaying = true;
      _playerState = PlayerState.playing;
    } catch (e) {
      setError('Play failed: $e');
    }
    _notify();
  }

  Future<void> pause() async {
    try {
      await pauseAudio();
      _lastCommandTime = DateTime.now();
      _isPlaying = false;
      _playerState = PlayerState.paused;
    } catch (e) {
      setError('Pause failed: $e');
    }
    _notify();
  }

  Future<void> togglePlayPause() async {
    if (_selectedPath == null) return;
    if (_isPlaying) {
      await pause();
    } else {
      await play();
    }
  }

  Future<void> seek(Duration target) async {
    if (_selectedPath == null) return;
    final ms = target.inMilliseconds.clamp(0, _duration.inMilliseconds);
    try {
      await seekAudioMs(positionMs: ms);
      _lastCommandTime = DateTime.now();
      _position = Duration(milliseconds: ms);
    } catch (e) {
      setError('Seek failed: $e');
    }
    _notify();
  }

  Future<void> setVolume(double volume) async {
    _volume = volume.clamp(0.0, 1.0);
    if (!_trackFadeTransitionActive) {
      await applyNativeVolume(_volume);
    }
    _notify();
  }

  void setFadeConfig({Duration? duration, FadeMode? mode}) {
    if (duration != null) _fadeDuration = duration;
    if (mode != null) _fadeMode = mode;
    _notify();
  }

  Future<void> applyNativeVolume(double volume) async {
    final clamped = volume.clamp(0.0, 1.0);
    await setAudioVolume(volume: clamped);
  }

  Future<bool> fadeNativeVolume({
    required double from,
    required double to,
    required Duration duration,
    required int sequence,
    bool followTargetVolume = false,
  }) async {
    if (duration <= Duration.zero) {
      if (_fadeSequence != sequence) return false;
      await applyNativeVolume(followTargetVolume ? _volume : to);
      return _fadeSequence == sequence;
    }

    final steps = math.max(1, (duration.inMilliseconds / 16).round());
    final stepDelay = Duration(microseconds: (duration.inMicroseconds / steps).round());

    for (var i = 1; i <= steps; i++) {
      if (_fadeSequence != sequence) return false;
      final progress = i / steps;
      final endVolume = followTargetVolume ? _volume : to;
      final nextVolume = from + ((endVolume - from) * progress);
      await applyNativeVolume(nextVolume);
      if (i < steps) {
        await Future<void>.delayed(stepDelay);
      }
    }
    return _fadeSequence == sequence;
  }

  void setFadeActive(bool active) {
    _trackFadeTransitionActive = active;
    _notify();
  }

  void stopPlayback() {
    _selectedPath = null;
    _position = Duration.zero;
    _duration = Duration.zero;
    _isPlaying = false;
    _playerState = PlayerState.idle;
    _notify();
  }

  // --- External Sync Interface ---

  void applySnapshot(String? path, Duration position, Duration duration, bool isPlaying, double nativeVolume) {
    if (DateTime.now().difference(_lastCommandTime) < const Duration(milliseconds: 500)) return;

    _selectedPath = path;
    _position = position;
    _duration = duration;
    _isPlaying = isPlaying;
    if (!_trackFadeTransitionActive) {
      _volume = nativeVolume;
    }
    
    if (_isPlaying) {
      _playerState = PlayerState.playing;
    } else if (_selectedPath != null && _duration > Duration.zero && _position.inMilliseconds >= (_duration.inMilliseconds - 250)) {
       _playerState = PlayerState.completed;
    } else if (_selectedPath != null) {
      _playerState = PlayerState.paused;
    }
    
    _notify();
  }

  void setError(String? message) {
    _error = message;
    if (message != null) _playerState = PlayerState.error;
    _notify();
  }

  void updatePosition(Duration position) {
    _position = position;
    if (_duration > Duration.zero && _position >= _duration - const Duration(milliseconds: 250)) {
      _isPlaying = false;
      _playerState = PlayerState.completed;
    }
    _notify();
  }

  void _notify() {
    notifyListeners();
    _parent.notifyListeners();
  }
}

/// Defines the strategy for transitioning between two audio tracks.
abstract class PlaybackTransition {
  const PlaybackTransition();
  Future<void> execute({
    required PlayerController player,
    required String uri,
    required bool autoPlay,
    Duration? position,
  });
}

class SequentialFadeTransition extends PlaybackTransition {
  const SequentialFadeTransition({required this.duration, required this.targetVolume});
  final Duration duration;
  final double targetVolume;

  @override
  Future<void> execute({required PlayerController player, required String uri, required bool autoPlay, Duration? position}) async {
    player.nextFadeSequence();
    final seq = player.fadeSequence;

    if (player.isPlaying) {
      player.setFadeActive(true);
      try {
        final fadedOut = await player.fadeNativeVolume(from: player.volume, to: 0.0, duration: duration, sequence: seq);
        if (!fadedOut) return;
      } finally {
        if (!autoPlay) player.setFadeActive(false);
      }
    }

    await player.load(uri, nativeVolume: autoPlay ? 0.0 : player.volume);
    if (player.fadeSequence != seq) return;
    if (position != null) await player.seek(position);

    if (autoPlay) {
      player.setFadeActive(true);
      try {
        await player.play();
        await player.fadeNativeVolume(from: 0.0, to: targetVolume, duration: duration, sequence: seq, followTargetVolume: true);
      } finally {
        player.setFadeActive(false);
      }
    }
  }
}

class CrossfadeTransition extends PlaybackTransition {
  const CrossfadeTransition({required this.duration});
  final Duration duration;

  @override
  Future<void> execute({required PlayerController player, required String uri, required bool autoPlay, Duration? position}) async {
    player.nextFadeSequence();
    final seq = player.fadeSequence;
    await crossfadeToAudioFile(path: uri, durationMs: duration.inMilliseconds);
    if (player.fadeSequence != seq) return;
    final durationMs = await getAudioDurationMs();
    player.applySnapshot(uri, Duration.zero, Duration(milliseconds: durationMs.toInt()), true, player.volume);
  }
}

class ImmediateTransition extends PlaybackTransition {
  const ImmediateTransition();
  @override
  Future<void> execute({required PlayerController player, required String uri, required bool autoPlay, Duration? position}) async {
    player.nextFadeSequence();
    await player.load(uri);
    if (position != null) await player.seek(position);
    if (autoPlay) await player.play();
  }
}
