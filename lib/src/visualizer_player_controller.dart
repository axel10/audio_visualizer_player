import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'fft_processor.dart';
import 'player_models.dart';
import 'rust/api/simple.dart';
import 'rust/frb_generated.dart';

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
class AudioVisualizerPlayerController extends ChangeNotifier {
  /// Creates a player controller with FFT and visualization options.
  AudioVisualizerPlayerController({
    this.fftSize = 1024,
    this.analysisFrequencyHz = 30.0,
    VisualizerOptimizationOptions visualOptions =
    const VisualizerOptimizationOptions(),
  })
      : assert(fftSize > 0),
        assert(analysisFrequencyHz > 0),
        assert(visualOptions.frequencyGroups > 0),
        assert(visualOptions.targetFrameRate > 0),
        assert(visualOptions.groupContrastExponent > 0) {
    _fftProcessor = FftProcessor(fftSize: fftSize, options: visualOptions);
  }

  /// FFT size requested from native analysis.
  final int fftSize;

  /// Analysis polling frequency in Hz.
  final double analysisFrequencyHz;

  /// Output smoothing/grouping options for visualization.
  VisualizerOptimizationOptions get visualOptions => _fftProcessor.options;

  Timer? _analysisTick;
  Timer? _renderTick;
  bool _initialized = false;
  int _lastAnalysisMicros = 0;
  bool _fftEnabled = true;

  String? _selectedPath;
  String? _error;
  Duration _duration = Duration.zero;
  Duration _position = Duration.zero;
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

  /// Whether FFT computation and data emission is enabled.
  bool get fftEnabled => _fftEnabled;

  /// Returns latest raw FFT magnitudes.
  List<double> getRawFft() => _fftProcessor.latestRawFft;

  /// Returns latest optimized FFT magnitudes.
  List<double> getOptimizedFft() => _fftProcessor.latestOptimizedFft;

  bool get _needOptimizedCompute => _optimizedFftController.hasListener;

  Duration get _analysisInterval =>
      Duration(microseconds: (1000000.0 / analysisFrequencyHz).round());

  Duration get _renderInterval =>
      Duration(
        microseconds: (1000000.0 / visualOptions.targetFrameRate).round(),
      );

  /// Requests required runtime permissions on Android.
  ///
  /// Returns `true` because file playback with rodio does not need mic permission.
  Future<bool> requestPermissions() async {
    clearError();
    return true;
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

    try {
      await RustLib.init();
    } catch (e) {
      _error = 'Rust bridge init failed: $e';
      notifyListeners();
      return;
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

    try {
      await loadAudioFile(path: path);
      await setAudioVolume(volume: _volume);
    } catch (e) {
      _error = 'Load failed: $e';
      _playerState = PlayerState.error;
      _emitPlaylistState();
      notifyListeners();
      return;
    }
    final durationMs = getAudioDurationMs();
    _selectedPath = path;
    _position = Duration.zero;
    _duration = Duration(milliseconds: durationMs.toInt());
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
    try {
      await playAudio();
      _isPlaying = true;
      _playerState = PlayerState.playing;
    } catch (e) {
      _error = 'Play failed: $e';
      _playerState = PlayerState.error;
    }
    _emitPlaylistState();
    notifyListeners();
  }

  /// Pauses playback.
  Future<void> pause() async {
    _suppressAutoAdvanceFor(const Duration(milliseconds: 900));
    try {
      await pauseAudio();
      _isPlaying = false;
      _playerState = PlayerState.paused;
    } catch (e) {
      _error = 'Pause failed: $e';
      _playerState = PlayerState.error;
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
    try {
      await seekAudioMs(positionMs: ms);
      _position = Duration(milliseconds: ms);
    } catch (e) {
      _error = 'Seek failed: $e';
    }
    _emitPlaylistState();
    notifyListeners();
  }

  /// Sets playback volume in range `0..1`.
  Future<void> setVolume(double volume) async {
    _volume = volume.clamp(0.0, 1.0);
    try {
      await setAudioVolume(volume: _volume);
    } catch (e) {
      _error = 'Set volume failed: $e';
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
  FftFrame getCurrentRawFftFrame() =>
      FftFrame(
        position: _position,
        values: _fftProcessor.latestRawFft,
        isPlaying: _isPlaying,
      );

  /// Current optimized FFT frame snapshot.
  FftFrame getCurrentOptimizedFftFrame() =>
      FftFrame(
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

  /// Enables or disables FFT computation and data emission.
  ///
  /// When disabled, stops all FFT calculations and clears FFT data.
  /// When enabled, resumes FFT computation on next analysis tick.
  Future<void> setFftEnabled(bool enabled) async {
    if (_fftEnabled == enabled) {
      return;
    }
    _fftEnabled = enabled;
    if (!_fftEnabled) {
      _resetFftState();
    }
    // _emitPlaylistState();
    notifyListeners();
  }

  /// Toggles FFT computation on/off.
  Future<void> toggleFftEnabled() async {
    await setFftEnabled(!_fftEnabled);
  }

  /// Returns the whole-track waveform for the currently loaded audio.
  ///
  /// [expectedChunks] controls the number of normalized amplitude samples (0.0 to 1.0).
  /// This uses Rust/Symphonia streaming decode and aggregates chunk peaks.
  /// [sampleStride] controls packet-step sampling (1 = process every packet).
  Future<List<double>> getLoadedWaveform({
    required int expectedChunks,
    int sampleStride = 1,
  }) async {
    if (expectedChunks <= 0) {
      _error = 'expectedChunks must be > 0.';
      notifyListeners();
      return const [];
    }
    if (_selectedPath == null) {
      _error = 'No audio loaded for waveform extraction.';
      notifyListeners();
      return const [];
    }

    try {
      final clampedStride = sampleStride < 1 ? 1 : sampleStride;
      final data = await extractLoadedWaveform(
        expectedChunks: BigInt.from(expectedChunks),
        sampleStride: BigInt.from(clampedStride),
      );
      return data.toList(growable: false);
    } catch (e) {
      _error = 'Waveform extraction failed: $e';
      notifyListeners();
      return const [];
    }
  }

  /// Calculates the whole-track waveform for the given [filePath].
  ///
  /// The [outCount] parameter specifies how many normalized magnitude samples (0.0 to 1.0)
  /// you want returned.
  Future<List<double>> getWholeTrackWaveform({
    required String filePath,
    required int outCount,
    int sampleStride = 1,
  }) async {
    if (filePath.isEmpty) {
      _error = 'Selected file path is unavailable.';
      notifyListeners();
      return const [];
    }
    if (_selectedPath != filePath) {
      await loadFromPath(filePath);
    }
    return getLoadedWaveform(
      expectedChunks: outCount,
      sampleStride: sampleStride,
    );
  }

  Future<void> _onAnalysisTick() async {
    if (_selectedPath == null || !_fftEnabled) {
      return;
    }
    await _pollPlaybackState();

    List<double> rawBins = List<double>.from(getLatestFft());
    if (rawBins.isEmpty) {
      return;
    }
    if (!_isPlaying) {
      rawBins = List<double>.filled(rawBins.length, 0.0);
    }

    final nowMicros = DateTime
        .now()
        .microsecondsSinceEpoch;
    final dtSec = _lastAnalysisMicros == 0
        ? _analysisInterval.inMicroseconds / 1000000.0
        : (nowMicros - _lastAnalysisMicros) / 1000000.0;
    _lastAnalysisMicros = nowMicros;

    _fftProcessor.processAnalysis(rawBins, dtSec);
    _emitRawFftFrame();
  }

  void _onRenderTick() {
    if (_selectedPath == null || !_fftEnabled || !_needOptimizedCompute) {
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
    try {
      _position = Duration(milliseconds: getAudioPositionMs().toInt());
      final newDurationMs = getAudioDurationMs().toInt();
      if (newDurationMs > 0) {
        _duration = Duration(milliseconds: newDurationMs);
      }
      _isPlaying = isAudioPlaying();

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
    } catch (e) {
      _error = 'Playback poll failed: $e';
      _playerState = PlayerState.error;
      _emitPlaylistState();
      notifyListeners();
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
    unawaited(disposeAudio());
    _rawFftController.close();
    _optimizedFftController.close();
    _disposePlaylistState();
    super.dispose();
  }

  /////////////////////////   playlist   //////////////////////////////

  // Playlist collection management
  static const String _defaultPlaylistId = '__default__';
  final List<Playlist> _playlists = <Playlist>[];
  String? _activePlaylistId;

  // Active playlist playback state (copies of active playlist's track list and order)
  final List<AudioTrack> _activePlaylistTracks = <AudioTrack>[];
  final List<int> _playOrder = <int>[];
  int? _currentIndex;
  int? _currentOrderCursor;

  // Playback settings
  bool _shuffleEnabled = false;
  RepeatMode _repeatMode = RepeatMode.off;
  math.Random _shuffleRandom = math.Random();

  // Internal state tracking
  bool _playlistInternalLoad = false;
  bool _autoTransitionInFlight = false;
  int _autoAdvanceSuppressedUntilMicros = 0;

  // State notifiers
  final StreamController<PlayerControllerState> _playlistStateController =
  StreamController<PlayerControllerState>.broadcast();
  late final ValueNotifier<PlayerControllerState> _playlistStateNotifier =
  ValueNotifier<PlayerControllerState>(_buildControllerState());

  /// All user-visible playlists (excludes internal __default__).
  List<Playlist> get playlists =>
      List<Playlist>.unmodifiable(
        _playlists.where((p) => p.id != _defaultPlaylistId).toList(),
      );

  /// Queue playlist backed by internal id `__default__`.
  Playlist? get queue => getPlaylistById(_defaultPlaylistId);

  /// Queue tracks snapshot.
  List<AudioTrack> get queueTracks =>
      List<AudioTrack>.unmodifiable(queue?.items ?? const <AudioTrack>[]);

  /// Current active playlist, or `null` if none.
  Playlist? get activePlaylist {
    if (_activePlaylistId == null) return null;
    try {
      return _playlists.firstWhere((p) => p.id == _activePlaylistId);
    } catch (e) {
      return null;
    }
  }

  /// Current active playlist tracks.
  List<AudioTrack> get playlist =>
      List<AudioTrack>.unmodifiable(_activePlaylistTracks);

  /// Current selected track index in active playlist.
  int? get currentIndex => _currentIndex;

  /// Currently selected track, or `null` if no active playlist or nothing selected.
  AudioTrack? get currentTrack =>
      _currentIndex == null
          ? null
          : (_currentIndex! < _activePlaylistTracks.length
          ? _activePlaylistTracks[_currentIndex!]
          : null);

  /// Whether shuffle playback order is enabled.
  bool get shuffleEnabled => _shuffleEnabled;

  /// Active repeat mode.
  RepeatMode get repeatMode => _repeatMode;

  /// Current playlist state snapshot.
  PlayerControllerState get playlistState => _buildControllerState();

  /// Value-listenable playlist state for UI binding.
  ValueListenable<PlayerControllerState> get playlistListenable =>
      _playlistStateNotifier;

  /// Stream of playlist state changes.
  Stream<PlayerControllerState> get playlistStream =>
      _playlistStateController.stream;

  // === Playlist Collection Management ===

  /// Creates a new playlist and optionally sets it as active.
  Future<void> createPlaylist(String id,
      String name, {
        List<AudioTrack> items = const <AudioTrack>[],
        bool setAsActive = false,
      }) async {
    if (id == _defaultPlaylistId) {
      throw StateError('Cannot create playlist with reserved id "$id"');
    }
    if (_playlists.any((p) => p.id == id)) {
      throw StateError('Playlist with id "$id" already exists');
    }
    final playlist = Playlist(id: id, name: name, items: items);
    _playlists.add(playlist);
    if (setAsActive) {
      await setActivePlaylistById(id);
    } else {
      _emitPlaylistState();
      notifyListeners();
    }
  }

  /// Gets a playlist by id, or `null` if not found.
  Playlist? getPlaylistById(String id) {
    try {
      return _playlists.firstWhere((p) => p.id == id);
    } catch (e) {
      return null;
    }
  }

  /// Updates a playlist's name and/or items.
  Future<void> updatePlaylist(String id, {
    String? name,
    List<AudioTrack>? items,
  }) async {
    final idx = _playlists.indexWhere((p) => p.id == id);
    if (idx < 0) {
      throw StateError('Playlist with id "$id" not found');
    }
    final old = _playlists[idx];
    final updated = old.copyWith(
      name: name ?? old.name,
      items: items ?? old.items,
    );
    _playlists[idx] = updated;

    // If this is the active playlist, update internal track state
    if (_activePlaylistId == id) {
      _activePlaylistTracks
        ..clear()
        ..addAll(updated.items);
      // Clamp currentIndex to new length
      if (_currentIndex != null &&
          _currentIndex! >= _activePlaylistTracks.length) {
        _currentIndex = _activePlaylistTracks.isEmpty
            ? null
            : _activePlaylistTracks.length - 1;
      }
      _rebuildPlayOrder(keepCurrentAtFront: _shuffleEnabled);
    }

    _emitPlaylistState();
    notifyListeners();
  }

  /// Deletes a playlist by id.
  /// If the deleted playlist is active, switches to another available playlist or clears playback.
  Future<void> deletePlaylist(String id) async {
    if (id == _defaultPlaylistId) {
      throw StateError('Cannot delete internal default playlist');
    }
    final idx = _playlists.indexWhere((p) => p.id == id);
    if (idx < 0) {
      throw StateError('Playlist with id "$id" not found');
    }
    _playlists.removeAt(idx);

    // If deleted playlist was active, switch to another
    if (_activePlaylistId == id) {
      // Find next available non-default playlist
      final nextPlaylist = _playlists
          .where((p) => p.id != _defaultPlaylistId)
          .firstOrNull;
      if (nextPlaylist != null) {
        await setActivePlaylistById(nextPlaylist.id);
      } else {
        await _clearActivePlaylist();
      }
    } else {
      _emitPlaylistState();
      notifyListeners();
    }
  }

  /// Sets the active playlist by id.
  /// Optionally starts playback at [startIndex] and with [autoPlay].
  Future<void> setActivePlaylistById(String id, {
    int startIndex = 0,
    bool autoPlay = false,
  }) async {
    final playlist = getPlaylistById(id);
    if (playlist == null) {
      throw StateError('Playlist with id "$id" not found');
    }
    _activePlaylistId = id;
    _activePlaylistTracks
      ..clear()
      ..addAll(playlist.items);
    if (playlist.items.isEmpty) {
      if (startIndex != 0) {
        throw RangeError.value(
          startIndex,
          'startIndex',
          'Must be 0 when playlist is empty',
        );
      }
      _currentIndex = null;
    } else {
      _assertValidIndex(startIndex, playlist.items, 'startIndex');
      _currentIndex = startIndex;
    }
    _rebuildPlayOrder(keepCurrentAtFront: _shuffleEnabled);

    if (_currentIndex != null) {
      await _loadCurrentTrack(autoPlay: autoPlay);
    } else {
      _emitPlaylistState();
      notifyListeners();
    }
  }

  /// Moves a playlist from [fromIndex] to [toIndex] in the user-visible collection.
  /// Indices apply only to non-internal playlists.
  Future<void> movePlaylist(int fromIndex, int toIndex) async {
    // Get user-visible playlists (excluding __default__)
    final visiblePlaylists = _playlists
        .where((p) => p.id != _defaultPlaylistId)
        .toList();
    if (visiblePlaylists.isEmpty) {
      throw StateError('No playlists available to move');
    }
    _assertValidIndex(fromIndex, visiblePlaylists, 'fromIndex');
    _assertValidIndex(toIndex, visiblePlaylists, 'toIndex');
    if (fromIndex == toIndex) {
      return;
    }
    // Map user indices to internal indices
    final actualFromIdx = _playlists.indexOf(visiblePlaylists[fromIndex]);
    final actualToIdx = _playlists.indexOf(visiblePlaylists[toIndex]);
    if (actualFromIdx < 0 || actualToIdx < 0) {
      return;
    }
    final moved = _playlists.removeAt(actualFromIdx);
    _playlists.insert(actualToIdx, moved);
    _emitPlaylistState();
    notifyListeners();
  }

  // === Track Operations on Active Playlist ===

  /// Adds one track to the end of active playlist.
  Future<void> addTrack(AudioTrack track) async {
    await addTracks(<AudioTrack>[track]);
  }

  /// Adds multiple tracks to the end of active playlist.
  Future<void> addTracks(List<AudioTrack> tracks) async {
    if (tracks.isEmpty) {
      return;
    }
    // Ensure we have an active playlist before adding tracks
    if (_activePlaylistId == null) {
      await _ensureActivePlaylist();
    }
    final wasEmpty = _activePlaylistTracks.isEmpty;
    _activePlaylistTracks.addAll(tracks);
    if (wasEmpty) {
      _currentIndex = 0;
      _rebuildPlayOrder(keepCurrentAtFront: _shuffleEnabled);
      await _loadCurrentTrack(autoPlay: false);
    } else {
      _rebuildPlayOrder(keepCurrentAtFront: _shuffleEnabled);
      _emitPlaylistState();
      notifyListeners();
    }
    // Sync back to _playlists
    await _syncActivePlaylistToPlaylists();
  }

  /// Adds one track to queue (`__default__`) without changing active playlist.
  Future<void> addQueueTrack(AudioTrack track) async {
    await addQueueTracks(<AudioTrack>[track]);
  }

  /// Adds multiple tracks to queue (`__default__`) without changing active playlist.
  Future<void> addQueueTracks(List<AudioTrack> tracks) async {
    if (tracks.isEmpty) {
      return;
    }
    await _ensureQueueExists();
    if (_activePlaylistId == _defaultPlaylistId) {
      await addTracks(tracks);
      return;
    }
    final currentQueue = queue!;
    await updatePlaylist(
      _defaultPlaylistId,
      items: List<AudioTrack>.from(currentQueue.items)
        ..addAll(tracks),
    );
  }

  /// Inserts one track at [index] in active playlist.
  Future<void> insertTrack(int index, AudioTrack track) async {
    // Ensure we have an active playlist before inserting
    if (_activePlaylistId == null) {
      await _ensureActivePlaylist();
    }
    _assertValidInsertionIndex(index, _activePlaylistTracks.length, 'index');
    final target = index;
    _activePlaylistTracks.insert(target, track);
    if (_currentIndex == null) {
      _currentIndex = 0;
      _rebuildPlayOrder(keepCurrentAtFront: _shuffleEnabled);
      await _loadCurrentTrack(autoPlay: false);
      // Sync back to _playlists
      await _syncActivePlaylistToPlaylists();
      return;
    }
    if (target <= _currentIndex!) {
      _currentIndex = _currentIndex! + 1;
    }
    _rebuildPlayOrder(keepCurrentAtFront: _shuffleEnabled);
    _emitPlaylistState();
    notifyListeners();
    // Sync back to _playlists
    await _syncActivePlaylistToPlaylists();
  }

  /// Removes the track at [index] from active playlist.
  Future<void> removeTrackAt(int index) async {
    if (_activePlaylistId == null) {
      await _ensureActivePlaylist();
    }
    _assertValidIndex(index, _activePlaylistTracks, 'index');
    final wasPlayingNow = _isPlaying;
    final removedCurrent = _currentIndex == index;
    _activePlaylistTracks.removeAt(index);
    if (_activePlaylistTracks.isEmpty) {
      await clearPlaylist();
      return;
    }
    if (removedCurrent) {
      final next = index.clamp(0, _activePlaylistTracks.length - 1);
      _currentIndex = next;
      _rebuildPlayOrder(keepCurrentAtFront: _shuffleEnabled);
      await _loadCurrentTrack(autoPlay: wasPlayingNow);
      // Sync back to _playlists
      await _syncActivePlaylistToPlaylists();
      return;
    }
    if (_currentIndex != null && index < _currentIndex!) {
      _currentIndex = _currentIndex! - 1;
    }
    _rebuildPlayOrder(keepCurrentAtFront: _shuffleEnabled);
    _emitPlaylistState();
    notifyListeners();
    // Sync back to _playlists
    await _syncActivePlaylistToPlaylists();
  }

  /// Removes the first track with matching [trackId] from active playlist.
  Future<void> removeTrackById(String trackId) async {
    final idx = _activePlaylistTracks.indexWhere((t) => t.id == trackId);
    if (idx < 0) {
      return;
    }
    await removeTrackAt(idx);
  }

  /// Moves a track from [fromIndex] to [toIndex] in active playlist.
  Future<void> moveTrack(int fromIndex, int toIndex) async {
    if (_activePlaylistId == null) {
      await _ensureActivePlaylist();
    }
    _assertValidIndex(fromIndex, _activePlaylistTracks, 'fromIndex');
    _assertValidIndex(toIndex, _activePlaylistTracks, 'toIndex');
    if (fromIndex == toIndex) {
      return;
    }
    final moved = _activePlaylistTracks.removeAt(fromIndex);
    _activePlaylistTracks.insert(toIndex, moved);

    if (_currentIndex != null) {
      var current = _currentIndex!;
      if (current == fromIndex) {
        current = toIndex;
      } else if (fromIndex < current && toIndex >= current) {
        current -= 1;
      } else if (fromIndex > current && toIndex <= current) {
        current += 1;
      }
      _currentIndex = current;
    }
    _rebuildPlayOrder(keepCurrentAtFront: _shuffleEnabled);
    _emitPlaylistState();
    notifyListeners();
    // Sync back to _playlists
    await _syncActivePlaylistToPlaylists();
  }

  /// Clears active playlist items and resets playback state.
  /// Does not delete the playlist itself, only clears its items.
  Future<void> clearPlaylist() async {
    _activePlaylistTracks.clear();
    _playOrder.clear();
    _currentIndex = null;
    _currentOrderCursor = null;
    _selectedPath = null;
    _duration = Duration.zero;
    _position = Duration.zero;
    _isPlaying = false;
    _resetFftState();
    // Sync back to _playlists
    if (_activePlaylistId != null) {
      await _syncActivePlaylistToPlaylists();
    }
    _emitPlaylistState();
    notifyListeners();
  }

  /// Removes one track by index from queue (`__default__`).
  Future<void> removeQueueTrackAt(int index) async {
    await _ensureQueueExists();
    if (_activePlaylistId == _defaultPlaylistId) {
      await removeTrackAt(index);
      return;
    }
    final currentQueue = queue!;
    _assertValidIndex(index, currentQueue.items, 'index');
    final updated = List<AudioTrack>.from(currentQueue.items)
      ..removeAt(index);
    await updatePlaylist(_defaultPlaylistId, items: updated);
  }

  /// Moves one track inside queue (`__default__`).
  Future<void> moveQueueTrack(int fromIndex, int toIndex) async {
    await _ensureQueueExists();
    if (_activePlaylistId == _defaultPlaylistId) {
      await moveTrack(fromIndex, toIndex);
      return;
    }
    final currentQueue = queue!;
    _assertValidIndex(fromIndex, currentQueue.items, 'fromIndex');
    _assertValidIndex(toIndex, currentQueue.items, 'toIndex');
    if (fromIndex == toIndex) {
      return;
    }
    final updated = List<AudioTrack>.from(currentQueue.items);
    final moved = updated.removeAt(fromIndex);
    updated.insert(toIndex, moved);
    await updatePlaylist(_defaultPlaylistId, items: updated);
  }

  /// Clears queue (`__default__`) items.
  Future<void> clearQueue() async {
    await _ensureQueueExists();
    if (_activePlaylistId == _defaultPlaylistId) {
      await clearPlaylist();
      return;
    }
    await updatePlaylist(_defaultPlaylistId, items: const <AudioTrack>[]);
  }

  /// Switches to track at [index] in active playlist and starts playback.
  ///
  /// Optional [position] seeks after loading.
  Future<void> playAt(int index, {Duration? position}) async {
    if (_activePlaylistId == null) {
      await _ensureActivePlaylist();
    }
    _assertValidIndex(index, _activePlaylistTracks, 'index');
    _currentIndex = index;
    _rebuildPlayOrder(keepCurrentAtFront: _shuffleEnabled);
    await _loadCurrentTrack(autoPlay: true, position: position);
  }

  /// Switches to track matching [trackId] in active playlist and starts playback.
  Future<void> playById(String trackId, {Duration? position}) async {
    final idx = _activePlaylistTracks.indexWhere((t) => t.id == trackId);
    if (idx < 0) {
      return;
    }
    await playAt(idx, position: position);
  }

  /// Plays next track according to repeat/shuffle rules.
  ///
  /// Returns `false` if no next track is available.
  Future<bool> playNext({PlaybackReason reason = PlaybackReason.user}) async {
    if (_activePlaylistTracks.isEmpty) {
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
    if (_activePlaylistTracks.isEmpty) {
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

  Future<void> _loadCurrentTrack({
    required bool autoPlay,
    Duration? position,
  }) async {
    final index = _currentIndex;
    if (index == null || index < 0 || index >= _activePlaylistTracks.length) {
      return;
    }
    final uri = _activePlaylistTracks[index].uri;
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

  Future<void> _syncActivePlaylistToPlaylists() async {
    if (_activePlaylistId == null) {
      return;
    }
    final idx = _playlists.indexWhere((p) => p.id == _activePlaylistId);
    if (idx < 0) {
      return;
    }
    final current = _playlists[idx];
    _playlists[idx] = current.copyWith(
      items: List<AudioTrack>.from(_activePlaylistTracks),
    );
  }

  Future<void> _clearActivePlaylist() async {
    _activePlaylistId = null;
    _activePlaylistTracks.clear();
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

  /// Ensures there's an active playlist, creating a default one if needed.
  /// Used for backward compatibility with loadFromPath.
  Future<void> _ensureActivePlaylist() async {
    if (_activePlaylistId != null) {
      return; // Already have active playlist
    }
    // Check if default playlist already exists
    if (_playlists.isNotEmpty &&
        _playlists.any((p) => p.id == _defaultPlaylistId)) {
      // Switch to existing default playlist
      await setActivePlaylistById(_defaultPlaylistId);
    } else {
      // Create and activate default playlist
      final playlist = Playlist(
        id: _defaultPlaylistId,
        name: 'Queue',
        items: const <AudioTrack>[],
      );
      _playlists.add(playlist);
      _activePlaylistId = _defaultPlaylistId;
      _activePlaylistTracks.clear();
      _currentIndex = null;
      _playOrder.clear();
      _currentOrderCursor = null;
      _emitPlaylistState();
      notifyListeners();
    }
  }

  Future<void> _ensureQueueExists() async {
    if (_playlists.any((p) => p.id == _defaultPlaylistId)) {
      return;
    }
    _playlists.add(
      const Playlist(
        id: _defaultPlaylistId,
        name: 'Queue',
        items: <AudioTrack>[],
      ),
    );
    _emitPlaylistState();
    notifyListeners();
  }

  void _assertValidIndex(int index, List<dynamic> items, String name) {
    RangeError.checkValidIndex(index, items, name);
  }

  void _assertValidInsertionIndex(int index, int length, String name) {
    RangeError.checkValueInInterval(index, 0, length, name);
  }

  void _syncLegacySingleTrackPlaylist(String path, {Duration? duration}) {
    if (_activePlaylistTracks.length == 1 &&
        _activePlaylistTracks.first.uri == path) {
      if (_currentIndex == 0) {
        _emitPlaylistState();
        return;
      }
    }
    final fileName = path
        .split(RegExp(r'[\\/]'))
        .last;
    _activePlaylistTracks
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
      ..addAll(List<int>.generate(_activePlaylistTracks.length, (i) => i));
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
    if (_activePlaylistTracks.isEmpty) {
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

  PlayerControllerState _buildControllerState() {
    // Filter out internal __default__ playlist from state
    final visiblePlaylists = _playlists
        .where((p) => p.id != _defaultPlaylistId)
        .toList();

    return PlayerControllerState(
      position: _position,
      duration: _duration,
      volume: _volume,
      currentState: _playerState,
      playlists: List<Playlist>.unmodifiable(visiblePlaylists),
      shuffleEnabled: _shuffleEnabled,
      repeatMode: _repeatMode,
      activePlaylist: activePlaylist,
      currentIndex: _currentIndex,
      track: currentTrack,
    );
  }

  void _emitPlaylistState() {
    final state = _buildControllerState();
    _playlistStateNotifier.value = state;
    if (_playlistStateController.hasListener &&
        !_playlistStateController.isClosed) {
      _playlistStateController.add(state);
    }
  }

  void _suppressAutoAdvanceFor(Duration duration) {
    _autoAdvanceSuppressedUntilMicros =
        DateTime
            .now()
            .microsecondsSinceEpoch + duration.inMicroseconds;
  }

  Future<void> _handleAutoTransitionIfNeeded({required bool wasPlaying}) async {
    if (_autoTransitionInFlight) {
      return;
    }
    if (_selectedPath == null || _activePlaylistTracks.isEmpty) {
      return;
    }
    final now = DateTime
        .now()
        .microsecondsSinceEpoch;
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

  void _disposePlaylistState() {
    _playlistStateController.close();
    _playlistStateNotifier.dispose();
  }

}
