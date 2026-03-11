import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

import 'fft_processor.dart';
import 'mav_native.dart';
import 'player_models.dart';
import 'player_controller_state.dart';

part 'visualizer_player_controller_playlist.dart';

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

/// High-level controller for audio playback, playlist management, and FFT data.
///
/// Supported platforms: Windows and Android.
class AudioVisualizerPlayerController extends ChangeNotifier
    with _PlaylistControllerMixin {
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

  @override
  String? _selectedPath;
  String? _error;
  @override
  Duration _duration = Duration.zero;
  @override
  Duration _position = Duration.zero;
  @override
  bool _isPlaying = false;
  
  double _volume = 1.0;
  PlayerState _playerState = PlayerState.idle;

  late final FftProcessor _fftProcessor;

  final StreamController<FftFrame> _rawFftController =
      StreamController<FftFrame>.broadcast();
  final StreamController<FftFrame> _optimizedFftController =
      StreamController<FftFrame>.broadcast();

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

  /// Current playback status.
  PlayerState get currentState => _playerState;

  /// Stream of raw FFT frames from native polling/events.
  Stream<FftFrame> get rawFftStream => _rawFftController.stream;

  /// Stream of smoothed/grouped FFT frames for visualization.
  Stream<FftFrame> get optimizedFftStream => _optimizedFftController.stream;

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
      _playerState = PlayerState.error;
      _emitPlaylistState();
      notifyListeners();
      return;
    }

    _playerState = PlayerState.buffering;
    _emitPlaylistState();

    // Ensure there's an active playlist for legacy usage
    if (!_playlistInternalLoad) {
      await _ensureActivePlaylist();
    }

    if (isWindows) {
      final native = _native;
      if (native == null) {
        _error = 'Controller is not initialized.';
        _playerState = PlayerState.error;
        _emitPlaylistState();
        notifyListeners();
        return;
      }
      final loadRc = native.loadAudioFile(path);
      if (loadRc != 0) {
        _error = 'Native load failed: $loadRc';
        _playerState = PlayerState.error;
        _emitPlaylistState();
        notifyListeners();
        return;
      }
      final openRc = native.openAudioForPlayback(path);
      if (openRc != 0) {
        _error = 'Native playback open failed: $openRc';
        _playerState = PlayerState.error;
        _emitPlaylistState();
        notifyListeners();
        return;
      }
      _selectedPath = path;
      _position = Duration.zero;
      _duration = Duration(milliseconds: native.getDurationMs());
      _isPlaying = false;
      _playerState = PlayerState.ready;
      native.playerSetVolume(_volume);
      _resetFftState();
      if (!_playlistInternalLoad) {
        _syncLegacySingleTrackPlaylist(path, duration: _duration);
      }
      _emitPlaylistState();
      notifyListeners();
      return;
    }

    final status = await Permission.microphone.status;
    if (!status.isGranted) {
      _error =
          'Microphone permission is required for Visualizer. Please call requestPermissions() first.';
      _playerState = PlayerState.error;
      _emitPlaylistState();
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
      _playerState = PlayerState.error;
      _emitPlaylistState();
      notifyListeners();
      return;
    }
    await _androidPlayerChannel.invokeMethod('setVolume', {'volume': _volume});
    final durationMs = await _androidCallInt('getDurationMs');
    _selectedPath = path;
    _position = Duration.zero;
    _duration = Duration(milliseconds: durationMs);
    _isPlaying = false;
    _playerState = PlayerState.ready;
    _resetFftState();
    if (!_playlistInternalLoad) {
      _syncLegacySingleTrackPlaylist(path, duration: _duration);
    }
    _emitPlaylistState();
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
        _playerState = PlayerState.error;
      } else {
        _isPlaying = true;
        _playerState = PlayerState.playing;
      }
      _emitPlaylistState();
      notifyListeners();
      return;
    }
    final rc = await _androidCallInt('play');
    if (rc != 0) {
      _error = 'Android player error: $rc';
      _playerState = PlayerState.error;
    } else {
      _isPlaying = true;
      _playerState = PlayerState.playing;
    }
    _emitPlaylistState();
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
        _playerState = PlayerState.error;
      } else {
        _isPlaying = false;
        _playerState = PlayerState.paused;
      }
      _emitPlaylistState();
      notifyListeners();
      return;
    }
    final rc = await _androidCallInt('pause');
    if (rc != 0) {
      _error = 'Android player error: $rc';
      _playerState = PlayerState.error;
    } else {
      _isPlaying = false;
      _playerState = PlayerState.paused;
    }
    _emitPlaylistState();
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
      _emitPlaylistState();
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
    _emitPlaylistState();
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
    _emitPlaylistState();
    notifyListeners();
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

      // Simple status derivation for recurring poll
      if (_isPlaying) {
        _playerState = PlayerState.playing;
      } else if (_selectedPath != null &&
          _position.inMilliseconds >= (_duration.inMilliseconds - 100)) {
        _playerState = PlayerState.completed;
      } else if (_selectedPath != null) {
        _playerState = PlayerState.paused;
      }

      _emitPlaylistState();
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

      if (_isPlaying) {
        _playerState = PlayerState.playing;
      } else if (_selectedPath != null &&
          _position.inMilliseconds >= (_duration.inMilliseconds - 250)) {
        _playerState = PlayerState.completed;
      } else if (_selectedPath != null) {
        _playerState = PlayerState.paused;
      }

      _emitPlaylistState();
      notifyListeners();
      await _handleAutoTransitionIfNeeded(wasPlaying: wasPlaying);
    } finally {
      _androidPollInFlight = false;
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
    _disposePlaylistState();
    super.dispose();
  }
}
