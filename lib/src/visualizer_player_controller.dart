import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

import 'mav_native.dart';

class FftFrame {
  const FftFrame({
    required this.position,
    required this.values,
    required this.isPlaying,
  });

  final Duration position;
  final List<double> values;
  final bool isPlaying;
}

enum FftAggregationMode {
  peak,
  mean,
  rms,
}

class VisualizerOptimizationOptions {
  const VisualizerOptimizationOptions({
    this.smoothingCoefficient = 0.55,
    this.gravityCoefficient = 1.2,
    this.logarithmicScale = 2.0,
    this.normalizationFloorDb = -70.0,
    this.aggregationMode = FftAggregationMode.peak,
    this.frequencyGroups = 32,
    this.targetFrameRate = 60.0,
  });

  final double smoothingCoefficient;
  final double gravityCoefficient;
  final double logarithmicScale;
  final double normalizationFloorDb;
  final FftAggregationMode aggregationMode;
  final int frequencyGroups;
  final double targetFrameRate;
}

class AudioVisualizerPlayerController extends ChangeNotifier {
  AudioVisualizerPlayerController({
    this.fftSize = 1024,
    this.analysisFrequencyHz = 30.0,
    this.visualOptions = const VisualizerOptimizationOptions(),
  })  : assert(fftSize > 0),
        assert(analysisFrequencyHz > 0),
        assert(visualOptions.frequencyGroups > 0),
        assert(visualOptions.targetFrameRate > 0) {
    _latestRawFft = const [];
    _latestOptimizedFft = List<double>.filled(visualOptions.frequencyGroups, 0.0);
    _optimizedState = List<double>.filled(visualOptions.frequencyGroups, 0.0);
    _interpFrom = List<double>.filled(visualOptions.frequencyGroups, 0.0);
    _interpTo = List<double>.filled(visualOptions.frequencyGroups, 0.0);
  }

  static const MethodChannel _androidPlayerChannel =
      MethodChannel('audio_visualizer_player/player');
  static const EventChannel _androidFftChannel =
      EventChannel('audio_visualizer_player/fft_bands');

  final int fftSize;
  final double analysisFrequencyHz;
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

  late List<double> _latestRawFft;
  late List<double> _latestOptimizedFft;
  late List<double> _optimizedState;
  late List<double> _interpFrom;
  late List<double> _interpTo;

  final StreamController<FftFrame> _rawFftController =
      StreamController<FftFrame>.broadcast();
  final StreamController<FftFrame> _optimizedFftController =
      StreamController<FftFrame>.broadcast();

  bool get isAndroid => Platform.isAndroid;
  bool get isWindows => Platform.isWindows;
  bool get isSupported => isAndroid || isWindows;
  bool get isInitialized => _initialized;
  String? get selectedPath => _selectedPath;
  String? get error => _error;
  Duration get duration => _duration;
  Duration get position => _position;
  bool get isPlaying => _isPlaying;
  double get volume => _volume;

  Stream<FftFrame> get rawFftStream => _rawFftController.stream;
  Stream<FftFrame> get optimizedFftStream => _optimizedFftController.stream;

  List<double> getRawFft() => List<double>.unmodifiable(_latestRawFft);
  List<double> getOptimizedFft() => List<double>.unmodifiable(_latestOptimizedFft);

  bool get _needOptimizedCompute => _optimizedFftController.hasListener;

  Duration get _analysisInterval =>
      Duration(microseconds: (1000000.0 / analysisFrequencyHz).round());
  Duration get _renderInterval =>
      Duration(microseconds: (1000000.0 / visualOptions.targetFrameRate).round());

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
      _androidFftSub = _androidFftChannel.receiveBroadcastStream().listen((event) {
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
    notifyListeners();
  }

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

  Future<void> pause() async {
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

  Future<void> seek(Duration target) async {
    if (_selectedPath == null) {
      return;
    }
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
    final rc = await _androidCallInt('seekMs', <String, dynamic>{'positionMs': ms});
    if (rc != 0) {
      _error = 'Android seek error: $rc';
    } else {
      _position = Duration(milliseconds: ms);
    }
    notifyListeners();
  }

  Future<void> setVolume(double volume) async {
    _volume = volume.clamp(0.0, 1.0);
    if (isWindows) {
      _native?.playerSetVolume(_volume);
    } else if (isAndroid) {
      await _androidPlayerChannel.invokeMethod('setVolume', {'volume': _volume});
    }
    notifyListeners();
  }

  FftFrame getCurrentRawFftFrame() => FftFrame(
        position: _position,
        values: List<double>.unmodifiable(_latestRawFft),
        isPlaying: _isPlaying,
      );

  FftFrame getCurrentOptimizedFftFrame() => FftFrame(
        position: _position,
        values: List<double>.unmodifiable(_latestOptimizedFft),
        isPlaying: _isPlaying,
      );

  void clearError({bool notify = true}) {
    _error = null;
    if (notify) {
      notifyListeners();
    }
  }

  Future<int> _androidCallInt(String method, [Map<String, dynamic>? args]) async {
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
    _interpMicros = (_interpMicros + _renderInterval.inMicroseconds).clamp(0, analysisMicros);
    final t = analysisMicros == 0 ? 1.0 : _interpMicros / analysisMicros;
    _latestOptimizedFft = List<double>.generate(
      visualOptions.frequencyGroups,
      (i) => _lerp(_interpFrom[i], _interpTo[i], t),
    );
    _emitOptimizedFftFrame();
  }

  Future<void> _pollPlaybackState() async {
    if (isWindows) {
      final native = _native;
      if (native == null) {
        return;
      }
      _position = Duration(milliseconds: native.playerGetPositionMs());
      _isPlaying = native.playerIsPlaying();
      notifyListeners();
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
    } finally {
      _androidPollInFlight = false;
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
      return List<double>.filled(groups, bins.first.clamp(0.0, double.infinity));
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

  double _lerp(double a, double b, double t) => a + ((b - a) * t.clamp(0.0, 1.0));

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
    if (_optimizedFftController.isClosed || !_optimizedFftController.hasListener) {
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
    _latestOptimizedFft = List<double>.filled(visualOptions.frequencyGroups, 0.0);
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
    super.dispose();
  }
}
