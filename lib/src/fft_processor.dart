import 'dart:math' as math;

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
    // Number of high frequency groups to skip.
    this.skipHighFrequencyGroups = 0,
    // Target visual frame rate for interpolated output.
    this.targetFrameRate = 60.0,
    // 1.0 keeps original contrast; >1.0 increases per-group separation.
    this.groupContrastExponent = 1.35,
    // Final output multiplier applied to optimized values.
    this.overallMultiplier = 1.0,
  });

  /// Temporal smoothing factor in range `0..1` (higher = smoother).
  final double smoothingCoefficient;

  /// Fall speed when magnitudes drop (higher = faster drop).
  final double gravityCoefficient;

  /// Log scaling strength for normalized values.
  final double logarithmicScale;

  /// dB floor used during normalization.
  final double normalizationFloorDb;

  /// Bin aggregation mode when reducing FFT bins.
  final FftAggregationMode aggregationMode;

  /// Number of output visual frequency groups.
  final int frequencyGroups;

  /// Number of high frequency groups to skip from the visual output.
  final int skipHighFrequencyGroups;

  /// Target visual frame rate for interpolated output.
  final double targetFrameRate;

  /// Extra contrast control for grouped bars.
  final double groupContrastExponent;

  /// Final multiplier applied to optimized output values.
  final double overallMultiplier;

  VisualizerOptimizationOptions copyWith({
    double? smoothingCoefficient,
    double? gravityCoefficient,
    double? logarithmicScale,
    double? normalizationFloorDb,
    FftAggregationMode? aggregationMode,
    int? frequencyGroups,
    int? skipHighFrequencyGroups,
    double? targetFrameRate,
    double? groupContrastExponent,
    double? overallMultiplier,
  }) => VisualizerOptimizationOptions(
    smoothingCoefficient: smoothingCoefficient ?? this.smoothingCoefficient,
    gravityCoefficient: gravityCoefficient ?? this.gravityCoefficient,
    logarithmicScale: logarithmicScale ?? this.logarithmicScale,
    normalizationFloorDb: normalizationFloorDb ?? this.normalizationFloorDb,
    aggregationMode: aggregationMode ?? this.aggregationMode,
    frequencyGroups: frequencyGroups ?? this.frequencyGroups,
    skipHighFrequencyGroups:
        skipHighFrequencyGroups ?? this.skipHighFrequencyGroups,
    targetFrameRate: targetFrameRate ?? this.targetFrameRate,
    groupContrastExponent: groupContrastExponent ?? this.groupContrastExponent,
    overallMultiplier: overallMultiplier ?? this.overallMultiplier,
  );
}

/// Handles FFT processing, including grouping, normalization, smoothing, and interpolation.
class FftProcessor {
  FftProcessor({
    required this.fftSize,
    VisualizerOptimizationOptions options =
        const VisualizerOptimizationOptions(),
  }) : _options = options {
    resetState();
  }

  final int fftSize;
  VisualizerOptimizationOptions _options;
  VisualizerOptimizationOptions get options => _options;

  late List<double> _latestRawFft;
  late List<double> _latestOptimizedFft;
  late List<double> _optimizedState;
  late List<double> _interpFrom;
  late List<double> _interpTo;
  int _interpMicros = 0;

  List<double> get latestRawFft => _latestRawFft;
  List<double> get latestOptimizedFft => _latestOptimizedFft;

  void updateOptions(VisualizerOptimizationOptions newOptions) {
    final groupsChanged =
        _options.frequencyGroups != newOptions.frequencyGroups;
    _options = newOptions;

    if (groupsChanged) {
      _latestOptimizedFft = _resampleFftState(
        _latestOptimizedFft,
        _options.frequencyGroups,
      );
      _optimizedState = _resampleFftState(
        _optimizedState,
        _options.frequencyGroups,
      );
      _interpFrom = _resampleFftState(_interpFrom, _options.frequencyGroups);
      _interpTo = List<double>.from(_optimizedState);
      _interpMicros = 0;
    }
  }

  void processAnalysis(List<double> rawBins, double dtSec) {
    _latestRawFft = rawBins;
    if (rawBins.isEmpty) return;

    final grouped = _groupBins(
      rawBins,
      _options.frequencyGroups,
      _options.aggregationMode,
      _options.skipHighFrequencyGroups,
    );
    final normalized = _normalizeAndScale(
      grouped,
      _options.logarithmicScale,
      _options.normalizationFloorDb,
      _options.groupContrastExponent,
    );
    final optimized = _applySmoothingAndGravity(
      previous: _optimizedState,
      next: normalized,
      smoothing: _options.smoothingCoefficient,
      gravity: _options.gravityCoefficient,
      dtSec: dtSec,
    );

    _interpFrom = List<double>.from(_optimizedState);
    _optimizedState = optimized;
    _interpTo = List<double>.from(_optimizedState);
    _interpMicros = 0;
  }

  void processRender(int elapsedMicros, int analysisIntervalMicros) {
    _interpMicros = (_interpMicros + elapsedMicros).clamp(
      0,
      analysisIntervalMicros,
    );
    final t = analysisIntervalMicros == 0
        ? 1.0
        : _interpMicros / analysisIntervalMicros;
    final outputMultiplier = _options.overallMultiplier;

    _latestOptimizedFft = List<double>.generate(
      _options.frequencyGroups,
      (i) => _lerp(_interpFrom[i], _interpTo[i], t) * outputMultiplier,
    );
  }

  void resetState() {
    _latestRawFft = const [];
    _latestOptimizedFft = List<double>.filled(_options.frequencyGroups, 0.0);
    _optimizedState = List<double>.filled(_options.frequencyGroups, 0.0);
    _interpFrom = List<double>.filled(_options.frequencyGroups, 0.0);
    _interpTo = List<double>.filled(_options.frequencyGroups, 0.0);
    _interpMicros = 0;
  }

  List<double> _groupBins(
    List<double> bins,
    int groups,
    FftAggregationMode aggregationMode,
    int skipHighFrequencyGroups,
  ) {
    if (bins.isEmpty) return List<double>.filled(groups, 0.0);
    final totalGroups = (groups + skipHighFrequencyGroups).clamp(groups, 512);
    final binCount = bins.length;
    final out = List<double>.filled(groups, 0.0);

    final boundaries = List<int>.filled(totalGroups + 1, 1);
    boundaries[0] = 1;
    boundaries[totalGroups] = binCount;
    for (var i = 1; i < totalGroups; i++) {
      final t = i / totalGroups;
      boundaries[i] = (math.pow(binCount.toDouble(), t).toDouble() - 1.0)
          .round()
          .clamp(1, binCount - 1);
    }
    for (var i = 1; i <= totalGroups; i++) {
      if (boundaries[i] <= boundaries[i - 1]) {
        boundaries[i] = (boundaries[i - 1] + 1).clamp(1, binCount);
      }
    }
    boundaries[totalGroups] = binCount;

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
        if (v > peak) peak = v;
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
      if (v > framePeak) framePeak = v;
    }
    if (framePeak <= 1e-9) return out;

    final ref = (fftSize / 2.0).clamp(1.0, double.infinity);
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

  List<double> _resampleFftState(List<double> source, int targetLength) {
    if (targetLength <= 0) return const <double>[];
    if (source.isEmpty) return List<double>.filled(targetLength, 0.0);
    if (source.length == targetLength) return List<double>.from(source);
    if (targetLength == 1) return <double>[source.first];

    final out = List<double>.filled(targetLength, 0.0);
    final maxSrc = source.length - 1;
    for (var i = 0; i < targetLength; i++) {
      final pos = (i * maxSrc) / (targetLength - 1);
      final left = pos.floor();
      final right = pos.ceil().clamp(0, maxSrc);
      if (left == right) {
        out[i] = source[left];
      } else {
        final t = pos - left;
        out[i] = _lerp(source[left], source[right], t);
      }
    }
    return out;
  }

  double _lerp(double a, double b, double t) =>
      a + ((b - a) * t.clamp(0.0, 1.0));
}
