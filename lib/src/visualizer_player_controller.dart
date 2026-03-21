import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'player_models.dart';
import 'playlist_models.dart';
import 'player_controller.dart';
import 'playlist_controller.dart';
import 'visualizer_controller.dart';
import 'rust/api/simple_api.dart';
import 'rust/frb_generated.dart';
import 'fft_processor.dart';

export 'player_controller.dart';
export 'playlist_controller.dart';
export 'visualizer_controller.dart';
export 'player_models.dart';
export 'playlist_models.dart';

/// The top-level modular controller for audio playback and visualization.
class AudioVisualizerPlayerController extends ChangeNotifier {
  AudioVisualizerPlayerController({
    this.fftSize = 1024,
    this.analysisFrequencyHz = 30.0,
    Duration fadeDuration = Duration.zero,
    FadeMode fadeMode = FadeMode.sequential,
    VisualizerOptimizationOptions visualOptions = const VisualizerOptimizationOptions(),
  }) {
    player = PlayerController(
      onNotifyParent: notifyListeners,
      onHandlePlayRequested: _handlePlayRequested,
    );
    player.setFadeConfig(duration: fadeDuration, mode: fadeMode);

    playlist = PlaylistController(
      onLoadTrack: _handleLoadTrack,
      onClearPlayback: _handleClearPlayback,
      onNotifyParent: notifyListeners,
    );

    visualizer = VisualizerController(
      fftSize: fftSize,
      visualOptions: visualOptions,
      getLatestFft: () => _latestFftCache,
      onNotifyParent: notifyListeners,
    );
  }

  final int fftSize;
  final double analysisFrequencyHz;

  late final PlayerController player;
  late final PlaylistController playlist;
  late final VisualizerController visualizer;
  List<double> _latestFftCache = const [];

  static bool _rustLibInitialized = false;
  bool _initialized = false;
  Timer? _analysisTick;
  Timer? _renderTick;
  StreamSubscription<PlaybackState>? _playbackStateSubscription;

  bool get isSupported => Platform.isAndroid || Platform.isWindows;
  bool get isInitialized => _initialized;

  PlayerControllerState get state => PlayerControllerState(
    position: player.position,
    duration: player.duration,
    volume: player.volume,
    currentState: player.currentState,
    playlists: playlist.playlists,
    shuffleEnabled: playlist.shuffleEnabled,
    playlistMode: playlist.mode,
    activePlaylist: playlist.activePlaylist,
    currentIndex: playlist.currentIndex,
    track: playlist.currentTrack,
  );

  Future<void> initialize() async {
    if (_initialized) return;
    if (!isSupported) {
      player.setError('Only Android/Windows are supported.');
      return;
    }

    if (!_rustLibInitialized) {
      try {
        await RustLib.init();
        _rustLibInitialized = true;
      } catch (e) {
        if (!e.toString().contains('Should not initialize flutter_rust_bridge twice')) {
          player.setError('Rust bridge init failed: $e');
          return;
        }
        _rustLibInitialized = true;
      }
    }

    _playbackStateSubscription = subscribePlaybackState().listen(
      _applyPlaybackStateSnapshot,
      onError: (e) => player.setError('Playback subscription failed: $e'),
    );

    _analysisTick = Timer.periodic(_analysisInterval, (_) => unawaited(_onAnalysisTick()));
    _renderTick = Timer.periodic(_renderInterval, (_) => _onRenderTick());
    
    visualizer.visualizerOutputManager.startAll();
    _initialized = true;
    notifyListeners();
  }

  @override
  void dispose() {
    _analysisTick?.cancel();
    _renderTick?.cancel();
    _playbackStateSubscription?.cancel();
    unawaited(disposeAudio());
    visualizer.dispose();
    player.dispose();
    playlist.dispose();
    super.dispose();
  }

  Future<void> _handleLoadTrack({required bool autoPlay, Duration? position}) async {
    final track = playlist.currentTrack;
    if (track == null) return;

    final previousPath = player.currentPath;
    final uri = track.uri;
    final switchingTracks = previousPath != null && previousPath != uri;
    
    final fadeDuration = player.fadeDuration;
    final fadeMode = player.fadeMode;
    final isPlaying = player.isPlaying;

    final shouldFade = switchingTracks && fadeDuration > Duration.zero;
    final shouldCrossfade = shouldFade && fadeMode == FadeMode.crossfade && isPlaying && autoPlay && position == null;
    final shouldSequentialFade = shouldFade && !shouldCrossfade;
    
    player.nextFadeSequence();
    final newSequence = player.fadeSequence;

    if (shouldSequentialFade && (isPlaying || autoPlay)) {
      player.setFadeActive(true);
    }

    try {
      if (shouldCrossfade) {
        await crossfadeToAudioFile(path: uri, durationMs: fadeDuration.inMilliseconds);
        if (player.fadeSequence != newSequence) return;
        
        final durationMs = await getAudioDurationMs();
        player.applySnapshot(uri, Duration.zero, Duration(milliseconds: durationMs.toInt()), true, player.volume);
        visualizer.resetState();
        notifyListeners();
        return;
      }

      if (shouldSequentialFade && isPlaying) {
        final fadedOut = await player.fadeNativeVolume(from: player.volume, to: 0.0, duration: fadeDuration, sequence: newSequence);
        if (!fadedOut) return;
      }

      await player.load(uri, nativeVolume: shouldSequentialFade && autoPlay ? 0.0 : player.volume);
      if (player.fadeSequence != newSequence) return;

      if (position != null) await player.seek(position);
      if (autoPlay) {
        await player.play();
        if (shouldSequentialFade) {
          await player.fadeNativeVolume(from: 0.0, to: player.volume, duration: fadeDuration, sequence: newSequence, followTargetVolume: true);
        }
      }
      visualizer.resetState();
    } finally {
      if (player.fadeSequence == newSequence) {
        player.setFadeActive(false);
      }
    }
  }

  Future<void> _handleClearPlayback() async {
    player.stopPlayback();
    visualizer.resetState();
  }

  Duration get _analysisInterval => Duration(microseconds: (1000000.0 / analysisFrequencyHz).round());
  Duration get _renderInterval => Duration(microseconds: (1000000.0 / visualizer.options.targetFrameRate).round());

  Future<void> _onAnalysisTick() async {
    await _refreshLatestFftCache();
    visualizer.processAnalysisTick(player.isPlaying, player.position);
  }

  void _onRenderTick() {
    _advanceLocalPosition();
    visualizer.processRenderTick(_renderInterval.inMicroseconds, _analysisInterval.inMicroseconds);
  }

  void _advanceLocalPosition() {
    if (!player.isPlaying || player.currentPath == null) return;
    final nextPosition = player.position + _renderInterval;
    player.updatePosition(nextPosition);

    if (player.currentState == PlayerState.completed) {
      unawaited(_handleAutoTransition());
    }
  }

  void _applyPlaybackStateSnapshot(PlaybackState state) {
    player.applySnapshot(
      state.path,
      Duration(milliseconds: state.positionMs.toInt()),
      Duration(milliseconds: state.durationMs.toInt()),
      state.isPlaying,
      state.volume.clamp(0.0, 1.0),
    );
    unawaited(_handleAutoTransition());
  }

  Future<void> _handleAutoTransition() async {
    if (player.currentState != PlayerState.completed) return;
    if (playlist.mode == PlaylistMode.single) return;
    
    final hasNext = playlist.resolveAdjacentIndex(next: true);
    if (hasNext != null) {
      await playlist.setActivePlaylist(playlist.activePlaylistId!, startIndex: hasNext, autoPlay: true);
    }
  }

  Future<bool> _handlePlayRequested() async {
    if (playlist.items.isEmpty) return false;

    if (playlist.mode == PlaylistMode.queue) {
      final hasNext = playlist.resolveAdjacentIndex(next: true);
      if (hasNext == null && playlist.activePlaylistId != null) {
        await playlist.setActivePlaylist(
          playlist.activePlaylistId!,
          startIndex: 0,
          autoPlay: true,
        );
        return true;
      }
    }
    return false;
  }

  Future<void> _refreshLatestFftCache() async {
    try {
      _latestFftCache = (await getLatestFft()).map((value) => value.toDouble()).toList(growable: false);
    } catch (e) {
      player.setError('FFT fetch failed: $e');
      _latestFftCache = const [];
    }
  }

  Future<List<double>> getWaveform({required int expectedChunks, int sampleStride = 1, String? filePath}) async {
    final targetPath = filePath ?? player.currentPath;
    if (targetPath == null) return const [];
    try {
      final clampedStride = sampleStride < 1 ? 1 : sampleStride;
      final data = (filePath != null) 
          ? await extractWaveformForPath(path: filePath, expectedChunks: BigInt.from(expectedChunks), sampleStride: BigInt.from(clampedStride))
          : await extractLoadedWaveform(expectedChunks: BigInt.from(expectedChunks), sampleStride: BigInt.from(clampedStride));
      return data.toList();
    } catch (e) {
      player.setError('Waveform failed: $e');
      return const [];
    }
  }
}
