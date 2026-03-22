import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'player_models.dart';
import 'rust/api/simple_api.dart';

/// Manages equalizer and bass boost configuration.
class EqualizerController extends ChangeNotifier {
  EqualizerController({
    required AudioVisualizerParent parent,
  }) : _parent = parent;

  final AudioVisualizerParent _parent;

  static const int maxEqualizerBands = 20;
  static const double minFrequencyHz = 32.0;
  static const double maxFrequencyHz = 16000.0;
  static const double bassBoostFrequencyHz = 80.0;
  static const double bassBoostQ = 0.75;

  EqualizerConfig _config = _makeDefaultConfig();
  EqualizerConfig get config => _config;

  Future<void> initialize() async {
    try {
      _config = await getAudioEqualizerConfig();
      _notify();
    } catch (e) {
      debugPrint('Equalizer fallback to default: $e');
    }
  }

  Future<void> setConfig(EqualizerConfig config) async {
    final normalized = _normalizeConfig(config);
    try {
      await setAudioEqualizerConfig(config: normalized);
      _config = normalized;
      _notify();
    } catch (e) {
      debugPrint('Equalizer update failed: $e');
      rethrow;
    }
  }

  Future<void> setEnabled(bool enabled) async => setConfig(_copyConfig(enabled: enabled));

  Future<void> setBandCount(int bandCount) async => setConfig(_copyConfig(bandCount: bandCount));

  Future<void> setBandGain(int bandIndex, double gainDb) async {
    if (bandIndex < 0 || bandIndex >= maxEqualizerBands) return;
    final gains = Float32List.fromList(_config.bandGainsDb.toList());
    gains[bandIndex] = gainDb;
    await setConfig(_copyConfig(bandGainsDb: gains));
  }

  Future<void> setPreamp(double preampDb) async => setConfig(_copyConfig(preampDb: preampDb));

  Future<void> setBassBoost(double gainDb) async => setConfig(_copyConfig(bassBoostDb: gainDb));

  void resetDefaults() {
    setConfig(_makeDefaultConfig());
  }

  List<double> getBandCenters({int? bandCount}) {
    final count = (bandCount ?? _config.bandCount).clamp(0, maxEqualizerBands);
    if (count <= 0) return const [];
    if (count == 1) return const [1000.0];
    final ratio = maxFrequencyHz / minFrequencyHz;
    return List.generate(count, (i) => minFrequencyHz * math.pow(ratio, i / (count - 1)).toDouble(), growable: false);
  }

  static EqualizerConfig _makeDefaultConfig() => EqualizerConfig(
    enabled: false,
    bandCount: maxEqualizerBands,
    preampDb: 0.0,
    bassBoostDb: 0.0,
    bassBoostFrequencyHz: bassBoostFrequencyHz,
    bassBoostQ: bassBoostQ,
    bandGainsDb: Float32List(maxEqualizerBands),
  );

  EqualizerConfig _normalizeConfig(EqualizerConfig config) {
    final gains = Float32List(maxEqualizerBands);
    for (var i = 0; i < maxEqualizerBands; i++) {
        gains[i] = i < config.bandGainsDb.length ? config.bandGainsDb[i] : 0.0;
    }
    return EqualizerConfig(
      enabled: config.enabled,
      bandCount: config.bandCount.clamp(0, maxEqualizerBands),
      preampDb: config.preampDb,
      bassBoostDb: config.bassBoostDb,
      bassBoostFrequencyHz: config.bassBoostFrequencyHz,
      bassBoostQ: config.bassBoostQ,
      bandGainsDb: gains,
    );
  }

  EqualizerConfig _copyConfig({bool? enabled, int? bandCount, double? preampDb, double? bassBoostDb, Float32List? bandGainsDb}) {
    return EqualizerConfig(
      enabled: enabled ?? _config.enabled,
      bandCount: bandCount ?? _config.bandCount,
      preampDb: preampDb ?? _config.preampDb,
      bassBoostDb: bassBoostDb ?? _config.bassBoostDb,
      bassBoostFrequencyHz: _config.bassBoostFrequencyHz,
      bassBoostQ: _config.bassBoostQ,
      bandGainsDb: bandGainsDb ?? _config.bandGainsDb,
    );
  }

  void _notify() {
    notifyListeners();
    _parent.notifyListeners();
  }
}
