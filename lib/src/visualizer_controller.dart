import 'dart:async';

import 'package:flutter/foundation.dart';

import 'fft_frame.dart';
import 'fft_processor.dart';
import 'player_models.dart';
import 'visualizer_output_config.dart';
import 'visualizer_output_stream.dart';
import 'visualizer_output_manager.dart';

/// Manages FFT analysis and visualization output streams.
class VisualizerController extends ChangeNotifier {
  VisualizerController({
    required int fftSize,
    VisualizerOptimizationOptions visualOptions = const VisualizerOptimizationOptions(),
    required List<double> Function() getLatestFft,
    required AudioVisualizerParent parent,
  }) : _getLatestFft = getLatestFft,
       _parent = parent {
    _fftProcessor = FftProcessor(fftSize: fftSize, options: visualOptions);
    _initVisualizerOutputManager();
  }

  final List<double> Function() _getLatestFft;
  final AudioVisualizerParent _parent;

  late final FftProcessor _fftProcessor;
  late final VisualizerOutputManager visualizerOutputManager;

  bool _fftEnabled = true;
  int _lastAnalysisMicros = 0;

  final StreamController<FftFrame> _rawFftController = StreamController<FftFrame>.broadcast();
  final StreamController<FftFrame> _optimizedFftController = StreamController<FftFrame>.broadcast();

  // --- Getters ---
  VisualizerOptimizationOptions get options => _fftProcessor.options;
  bool get enabled => _fftEnabled;
  Stream<FftFrame> get rawStream => _rawFftController.stream;
  Stream<FftFrame> get optimizedStream => _optimizedFftController.stream;

  List<double> get rawMagnitudes => _fftProcessor.latestRawFft;
  List<double> get optimizedMagnitudes => _fftProcessor.latestOptimizedFft;

  bool get hasOptimizedListeners => _optimizedFftController.hasListener;

  void _initVisualizerOutputManager() {
    visualizerOutputManager = VisualizerOutputManager(
      fftSourceProvider: () {
        final bins = _getLatestFft();
        return bins.isEmpty ? <double>[] : List<double>.from(bins);
      },
    );
  }

  // --- Actions ---

  void setEnabled(bool enabled) {
    if (_fftEnabled == enabled) return;
    _fftEnabled = enabled;
    if (!_fftEnabled) resetState();
    _notify();
  }

  void updateOptions(VisualizerOptimizationOptions options) {
    _fftProcessor.updateOptions(options);
    _notify();
  }

  void resetState() {
    _fftProcessor.resetState();
    visualizerOutputManager.resetAll();
    _lastAnalysisMicros = 0;
    _notify();
  }

  void processAnalysisTick(bool isPlaying, Duration position) {
    if (!_fftEnabled) return;

    List<double> rawBins = List<double>.from(_getLatestFft());
    if (rawBins.isEmpty) return;
    
    if (!isPlaying) {
      rawBins = List<double>.filled(rawBins.length, 0.0);
    }

    final nowMicros = DateTime.now().microsecondsSinceEpoch;
    final dtSec = _lastAnalysisMicros == 0
        ? (1.0 / 30.0) 
        : (nowMicros - _lastAnalysisMicros) / 1000000.0;
    _lastAnalysisMicros = nowMicros;

    _fftProcessor.processAnalysis(rawBins, dtSec);
    _emitFrames(position, isPlaying);
  }

  void processRenderTick(int elapsedMicros, int analysisIntervalMicros) {
    if (!_fftEnabled || !hasOptimizedListeners) return;
    _fftProcessor.processRender(elapsedMicros, analysisIntervalMicros);
    if (!_optimizedFftController.isClosed) {
      _optimizedFftController.add(FftFrame(
        position: Duration.zero,
        values: _fftProcessor.latestOptimizedFft,
        isPlaying: true, 
      ));
    }
  }

  void _emitFrames(Duration position, bool isPlaying) {
    if (!_rawFftController.isClosed && _rawFftController.hasListener) {
      _rawFftController.add(FftFrame(
        position: position,
        values: _fftProcessor.latestRawFft,
        isPlaying: isPlaying,
      ));
    }
  }

  @override
  void dispose() {
    _rawFftController.close();
    _optimizedFftController.close();
    visualizerOutputManager.dispose();
    super.dispose();
  }

  void _notify() {
    notifyListeners();
    _parent.notifyListeners();
  }

  // --- Output Manager Proxy ---
  VisualizerOutputStream createOutput(VisualizerOutputConfig config) => visualizerOutputManager.createOutput(config);
  void removeOutput(String id) => visualizerOutputManager.removeOutput(id);
  VisualizerOutputStream? getOutput(String id) => visualizerOutputManager.getOutput(id);
}
