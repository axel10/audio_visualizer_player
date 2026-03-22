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
import 'player_state_snapshot.dart';
import 'equalizer_controller.dart';

export 'player_controller.dart';
export 'playlist_controller.dart';
export 'random_playback_models.dart';
export 'visualizer_controller.dart';
export 'equalizer_controller.dart';
export 'playlist_models.dart';
export 'player_state_snapshot.dart';

/// The top-level modular controller for audio playback and visualization.
class AudioVisualizerPlayerController extends ChangeNotifier implements AudioVisualizerParent {
  AudioVisualizerPlayerController({
    this.fftSize = 1024,
    this.analysisFrequencyHz = 30.0,
    Duration fadeDuration = Duration.zero,
    FadeMode fadeMode = FadeMode.sequential,
    VisualizerOptimizationOptions visualOptions = const VisualizerOptimizationOptions(),
  }) {
    player = PlayerController(parent: this);
    player.setFadeConfig(duration: fadeDuration, mode: fadeMode);

    playlist = PlaylistController(parent: this);

    visualizer = VisualizerController(
      fftSize: fftSize,
      visualOptions: visualOptions,
      getLatestFft: () => _latestFftCache,
      parent: this,
    );

    equalizer = EqualizerController(parent: this);
  }

  static const int maxEqualizerBands = EqualizerController.maxEqualizerBands;
  static const double equalizerMinFrequencyHz = EqualizerController.minFrequencyHz;
  static const double equalizerMaxFrequencyHz = EqualizerController.maxFrequencyHz;
  static const double equalizerBassBoostFrequencyHz = EqualizerController.bassBoostFrequencyHz;
  static const double equalizerBassBoostQ = EqualizerController.bassBoostQ;

  final int fftSize;
  final double analysisFrequencyHz;

  late final PlayerController player;
  late final PlaylistController playlist;
  late final VisualizerController visualizer;
  late final EqualizerController equalizer;

  List<double> _latestFftCache = const [];

  static bool _rustLibInitialized = false;
  bool _initialized = false;
  bool _isTransitioning = false;
  Timer? _analysisTick;
  Timer? _renderTick;
  StreamSubscription<PlaybackState>? _playbackStateSubscription;

  bool get isSupported => Platform.isAndroid || Platform.isWindows;
  bool get isInitialized => _initialized;
  EqualizerConfig get equalizerConfig => equalizer.config;

  /// Returns a full snapshot of the current state.
  PlayerStateSnapshot get state => PlayerStateSnapshot(
    position: player.position,
    duration: player.duration,
    volume: player.volume,
    currentState: player.currentState,
    playlists: playlist.playlists,
    randomPolicy: playlist.randomPolicy,
    playlistMode: playlist.mode,
    activePlaylist: playlist.activePlaylist,
    currentIndex: playlist.currentIndex,
    track: playlist.currentTrack,
    error: player.error,
    equalizerConfig: equalizer.config,
    isTransitioning: _isTransitioning || player.isFadeActive,
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

    try {
      await equalizer.initialize();
    } catch (e) {
      player.setError('Equalizer sync failed: $e');
      return;
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

  // --- AudioVisualizerParent Implementation ---

  @override
  void notifyListeners() => super.notifyListeners();

  @override
  Future<void> loadTrack({required bool autoPlay, Duration? position}) async {
    final track = playlist.currentTrack;
    if (track == null) return;

    await player.performTransition(
      uri: track.uri,
      autoPlay: autoPlay,
      position: position,
      onStateChanged: (progressing) {
        _isTransitioning = progressing;
        notifyListeners();
      },
    );
    visualizer.resetState();
  }

  @override
  Future<void> clearPlayback() async {
    player.stopPlayback();
    visualizer.resetState();
  }

  @override
  Future<bool> handlePlayRequested() async {
    if (playlist.items.isEmpty) return false;

    if (playlist.mode == PlaylistMode.queue ||
        playlist.mode == PlaylistMode.queueLoop ||
        playlist.mode == PlaylistMode.autoQueueLoop) {
      final hasNext = playlist.resolveAdjacentIndex(next: true);
      if (hasNext == null) {
        await playlist.setActivePlaylist(playlist.activePlaylistId!, startIndex: 0, autoPlay: true);
        return true;
      }
    }
    return false;
  }

  // --- Internal Loops ---

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
    player.updatePosition(player.position + _renderInterval);

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
    if (_isTransitioning || player.currentState != PlayerState.completed) return;

    if (playlist.mode == PlaylistMode.singleLoop) {
      await loadTrack(autoPlay: true);
      return;
    }

    if (playlist.mode == PlaylistMode.single) return;

    final success = await playlist.playNext(reason: PlaybackReason.autoNext);
    if (!success) {
      // End of queue logic could go here
    }
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
          ? await extractWaveformForPath(
              path: filePath,
              expectedChunks: BigInt.from(expectedChunks),
              sampleStride: BigInt.from(clampedStride),
            )
          : await extractLoadedWaveform(
              expectedChunks: BigInt.from(expectedChunks),
              sampleStride: BigInt.from(clampedStride),
            );
      return data.toList();
    } catch (e) {
      player.setError('Waveform failed: $e');
      return const [];
    }
  }

  // --- Methods Delegated to Sub-Controllers ---

  Future<void> setEqualizerConfig(EqualizerConfig config) async => equalizer.setConfig(config);
  Future<void> setEqualizerEnabled(bool enabled) async => equalizer.setEnabled(enabled);
  Future<void> setEqualizerBandCount(int bandCount) async => equalizer.setBandCount(bandCount);
  Future<void> setEqualizerBandGain(int bandIndex, double gainDb) async => equalizer.setBandGain(bandIndex, gainDb);
  Future<void> setEqualizerPreamp(double preampDb) async => equalizer.setPreamp(preampDb);
  Future<void> setBassBoost(double gainDb) async => equalizer.setBassBoost(gainDb);
  void resetEqualizerDefaults() => equalizer.resetDefaults();
  List<double> getEqualizerBandCenters({int? bandCount}) => equalizer.getBandCenters(bandCount: bandCount);
}
