import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

import 'fft_processor.dart';
import 'mav_native.dart';

/// A single FFT frame emitted by the player.
///
/// Contains the playback [position], FFT [values], and whether the player
/// was [isPlaying] when this frame was produced.
class FftFrame {
  const FftFrame({
    required this.position,
    required this.values,
    required this.isPlaying,
  });

  /// Playback position associated with this frame.
  final Duration position;

  /// FFT magnitudes for this frame.
  final List<double> values;

  /// Whether playback was active when this frame was sampled.
  final bool isPlaying;
}

/// A track item used by playlist APIs.
class AudioTrack {
  const AudioTrack({
    required this.id,
    required this.uri,
    this.title,
    this.artist,
    this.album,
    this.duration,
    this.extras = const <String, Object?>{},
  });

  /// Stable unique track id.
  final String id;

  /// Audio URI/path understood by the plugin.
  final String uri;

  /// Optional display title.
  final String? title;

  /// Optional artist name.
  final String? artist;

  /// Optional album name.
  final String? album;

  /// Optional known duration.
  final Duration? duration;

  /// Optional custom metadata.
  final Map<String, Object?> extras;
}

/// Repeat behavior used by playlist playback.
enum RepeatMode { off, one, all }

/// Reason for a track transition.
enum PlaybackReason { user, autoNext, ended, playlistChanged }

/// Snapshot of current playlist playback state.
class PlaylistState {
  const PlaylistState({
    required this.items,
    required this.currentIndex,
    required this.shuffleEnabled,
    required this.repeatMode,
    required this.currentTrack,
  });

  /// Current list of tracks.
  final List<AudioTrack> items;

  /// Current index in [items], or `null` if nothing selected.
  final int? currentIndex;

  /// Whether shuffle order is enabled.
  final bool shuffleEnabled;

  /// Active repeat mode.
  final RepeatMode repeatMode;

  /// Currently selected track, or `null` when playlist is empty.
  final AudioTrack? currentTrack;
}

/// High-level controller for audio playback, playlist management, and FFT data.
///
/// Supported platforms: Windows and Android.
class AudioVisualizerPlayerController extends ChangeNotifier {
  /// Creates a player controller with FFT and visualization options.
  AudioVisualizerPlayerController({
    this.fftSize = 1024,
    this.analysisFrequencyHz = 30.0,
    VisualizerOptimizationOptions visualOptions =
        const VisualizerOptimizationOptions(),
  }) : assert(fftSize > 0),
       assert(analysisFrequencyHz > 0),
       assert(visualOptions.frequencyGroups > 0),
       assert(visualOptions.targetFrameRate > 0),
       assert(visualOptions.groupContrastExponent > 0) {
    _fftProcessor = FftProcessor(fftSize: fftSize, options: visualOptions);
  }

  static const MethodChannel _androidPlayerChannel = MethodChannel(
    'audio_visualizer_player/player',
  );
  static const EventChannel _androidFftChannel = EventChannel(
    'audio_visualizer_player/fft_bands',
  );

  /// FFT size requested from native analysis.
  final int fftSize;

  /// Analysis polling frequency in Hz.
  final double analysisFrequencyHz;

  /// Output smoothing/grouping options for visualization.
  VisualizerOptimizationOptions get visualOptions => _fftProcessor.options;

  MavNative? _native;
  StreamSubscription<dynamic>? _androidFftSub;
  Timer? _analysisTick;
  Timer? _renderTick;
  bool _initialized = false;
  bool _androidPollInFlight = false;
  int _lastAnalysisMicros = 0;

  String? _selectedPath;
  String? _error;
  Duration _duration = Duration.zero;
  Duration _position = Duration.zero;
  bool _isPlaying = false;
  double _volume = 1.0;

  final List<AudioTrack> _playlist = <AudioTrack>[];
  final List<int> _playOrder = <int>[];
  int? _currentIndex;
  int? _currentOrderCursor;
  bool _shuffleEnabled = false;
  RepeatMode _repeatMode = RepeatMode.off;
  math.Random _shuffleRandom = math.Random();
  bool _playlistInternalLoad = false;
  bool _autoTransitionInFlight = false;
  int _autoAdvanceSuppressedUntilMicros = 0;

  late final FftProcessor _fftProcessor;

  final StreamController<FftFrame> _rawFftController =
      StreamController<FftFrame>.broadcast();
  final StreamController<FftFrame> _optimizedFftController =
      StreamController<FftFrame>.broadcast();
  final StreamController<PlaylistState> _playlistStateController =
      StreamController<PlaylistState>.broadcast();
  late final ValueNotifier<PlaylistState> _playlistStateNotifier =
      ValueNotifier<PlaylistState>(_buildPlaylistState());

  /// Whether the current platform is Android.
  bool get isAndroid => Platform.isAndroid;

  /// Whether the current platform is Windows.
  bool get isWindows => Platform.isWindows;

  /// Whether this plugin supports the current platform.
  bool get isSupported => isAndroid || isWindows;

  /// Whether [initialize] has completed successfully.
  bool get isInitialized => _initialized;

  /// Selected audio path of the currently loaded track.
  String? get selectedPath => _selectedPath;

  /// Latest user-facing error message, if any.
  String? get error => _error;

  /// Duration of the currently loaded track.
  Duration get duration => _duration;

  /// Current playback position.
  Duration get position => _position;

  /// Whether playback is currently active.
  bool get isPlaying => _isPlaying;

  /// Output volume in range `0..1`.
  double get volume => _volume;

  /// Current playlist in logical order.
  List<AudioTrack> get playlist => List<AudioTrack>.unmodifiable(_playlist);

  /// Current selected track index in [playlist].
  int? get currentIndex => _currentIndex;

  /// Currently selected track, or `null` if playlist is empty.
  AudioTrack? get currentTrack =>
      _currentIndex == null ? null : _playlist[_currentIndex!];

  /// Whether shuffle playback order is enabled.
  bool get shuffleEnabled => _shuffleEnabled;

  /// Active repeat mode.
  RepeatMode get repeatMode => _repeatMode;

  /// Current playlist state snapshot.
  PlaylistState get playlistState => _buildPlaylistState();

  /// Value-listenable playlist state for UI binding.
  ValueListenable<PlaylistState> get playlistListenable =>
      _playlistStateNotifier;

  /// Stream of raw FFT frames from native polling/events.
  Stream<FftFrame> get rawFftStream => _rawFftController.stream;

  /// Stream of smoothed/grouped FFT frames for visualization.
  Stream<FftFrame> get optimizedFftStream => _optimizedFftController.stream;

  /// Stream of playlist state changes.
  Stream<PlaylistState> get playlistStream => _playlistStateController.stream;

  /// Returns latest raw FFT magnitudes.
  List<double> getRawFft() => _fftProcessor.latestRawFft;

  /// Returns latest optimized FFT magnitudes.
  List<double> getOptimizedFft() => _fftProcessor.latestOptimizedFft;

  bool get _needOptimizedCompute => _optimizedFftController.hasListener;

  Duration get _analysisInterval =>
      Duration(microseconds: (1000000.0 / analysisFrequencyHz).round());
  Duration get _renderInterval => Duration(
    microseconds: (1000000.0 / visualOptions.targetFrameRate).round(),
  );

  /// Requests required runtime permissions on Android.
  ///
  /// Returns `true` when permission is granted (or not required).
  Future<bool> requestPermissions() async {
    if (isAndroid) {
      final status = await Permission.microphone.request();
      if (status.isGranted) {
        clearError();
        return true;
      } else {
        _error = 'Microphone permission is required for Visualizer.';
        notifyListeners();
        return false;
      }
    }
    return true; // Not required for Windows
  }

  /// Initializes native playback/analyzer resources.
  Future<void> initialize() async {
    if (_initialized) {
      return;
    }
    if (!isSupported) {
      _error = 'Only Android/Windows are supported.';
      notifyListeners();
      return;
    }

    if (isWindows) {
      _native = MavNative.open();
      final rc = _native!.createFft(fftSize);
      if (rc != 0) {
        _error = 'Native FFT init failed: $rc';
        notifyListeners();
        return;
      }
    } else {
      _androidFftSub = _androidFftChannel.receiveBroadcastStream().listen((
        event,
      ) {
        if (event is! List<dynamic>) {
          return;
        }
        _fftProcessor.processAnalysis(
          List<double>.generate(
            event.length,
            (i) => (event[i] as num).toDouble(),
          ),
          0.0, // dtSec not strictly needed for raw update if not smoothing raw
        );
      });
    }

    _analysisTick = Timer.periodic(_analysisInterval, (_) => _onAnalysisTick());
    _renderTick = Timer.periodic(_renderInterval, (_) => _onRenderTick());
    _initialized = true;
    notifyListeners();
  }

  /// Loads a single audio file path for playback.
  ///
  /// This keeps backward compatibility with single-track usage and also syncs
  /// the internal playlist to one item when called directly.
  Future<void> loadFromPath(String path) async {
    clearError(notify: false);
    if (path.isEmpty) {
      _error = 'Selected file path is unavailable.';
      notifyListeners();
      return;
    }

    if (isWindows) {
      final native = _native;
      if (native == null) {
        _error = 'Controller is not initialized.';
        notifyListeners();
        return;
      }
      final loadRc = native.loadAudioFile(path);
      if (loadRc != 0) {
        _error = 'Native load failed: $loadRc';
        notifyListeners();
        return;
      }
      final openRc = native.openAudioForPlayback(path);
      if (openRc != 0) {
        _error = 'Native playback open failed: $openRc';
        notifyListeners();
        return;
      }
      _selectedPath = path;
      _position = Duration.zero;
      _duration = Duration(milliseconds: native.getDurationMs());
      _isPlaying = false;
      native.playerSetVolume(_volume);
      _resetFftState();
      if (!_playlistInternalLoad) {
        _syncLegacySingleTrackPlaylist(path, duration: _duration);
      }
      notifyListeners();
      return;
    }

    final status = await Permission.microphone.request();
    if (!status.isGranted) {
      _error = 'Microphone permission is required for Visualizer.';
      notifyListeners();
      return;
    }
    final rc = await _androidCallInt('loadAudio', <String, dynamic>{
      'path': path,
      'fftSize': fftSize,
      'analysisHz': analysisFrequencyHz,
    });
    if (rc != 0) {
      _error = 'Android load failed: $rc';
      notifyListeners();
      return;
    }
    await _androidPlayerChannel.invokeMethod('setVolume', {'volume': _volume});
    final durationMs = await _androidCallInt('getDurationMs');
    _selectedPath = path;
    _position = Duration.zero;
    _duration = Duration(milliseconds: durationMs);
    _isPlaying = false;
    _resetFftState();
    if (!_playlistInternalLoad) {
      _syncLegacySingleTrackPlaylist(path, duration: _duration);
    }
    notifyListeners();
  }

  /// Loads audio bytes by persisting them to a temporary file on Android.
  Future<void> loadFromBytes({
    required List<int> bytes,
    required String fileName,
  }) async {
    if (!isAndroid) {
      _error = 'loadFromBytes is only needed on Android.';
      notifyListeners();
      return;
    }
    if (bytes.isEmpty) {
      _error = 'Audio bytes are empty.';
      notifyListeners();
      return;
    }
    final tempDir = await getTemporaryDirectory();
    final safeName = (fileName.isNotEmpty ? fileName : 'picked_audio.bin')
        .replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
    final cached = File('${tempDir.path}/$safeName');
    await cached.writeAsBytes(bytes, flush: true);
    await loadFromPath(cached.path);
  }

  /// Plays when paused, pauses when playing.
  Future<void> togglePlayPause() async {
    if (_selectedPath == null) {
      return;
    }
    if (_isPlaying) {
      await pause();
    } else {
      await play();
    }
  }

  /// Starts playback of the currently loaded track.
  Future<void> play() async {
    if (isWindows) {
      final native = _native;
      if (native == null) {
        return;
      }
      final rc = native.playerPlay();
      if (rc != 0) {
        _error = 'Native player error: $rc';
      } else {
        _isPlaying = true;
      }
      notifyListeners();
      return;
    }
    final rc = await _androidCallInt('play');
    if (rc != 0) {
      _error = 'Android player error: $rc';
    } else {
      _isPlaying = true;
    }
    notifyListeners();
  }

  /// Pauses playback.
  Future<void> pause() async {
    _suppressAutoAdvanceFor(const Duration(milliseconds: 900));
    if (isWindows) {
      final native = _native;
      if (native == null) {
        return;
      }
      final rc = native.playerPause();
      if (rc != 0) {
        _error = 'Native player error: $rc';
      } else {
        _isPlaying = false;
      }
      notifyListeners();
      return;
    }
    final rc = await _androidCallInt('pause');
    if (rc != 0) {
      _error = 'Android player error: $rc';
    } else {
      _isPlaying = false;
    }
    notifyListeners();
  }

  /// Seeks within the currently loaded track.
  Future<void> seek(Duration target) async {
    if (_selectedPath == null) {
      return;
    }
    _suppressAutoAdvanceFor(const Duration(milliseconds: 600));
    final ms = target.inMilliseconds.clamp(0, _duration.inMilliseconds);
    if (isWindows) {
      final native = _native;
      if (native == null) {
        return;
      }
      final rc = native.playerSeekMs(ms);
      if (rc != 0) {
        _error = 'Native seek error: $rc';
      } else {
        _position = Duration(milliseconds: ms);
      }
      notifyListeners();
      return;
    }
    final rc = await _androidCallInt('seekMs', <String, dynamic>{
      'positionMs': ms,
    });
    if (rc != 0) {
      _error = 'Android seek error: $rc';
    } else {
      _position = Duration(milliseconds: ms);
    }
    notifyListeners();
  }

  /// Sets playback volume in range `0..1`.
  Future<void> setVolume(double volume) async {
    _volume = volume.clamp(0.0, 1.0);
    if (isWindows) {
      _native?.playerSetVolume(_volume);
    } else if (isAndroid) {
      await _androidPlayerChannel.invokeMethod('setVolume', {
        'volume': _volume,
      });
    }
    notifyListeners();
  }

  /// Replaces the playlist and selects [startIndex].
  ///
  /// When [autoPlay] is `true`, playback starts immediately.
  Future<void> setPlaylist(
    List<AudioTrack> items, {
    int startIndex = 0,
    bool autoPlay = false,
  }) async {
    if (items.isEmpty) {
      await clearPlaylist();
      return;
    }
    final clamped = startIndex.clamp(0, items.length - 1);
    _playlist
      ..clear()
      ..addAll(items);
    _currentIndex = clamped;
    _rebuildPlayOrder(keepCurrentAtFront: _shuffleEnabled);
    await _loadCurrentTrack(autoPlay: autoPlay);
    _emitPlaylistState();
    notifyListeners();
  }

  /// Adds one track to the end of playlist.
  Future<void> addTrack(AudioTrack track) async {
    await addTracks(<AudioTrack>[track]);
  }

  /// Adds multiple tracks to the end of playlist.
  Future<void> addTracks(List<AudioTrack> tracks) async {
    if (tracks.isEmpty) {
      return;
    }
    final wasEmpty = _playlist.isEmpty;
    _playlist.addAll(tracks);
    if (wasEmpty) {
      _currentIndex = 0;
      _rebuildPlayOrder(keepCurrentAtFront: _shuffleEnabled);
      await _loadCurrentTrack(autoPlay: false);
    } else {
      _rebuildPlayOrder(keepCurrentAtFront: _shuffleEnabled);
      _emitPlaylistState();
      notifyListeners();
    }
  }

  /// Inserts one track at [index].
  Future<void> insertTrack(int index, AudioTrack track) async {
    final target = index.clamp(0, _playlist.length);
    _playlist.insert(target, track);
    if (_currentIndex == null) {
      _currentIndex = 0;
      _rebuildPlayOrder(keepCurrentAtFront: _shuffleEnabled);
      await _loadCurrentTrack(autoPlay: false);
      return;
    }
    if (target <= _currentIndex!) {
      _currentIndex = _currentIndex! + 1;
    }
    _rebuildPlayOrder(keepCurrentAtFront: _shuffleEnabled);
    _emitPlaylistState();
    notifyListeners();
  }

  /// Removes the track at [index].
  Future<void> removeTrackAt(int index) async {
    if (index < 0 || index >= _playlist.length) {
      return;
    }
    final wasPlayingNow = _isPlaying;
    final removedCurrent = _currentIndex == index;
    _playlist.removeAt(index);
    if (_playlist.isEmpty) {
      await clearPlaylist();
      return;
    }
    if (removedCurrent) {
      final next = index.clamp(0, _playlist.length - 1);
      _currentIndex = next;
      _rebuildPlayOrder(keepCurrentAtFront: _shuffleEnabled);
      await _loadCurrentTrack(autoPlay: wasPlayingNow);
      return;
    }
    if (_currentIndex != null && index < _currentIndex!) {
      _currentIndex = _currentIndex! - 1;
    }
    _rebuildPlayOrder(keepCurrentAtFront: _shuffleEnabled);
    _emitPlaylistState();
    notifyListeners();
  }

  /// Removes the first track with matching [trackId].
  Future<void> removeTrackById(String trackId) async {
    final idx = _playlist.indexWhere((t) => t.id == trackId);
    if (idx < 0) {
      return;
    }
    await removeTrackAt(idx);
  }

  /// Moves a track from [fromIndex] to [toIndex].
  Future<void> moveTrack(int fromIndex, int toIndex) async {
    if (fromIndex < 0 || fromIndex >= _playlist.length) {
      return;
    }
    final boundedTo = toIndex.clamp(0, _playlist.length - 1);
    if (fromIndex == boundedTo) {
      return;
    }
    final moved = _playlist.removeAt(fromIndex);
    _playlist.insert(boundedTo, moved);

    if (_currentIndex != null) {
      var current = _currentIndex!;
      if (current == fromIndex) {
        current = boundedTo;
      } else if (fromIndex < current && boundedTo >= current) {
        current -= 1;
      } else if (fromIndex > current && boundedTo <= current) {
        current += 1;
      }
      _currentIndex = current;
    }
    _rebuildPlayOrder(keepCurrentAtFront: _shuffleEnabled);
    _emitPlaylistState();
    notifyListeners();
  }

  /// Clears playlist and resets playback state.
  Future<void> clearPlaylist() async {
    _playlist.clear();
    _playOrder.clear();
    _currentIndex = null;
    _currentOrderCursor = null;
    _selectedPath = null;
    _duration = Duration.zero;
    _position = Duration.zero;
    _isPlaying = false;
    _resetFftState();
    _emitPlaylistState();
    notifyListeners();
  }

  /// Switches to track at [index] and starts playback.
  ///
  /// Optional [position] seeks after loading.
  Future<void> playAt(int index, {Duration? position}) async {
    if (index < 0 || index >= _playlist.length) {
      return;
    }
    _currentIndex = index;
    _rebuildPlayOrder(keepCurrentAtFront: _shuffleEnabled);
    await _loadCurrentTrack(autoPlay: true, position: position);
  }

  /// Switches to track matching [trackId] and starts playback.
  Future<void> playById(String trackId, {Duration? position}) async {
    final idx = _playlist.indexWhere((t) => t.id == trackId);
    if (idx < 0) {
      return;
    }
    await playAt(idx, position: position);
  }

  /// Plays next track according to repeat/shuffle rules.
  ///
  /// Returns `false` if no next track is available.
  Future<bool> playNext({PlaybackReason reason = PlaybackReason.user}) async {
    if (_playlist.isEmpty) {
      return false;
    }
    if (_currentIndex == null) {
      await playAt(0);
      return true;
    }
    if (_repeatMode == RepeatMode.one && reason != PlaybackReason.user) {
      await seek(Duration.zero);
      await play();
      return true;
    }

    final next = _resolveAdjacentIndex(next: true);
    if (next == null) {
      return false;
    }
    _currentIndex = next;
    _syncOrderCursorFromCurrentIndex();
    final shouldPlay = reason == PlaybackReason.user || _isPlaying;
    await _loadCurrentTrack(autoPlay: shouldPlay);
    return true;
  }

  /// Plays previous track according to repeat/shuffle rules.
  ///
  /// Returns `false` if no previous track is available.
  Future<bool> playPrevious({
    PlaybackReason reason = PlaybackReason.user,
  }) async {
    if (_playlist.isEmpty) {
      return false;
    }
    if (_currentIndex == null) {
      await playAt(0);
      return true;
    }
    final prev = _resolveAdjacentIndex(next: false);
    if (prev == null) {
      return false;
    }
    _currentIndex = prev;
    _syncOrderCursorFromCurrentIndex();
    final shouldPlay = reason == PlaybackReason.user || _isPlaying;
    await _loadCurrentTrack(autoPlay: shouldPlay);
    return true;
  }

  /// Alias of [seek] for playlist-centric API naming.
  Future<void> seekInCurrent(Duration position) async {
    await seek(position);
  }

  /// Applies visualization tuning options at runtime.
  ///
  /// This can be called while playback is running.
  void updateVisualOptions(VisualizerOptimizationOptions options) {
    assert(options.frequencyGroups > 0);
    assert(options.targetFrameRate > 0);
    assert(options.groupContrastExponent > 0);

    final old = _fftProcessor.options;
    final frameRateChanged =
        (old.targetFrameRate - options.targetFrameRate).abs() > 1e-9;

    _fftProcessor.updateOptions(options);

    if (frameRateChanged && _initialized) {
      _restartRenderTick();
    }
    notifyListeners();
  }

  /// Patches one or more visualization option fields at runtime.
  void patchVisualOptions({
    double? smoothingCoefficient,
    double? gravityCoefficient,
    double? logarithmicScale,
    double? normalizationFloorDb,
    FftAggregationMode? aggregationMode,
    int? frequencyGroups,
    int? skipHighFrequencyGroups,
    double? targetFrameRate,
    double? groupContrastExponent,
  }) {
    updateVisualOptions(
      visualOptions.copyWith(
        smoothingCoefficient: smoothingCoefficient,
        gravityCoefficient: gravityCoefficient,
        logarithmicScale: logarithmicScale,
        normalizationFloorDb: normalizationFloorDb,
        aggregationMode: aggregationMode,
        frequencyGroups: frequencyGroups,
        skipHighFrequencyGroups: skipHighFrequencyGroups,
        targetFrameRate: targetFrameRate,
        groupContrastExponent: groupContrastExponent,
      ),
    );
  }

  /// Sets repeat mode.
  Future<void> setRepeatMode(RepeatMode mode) async {
    _repeatMode = mode;
    _emitPlaylistState();
    notifyListeners();
  }

  /// Enables/disables shuffle order.
  ///
  /// Provide [seed] for deterministic shuffle order.
  Future<void> setShuffleEnabled(bool enabled, {int? seed}) async {
    if (seed != null) {
      _shuffleRandom = math.Random(seed);
    }
    if (_shuffleEnabled == enabled) {
      return;
    }
    _shuffleEnabled = enabled;
    _rebuildPlayOrder(keepCurrentAtFront: _shuffleEnabled);
    _emitPlaylistState();
    notifyListeners();
  }

  /// Toggles shuffle mode.
  Future<void> toggleShuffle() async {
    await setShuffleEnabled(!_shuffleEnabled);
  }

  /// Current raw FFT frame snapshot.
  FftFrame getCurrentRawFftFrame() => FftFrame(
    position: _position,
    values: _fftProcessor.latestRawFft,
    isPlaying: _isPlaying,
  );

  /// Current optimized FFT frame snapshot.
  FftFrame getCurrentOptimizedFftFrame() => FftFrame(
    position: _position,
    values: _fftProcessor.latestOptimizedFft,
    isPlaying: _isPlaying,
  );

  /// Clears current [error].
  void clearError({bool notify = true}) {
    _error = null;
    if (notify) {
      notifyListeners();
    }
  }

  Future<int> _androidCallInt(
    String method, [
    Map<String, dynamic>? args,
  ]) async {
    final value = await _androidPlayerChannel.invokeMethod<int>(method, args);
    return value ?? 0;
  }

  Future<void> _onAnalysisTick() async {
    if (_selectedPath == null) {
      return;
    }
    await _pollPlaybackState();

    List<double> rawBins = const [];
    if (isWindows) {
      final native = _native;
      if (native == null) {
        return;
      }
      rawBins = native.getSpectrumAtMs(
        positionMs: _position.inMilliseconds,
        outCount: fftSize ~/ 2,
      );
    } else {
      rawBins = _fftProcessor.latestRawFft;
    }
    if (rawBins.isEmpty) {
      return;
    }
    if (!_isPlaying) {
      rawBins = List<double>.filled(rawBins.length, 0.0);
    }

    final nowMicros = DateTime.now().microsecondsSinceEpoch;
    final dtSec = _lastAnalysisMicros == 0
        ? _analysisInterval.inMicroseconds / 1000000.0
        : (nowMicros - _lastAnalysisMicros) / 1000000.0;
    _lastAnalysisMicros = nowMicros;

    _fftProcessor.processAnalysis(rawBins, dtSec);
    _emitRawFftFrame();
  }

  void _onRenderTick() {
    if (_selectedPath == null || !_needOptimizedCompute) {
      return;
    }
    _fftProcessor.processRender(
      _renderInterval.inMicroseconds,
      _analysisInterval.inMicroseconds,
    );
    _emitOptimizedFftFrame();
  }

  void _restartRenderTick() {
    _renderTick?.cancel();
    _renderTick = Timer.periodic(_renderInterval, (_) => _onRenderTick());
  }

  Future<void> _pollPlaybackState() async {
    final wasPlaying = _isPlaying;
    if (isWindows) {
      final native = _native;
      if (native == null) {
        return;
      }
      _position = Duration(milliseconds: native.playerGetPositionMs());
      _isPlaying = native.playerIsPlaying();
      notifyListeners();
      await _handleAutoTransitionIfNeeded(wasPlaying: wasPlaying);
      return;
    }
    if (_androidPollInFlight) {
      return;
    }
    _androidPollInFlight = true;
    try {
      final positionMs = await _androidCallInt('getPositionMs');
      final playing = await _androidCallInt('isPlaying');
      _position = Duration(milliseconds: positionMs);
      _isPlaying = playing == 1;
      notifyListeners();
      await _handleAutoTransitionIfNeeded(wasPlaying: wasPlaying);
    } finally {
      _androidPollInFlight = false;
    }
  }

  Future<void> _loadCurrentTrack({
    required bool autoPlay,
    Duration? position,
  }) async {
    final index = _currentIndex;
    if (index == null || index < 0 || index >= _playlist.length) {
      return;
    }
    final uri = _playlist[index].uri;
    _playlistInternalLoad = true;
    try {
      await loadFromPath(uri);
    } finally {
      _playlistInternalLoad = false;
    }
    if (position != null) {
      await seek(position);
    }
    if (autoPlay) {
      await play();
    }
    _emitPlaylistState();
    notifyListeners();
  }

  void _syncLegacySingleTrackPlaylist(String path, {Duration? duration}) {
    final existing = _playlist.length == 1 ? _playlist.first : null;
    final sameTrack = existing != null && existing.uri == path;
    if (sameTrack && _currentIndex == 0) {
      _emitPlaylistState();
      return;
    }
    final fileName = path.split(RegExp(r'[\\/]')).last;
    _playlist
      ..clear()
      ..add(
        AudioTrack(id: path, uri: path, title: fileName, duration: duration),
      );
    _currentIndex = 0;
    _rebuildPlayOrder(keepCurrentAtFront: _shuffleEnabled);
    _emitPlaylistState();
  }

  void _rebuildPlayOrder({required bool keepCurrentAtFront}) {
    _playOrder
      ..clear()
      ..addAll(List<int>.generate(_playlist.length, (i) => i));
    if (_playOrder.isEmpty) {
      _currentOrderCursor = null;
      return;
    }
    if (_shuffleEnabled) {
      _playOrder.shuffle(_shuffleRandom);
      if (keepCurrentAtFront && _currentIndex != null) {
        final idx = _playOrder.indexOf(_currentIndex!);
        if (idx > 0) {
          final current = _playOrder.removeAt(idx);
          _playOrder.insert(0, current);
        }
      }
    }
    _syncOrderCursorFromCurrentIndex();
  }

  void _syncOrderCursorFromCurrentIndex() {
    final ci = _currentIndex;
    if (ci == null || _playOrder.isEmpty) {
      _currentOrderCursor = null;
      return;
    }
    final pos = _playOrder.indexOf(ci);
    if (pos >= 0) {
      _currentOrderCursor = pos;
      return;
    }
    _playOrder.add(ci);
    _currentOrderCursor = _playOrder.length - 1;
  }

  int? _resolveAdjacentIndex({required bool next}) {
    if (_playlist.isEmpty) {
      return null;
    }
    _syncOrderCursorFromCurrentIndex();
    final cursor = _currentOrderCursor;
    if (cursor == null) {
      return 0;
    }
    final candidate = next ? cursor + 1 : cursor - 1;
    if (candidate >= 0 && candidate < _playOrder.length) {
      return _playOrder[candidate];
    }
    if (_repeatMode == RepeatMode.all) {
      return next ? _playOrder.first : _playOrder.last;
    }
    return null;
  }

  PlaylistState _buildPlaylistState() {
    final ci = _currentIndex;
    AudioTrack? track;
    if (ci != null && ci >= 0 && ci < _playlist.length) {
      track = _playlist[ci];
    }
    return PlaylistState(
      items: List<AudioTrack>.unmodifiable(_playlist),
      currentIndex: ci,
      shuffleEnabled: _shuffleEnabled,
      repeatMode: _repeatMode,
      currentTrack: track,
    );
  }

  void _emitPlaylistState() {
    final state = _buildPlaylistState();
    _playlistStateNotifier.value = state;
    if (_playlistStateController.hasListener &&
        !_playlistStateController.isClosed) {
      _playlistStateController.add(state);
    }
  }

  void _suppressAutoAdvanceFor(Duration duration) {
    _autoAdvanceSuppressedUntilMicros =
        DateTime.now().microsecondsSinceEpoch + duration.inMicroseconds;
  }

  Future<void> _handleAutoTransitionIfNeeded({required bool wasPlaying}) async {
    if (_autoTransitionInFlight) {
      return;
    }
    if (_selectedPath == null || _playlist.isEmpty) {
      return;
    }
    final now = DateTime.now().microsecondsSinceEpoch;
    if (now < _autoAdvanceSuppressedUntilMicros) {
      return;
    }
    final reachedEnd =
        _duration.inMilliseconds > 0 &&
        _position.inMilliseconds >= (_duration.inMilliseconds - 250);
    if (!wasPlaying || _isPlaying || !reachedEnd) {
      return;
    }
    _autoTransitionInFlight = true;
    try {
      if (_repeatMode == RepeatMode.one) {
        await seek(Duration.zero);
        await play();
        return;
      }
      final moved = await playNext(reason: PlaybackReason.ended);
      if (!moved) {
        _isPlaying = false;
        notifyListeners();
      }
    } finally {
      _autoTransitionInFlight = false;
    }
  }

  void _emitRawFftFrame() {
    if (_rawFftController.isClosed || !_rawFftController.hasListener) {
      return;
    }
    _rawFftController.add(
      FftFrame(
        position: _position,
        values: _fftProcessor.latestRawFft,
        isPlaying: _isPlaying,
      ),
    );
  }

  void _emitOptimizedFftFrame() {
    if (_optimizedFftController.isClosed ||
        !_optimizedFftController.hasListener) {
      return;
    }
    _optimizedFftController.add(
      FftFrame(
        position: _position,
        values: _fftProcessor.latestOptimizedFft,
        isPlaying: _isPlaying,
      ),
    );
  }

  void _resetFftState() {
    _fftProcessor.resetState();
    _lastAnalysisMicros = 0;
  }

  @override
  void dispose() {
    _analysisTick?.cancel();
    _renderTick?.cancel();
    _androidFftSub?.cancel();
    if (isWindows && _native != null) {
      _native!.dispose();
      _native = null;
    }
    if (isAndroid) {
      _androidPlayerChannel.invokeMethod<int>('dispose');
    }
    _rawFftController.close();
    _optimizedFftController.close();
    _playlistStateController.close();
    _playlistStateNotifier.dispose();
    super.dispose();
  }
}
