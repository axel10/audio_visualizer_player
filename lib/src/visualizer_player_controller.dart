import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

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
import 'playback_transition.dart';

export 'player_controller.dart';
export 'playlist_controller.dart';
export 'random_playback_models.dart';
export 'visualizer_controller.dart';
export 'player_models.dart';
export 'playlist_models.dart';
export 'player_state_snapshot.dart';
export 'playback_transition.dart';

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

  static const int maxEqualizerBands = 20;
  static const double equalizerMinFrequencyHz = 32.0;
  static const double equalizerMaxFrequencyHz = 16000.0;
  static const double equalizerBassBoostFrequencyHz = 80.0;
  static const double equalizerBassBoostQ = 0.75;

  final int fftSize;
  final double analysisFrequencyHz;

  late final PlayerController player;
  late final PlaylistController playlist;
  late final VisualizerController visualizer;

  EqualizerConfig _equalizerConfig = _makeDefaultEqualizerConfig();
  List<double> _latestFftCache = const [];

  static bool _rustLibInitialized = false;
  bool _initialized = false;
  bool _isTransitioning = false;
  Timer? _analysisTick;
  Timer? _renderTick;
  StreamSubscription<PlaybackState>? _playbackStateSubscription;

  bool get isSupported => Platform.isAndroid || Platform.isWindows;
  bool get isInitialized => _initialized;
  EqualizerConfig get equalizerConfig => _equalizerConfig;

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
      _equalizerConfig = await getAudioEqualizerConfig();
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

  Future<void> _handleLoadTrack({required bool autoPlay, Duration? position}) async {
    final track = playlist.currentTrack;
    if (track == null) return;

    final switchingTracks = player.currentPath != null && player.currentPath != track.uri;
    final isPlaying = player.isPlaying;

    PlaybackTransition strategy = const ImmediateTransition();

    if (switchingTracks && player.fadeDuration > Duration.zero) {
      if (player.fadeMode == FadeMode.crossfade && isPlaying && autoPlay && position == null) {
        strategy = CrossfadeTransition(duration: player.fadeDuration);
      } else {
        strategy = SequentialFadeTransition(
          duration: player.fadeDuration,
          targetVolume: player.volume,
        );
      }
    }

    _isTransitioning = true;
    notifyListeners();
    try {
      await strategy.execute(
        player: player,
        uri: track.uri,
        autoPlay: autoPlay,
        position: position,
      );
      visualizer.resetState();
    } finally {
      _isTransitioning = false;
      notifyListeners();
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
      await _handleLoadTrack(autoPlay: true);
      return;
    }

    if (playlist.mode == PlaylistMode.single) return;

    final success = await playlist.playNext(reason: PlaybackReason.autoNext);
    if (!success) {
      // End of queue logic could go here
    }
  }

  Future<bool> _handlePlayRequested() async {
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

  // --- Equalizer Support ---

  Future<void> setEqualizerConfig(EqualizerConfig config) async {
    final normalized = _normalizeEqualizerConfig(config);
    try {
      await setAudioEqualizerConfig(config: normalized);
      _equalizerConfig = normalized;
      notifyListeners();
    } catch (e) {
      player.setError('Equalizer update failed: $e');
    }
  }

  Future<void> setEqualizerEnabled(bool enabled) async => setEqualizerConfig(_copyEqualizerConfig(enabled: enabled));

  Future<void> setEqualizerBandCount(int bandCount) async => setEqualizerConfig(_copyEqualizerConfig(bandCount: bandCount));

  Future<void> setEqualizerBandGain(int bandIndex, double gainDb) async {
    if (bandIndex < 0 || bandIndex >= maxEqualizerBands) return;
    final gains = Float32List.fromList(_equalizerConfig.bandGainsDb.toList());
    gains[bandIndex] = gainDb;
    await setEqualizerConfig(_copyEqualizerConfig(bandGainsDb: gains));
  }

  Future<void> setEqualizerPreamp(double preampDb) async => setEqualizerConfig(_copyEqualizerConfig(preampDb: preampDb));

  Future<void> setBassBoost(double gainDb) async => setEqualizerConfig(_copyEqualizerConfig(bassBoostDb: gainDb));

  void resetEqualizerDefaults() {
    unawaited(setEqualizerConfig(_makeDefaultEqualizerConfig()));
  }

  List<double> getEqualizerBandCenters({int? bandCount}) {
    final count = (bandCount ?? _equalizerConfig.bandCount).clamp(0, maxEqualizerBands);
    if (count <= 0) return const [];
    if (count == 1) return const [1000.0];
    final ratio = equalizerMaxFrequencyHz / equalizerMinFrequencyHz;
    return List.generate(count, (i) => equalizerMinFrequencyHz * math.pow(ratio, i / (count - 1)).toDouble(), growable: false);
  }

  static EqualizerConfig _makeDefaultEqualizerConfig() => EqualizerConfig(
    enabled: false,
    bandCount: maxEqualizerBands,
    preampDb: 0.0,
    bassBoostDb: 0.0,
    bassBoostFrequencyHz: equalizerBassBoostFrequencyHz,
    bassBoostQ: equalizerBassBoostQ,
    bandGainsDb: Float32List(maxEqualizerBands),
  );

  EqualizerConfig _normalizeEqualizerConfig(EqualizerConfig config) {
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

  EqualizerConfig _copyEqualizerConfig({bool? enabled, int? bandCount, double? preampDb, double? bassBoostDb, Float32List? bandGainsDb}) {
    return EqualizerConfig(
      enabled: enabled ?? _equalizerConfig.enabled,
      bandCount: bandCount ?? _equalizerConfig.bandCount,
      preampDb: preampDb ?? _equalizerConfig.preampDb,
      bassBoostDb: bassBoostDb ?? _equalizerConfig.bassBoostDb,
      bassBoostFrequencyHz: _equalizerConfig.bassBoostFrequencyHz,
      bassBoostQ: _equalizerConfig.bassBoostQ,
      bandGainsDb: bandGainsDb ?? _equalizerConfig.bandGainsDb,
    );
  }
}
