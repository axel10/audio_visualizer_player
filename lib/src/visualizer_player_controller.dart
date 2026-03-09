import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

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

/// Aggregation strategy used when compressing FFT bins into visual groups.
enum FftAggregationMode { peak, mean, rms }

/// Runtime options for FFT smoothing and visualization output.
class VisualizerOptimizationOptions {
  const VisualizerOptimizationOptions({
    // Higher => more stable bars, lower => quicker response.
    this.smoothingCoefficient = 0.55,
    // Higher => bars fall faster after peaks.
    this.gravityCoefficient = 1.2,
    // >1.0 boosts low-level details for quiet bands.
    this.logarithmicScale = 2.0,
    // Relative noise floor (dB) for normalization.
    this.normalizationFloorDb = -70.0,
    this.aggregationMode = FftAggregationMode.peak,
    // Number of output bars.
    this.frequencyGroups = 32,
    this.targetFrameRate = 60.0,
    // 1.0 keeps original contrast; >1.0 increases per-group separation.
    this.groupContrastExponent = 1.35,
  });

  /// Temporal smoothing factor in range `0..1` (higher = smoother).
  ///
  /// Use this when bars are too jittery.
  /// Typical range: `0.45..0.85`.
  final double smoothingCoefficient;

  /// Fall speed when magnitudes drop (higher = faster drop).
  ///
  /// Use this when peaks linger too long.
  /// Typical range: `0.8..3.0`.
  final double gravityCoefficient;

  /// Log scaling strength for normalized values.
  ///
  /// Use this to make quieter details more visible.
  /// Typical range: `1.0..4.0`.
  final double logarithmicScale;

  /// dB floor used during normalization.
  ///
  /// Less negative (e.g. `-50`) => punchier dynamics.
  /// More negative (e.g. `-90`) => smoother output.
  /// Typical range: `-90..-45`.
  final double normalizationFloorDb;

  /// Bin aggregation mode when reducing FFT bins.
  ///
  /// - [FftAggregationMode.peak]: strongest transient feel.
  /// - [FftAggregationMode.mean]: smooth average energy.
  /// - [FftAggregationMode.rms]: balanced loudness feel.
  final FftAggregationMode aggregationMode;

  /// Number of output visual frequency groups.
  ///
  /// Higher values give finer detail but more visual noise.
  /// Typical range: `24..96`.
  final int frequencyGroups;

  /// Target visual frame rate for interpolated output.
  ///
  /// Typical range: `30..120`.
  final double targetFrameRate;

  /// Extra contrast control for grouped bars.
  ///
  /// This option can increase the comparison between each group:
  /// - `1.0`: no extra contrast.
  /// - `>1.0`: strong groups become stronger, weak groups become weaker.
  /// - `<1.0`: differences are compressed.
  ///
  /// Typical range: `1.1..2.0`.
  final double groupContrastExponent;
}

/// High-level controller for audio playback, playlist management, and FFT data.
///
/// Supported platforms: Windows and Android.
class AudioVisualizerPlayerController extends ChangeNotifier {
  /// Creates a player controller with FFT and visualization options.
  AudioVisualizerPlayerController({
    this.fftSize = 1024,
    this.analysisFrequencyHz = 30.0,
    this.visualOptions = const VisualizerOptimizationOptions(),
  }) : assert(fftSize > 0),
       assert(analysisFrequencyHz > 0),
       assert(visualOptions.frequencyGroups > 0),
       assert(visualOptions.targetFrameRate > 0),
       assert(visualOptions.groupContrastExponent > 0) {
    _latestRawFft = const [];
    _latestOptimizedFft = List<double>.filled(
      visualOptions.frequencyGroups,
      0.0,
    );
    _optimizedState = List<double>.filled(visualOptions.frequencyGroups, 0.0);
    _interpFrom = List<double>.filled(visualOptions.frequencyGroups, 0.0);
    _interpTo = List<double>.filled(visualOptions.frequencyGroups, 0.0);
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
  final VisualizerOptimizationOptions visualOptions;

  MavNative? _native;
  StreamSubscription<dynamic>? _androidFftSub;
  Timer? _analysisTick;
  Timer? _renderTick;
  bool _initialized = false;
  bool _androidPollInFlight = false;
  int _lastAnalysisMicros = 0;
  int _interpMicros = 0;

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

  late List<double> _latestRawFft;
  late List<double> _latestOptimizedFft;
  late List<double> _optimizedState;
  late List<double> _interpFrom;
  late List<double> _interpTo;

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
  List<double> getRawFft() => List<double>.unmodifiable(_latestRawFft);

  /// Returns latest optimized FFT magnitudes.
  List<double> getOptimizedFft() =>
      List<double>.unmodifiable(_latestOptimizedFft);

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
        _latestRawFft = List<double>.generate(
          event.length,
          (i) => (event[i] as num).toDouble(),
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
    values: List<double>.unmodifiable(_latestRawFft),
    isPlaying: _isPlaying,
  );

  /// Current optimized FFT frame snapshot.
  FftFrame getCurrentOptimizedFftFrame() => FftFrame(
    position: _position,
    values: List<double>.unmodifiable(_latestOptimizedFft),
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
      rawBins = _latestRawFft;
    }
    if (rawBins.isEmpty) {
      return;
    }
    if (!_isPlaying) {
      rawBins = List<double>.filled(rawBins.length, 0.0);
    }

    _latestRawFft = rawBins;
    _emitRawFftFrame();

    if (!_needOptimizedCompute) {
      return;
    }

    final nowMicros = DateTime.now().microsecondsSinceEpoch;
    final dtSec = _lastAnalysisMicros == 0
        ? _analysisInterval.inMicroseconds / 1000000.0
        : (nowMicros - _lastAnalysisMicros) / 1000000.0;
    _lastAnalysisMicros = nowMicros;

    final grouped = _groupBins(
      rawBins,
      visualOptions.frequencyGroups,
      visualOptions.aggregationMode,
    );
    final normalized = _normalizeAndScale(
      grouped,
      visualOptions.logarithmicScale,
      visualOptions.normalizationFloorDb,
      visualOptions.groupContrastExponent,
    );
    final optimized = _applySmoothingAndGravity(
      previous: _optimizedState,
      next: normalized,
      smoothing: visualOptions.smoothingCoefficient,
      gravity: visualOptions.gravityCoefficient,
      dtSec: dtSec,
    );

    _optimizedState = optimized;
    _interpFrom = List<double>.from(_latestOptimizedFft);
    _interpTo = List<double>.from(_optimizedState);
    _interpMicros = 0;
  }

  void _onRenderTick() {
    if (_selectedPath == null || !_needOptimizedCompute) {
      return;
    }
    final analysisMicros = _analysisInterval.inMicroseconds;
    _interpMicros = (_interpMicros + _renderInterval.inMicroseconds).clamp(
      0,
      analysisMicros,
    );
    final t = analysisMicros == 0 ? 1.0 : _interpMicros / analysisMicros;
    _latestOptimizedFft = List<double>.generate(
      visualOptions.frequencyGroups,
      (i) => _lerp(_interpFrom[i], _interpTo[i], t),
    );
    _emitOptimizedFftFrame();
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

  List<double> _groupBins(
    List<double> bins,
    int groups,
    FftAggregationMode aggregationMode,
  ) {
    if (bins.isEmpty) {
      return List<double>.filled(groups, 0.0);
    }
    if (bins.length <= 2) {
      return List<double>.filled(
        groups,
        bins.first.clamp(0.0, double.infinity),
      );
    }

    final out = List<double>.filled(groups, 0.0);
    final binCount = bins.length;

    final boundaries = List<int>.filled(groups + 1, 1);
    boundaries[0] = 1;
    boundaries[groups] = binCount;
    for (var i = 1; i < groups; i++) {
      final t = i / groups;
      boundaries[i] = (math.pow(binCount.toDouble(), t).toDouble() - 1.0)
          .round()
          .clamp(1, binCount - 1);
    }
    for (var i = 1; i <= groups; i++) {
      if (boundaries[i] <= boundaries[i - 1]) {
        boundaries[i] = (boundaries[i - 1] + 1).clamp(1, binCount);
      }
    }
    boundaries[groups] = binCount;

    for (var g = 0; g < groups; g++) {
      final start = boundaries[g];
      final end = boundaries[g + 1];
      if (end <= start) {
        out[g] = 0.0;
        continue;
      }
      var acc = 0.0;
      var peak = 0.0;
      for (var i = start; i < end; i++) {
        final v = bins[i];
        if (v > peak) {
          peak = v;
        }
        acc += v;
      }
      final count = (end - start).toDouble();
      switch (aggregationMode) {
        case FftAggregationMode.peak:
          out[g] = peak;
          break;
        case FftAggregationMode.mean:
          out[g] = acc / count;
          break;
        case FftAggregationMode.rms:
          var square = 0.0;
          for (var i = start; i < end; i++) {
            final v = bins[i];
            square += v * v;
          }
          out[g] = math.sqrt(square / count);
          break;
      }
    }
    return out;
  }

  List<double> _normalizeAndScale(
    List<double> grouped,
    double logScale,
    double normalizationFloorDb,
    double contrastExponent,
  ) {
    final out = List<double>.filled(grouped.length, 0.0);
    var framePeak = 0.0;
    for (final v in grouped) {
      if (v > framePeak) {
        framePeak = v;
      }
    }
    if (framePeak <= 1e-9) {
      return out;
    }
    final ref = framePeak;
    final noiseFloorDb = normalizationFloorDb.clamp(-120.0, -10.0);
    final invRange = 1.0 / -noiseFloorDb;

    for (var i = 0; i < grouped.length; i++) {
      final ratio = (grouped[i] + 1e-9) / ref;
      final dbRelative = 20.0 * math.log(ratio) / math.ln10;
      var normalized = (dbRelative - noiseFloorDb) * invRange;
      normalized = normalized.clamp(0.0, 1.0);
      if (logScale > 1.0) {
        final k = logScale - 1.0;
        normalized = math.log(1.0 + normalized * k) / math.log(1.0 + k);
      }
      final ce = contrastExponent.clamp(0.1, 6.0);
      if (ce != 1.0) {
        normalized = math.pow(normalized, ce).toDouble();
      }
      out[i] = normalized;
    }
    return out;
  }

  List<double> _applySmoothingAndGravity({
    required List<double> previous,
    required List<double> next,
    required double smoothing,
    required double gravity,
    required double dtSec,
  }) {
    final out = List<double>.filled(next.length, 0.0);
    final s = smoothing.clamp(0.0, 0.99);
    final dropStep = (gravity.clamp(0.0, 10.0)) * dtSec;
    for (var i = 0; i < next.length; i++) {
      final oldV = i < previous.length ? previous[i] : 0.0;
      final newV = next[i];
      var candidate = newV;
      if (newV < oldV) {
        candidate = math.max(newV, oldV - dropStep);
      }
      out[i] = (oldV * s) + (candidate * (1.0 - s));
    }
    return out;
  }

  double _lerp(double a, double b, double t) =>
      a + ((b - a) * t.clamp(0.0, 1.0));

  void _emitRawFftFrame() {
    if (_rawFftController.isClosed || !_rawFftController.hasListener) {
      return;
    }
    _rawFftController.add(
      FftFrame(
        position: _position,
        values: List<double>.unmodifiable(_latestRawFft),
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
        values: List<double>.unmodifiable(_latestOptimizedFft),
        isPlaying: _isPlaying,
      ),
    );
  }

  void _resetFftState() {
    _latestRawFft = const [];
    _latestOptimizedFft = List<double>.filled(
      visualOptions.frequencyGroups,
      0.0,
    );
    _optimizedState = List<double>.filled(visualOptions.frequencyGroups, 0.0);
    _interpFrom = List<double>.filled(visualOptions.frequencyGroups, 0.0);
    _interpTo = List<double>.filled(visualOptions.frequencyGroups, 0.0);
    _lastAnalysisMicros = 0;
    _interpMicros = 0;
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
