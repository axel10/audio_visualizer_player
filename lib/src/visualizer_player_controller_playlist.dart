part of 'visualizer_player_controller.dart';

mixin _PlaylistControllerMixin on ChangeNotifier {
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

  String? get _selectedPath;
  set _selectedPath(String? value);

  Duration get _duration;
  set _duration(Duration value);

  Duration get _position;
  set _position(Duration value);

  bool get _isPlaying;
  set _isPlaying(bool value);

  PlayerState get _playerState;
  double get _volume;

  Future<void> loadFromPath(String path);
  Future<void> seek(Duration target);
  Future<void> play();
  void _resetFftState();

  /// All user-visible playlists (excludes internal __default__).
  List<Playlist> get playlists => List<Playlist>.unmodifiable(
    _playlists.where((p) => p.id != _defaultPlaylistId).toList(),
  );

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
  AudioTrack? get currentTrack => _currentIndex == null
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
  Future<void> createPlaylist(
    String id,
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
  Future<void> updatePlaylist(
    String id, {
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
  Future<void> setActivePlaylistById(
    String id, {
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
    _currentIndex = playlist.items.isEmpty
        ? null
        : startIndex.clamp(0, playlist.items.length - 1);
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
    if (fromIndex < 0 || fromIndex >= visiblePlaylists.length || toIndex < 0) {
      return;
    }
    final boundedTo = toIndex.clamp(0, visiblePlaylists.length - 1);
    if (fromIndex == boundedTo) {
      return;
    }
    // Map user indices to internal indices
    final actualFromIdx = _playlists.indexOf(visiblePlaylists[fromIndex]);
    final actualToIdx = _playlists.indexOf(visiblePlaylists[boundedTo]);
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

  /// Inserts one track at [index] in active playlist.
  Future<void> insertTrack(int index, AudioTrack track) async {
    // Ensure we have an active playlist before inserting
    if (_activePlaylistId == null) {
      await _ensureActivePlaylist();
    }
    final target = index.clamp(0, _activePlaylistTracks.length);
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
    if (_activePlaylistId == null ||
        index < 0 ||
        index >= _activePlaylistTracks.length) {
      return;
    }
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
    if (_activePlaylistId == null ||
        fromIndex < 0 ||
        fromIndex >= _activePlaylistTracks.length) {
      return;
    }
    final boundedTo = toIndex.clamp(0, _activePlaylistTracks.length - 1);
    if (fromIndex == boundedTo) {
      return;
    }
    final moved = _activePlaylistTracks.removeAt(fromIndex);
    _activePlaylistTracks.insert(boundedTo, moved);

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

  /// Switches to track at [index] in active playlist and starts playback.
  ///
  /// Optional [position] seeks after loading.
  Future<void> playAt(int index, {Duration? position}) async {
    if (_activePlaylistId == null ||
        index < 0 ||
        index >= _activePlaylistTracks.length) {
      return;
    }
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
        name: 'Default',
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

  void _syncLegacySingleTrackPlaylist(String path, {Duration? duration}) {
    if (_activePlaylistTracks.length == 1 &&
        _activePlaylistTracks.first.uri == path) {
      if (_currentIndex == 0) {
        _emitPlaylistState();
        return;
      }
    }
    final fileName = path.split(RegExp(r'[\\/]')).last;
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
      activePlaylistId: _activePlaylistId,
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
        DateTime.now().microsecondsSinceEpoch + duration.inMicroseconds;
  }

  Future<void> _handleAutoTransitionIfNeeded({required bool wasPlaying}) async {
    if (_autoTransitionInFlight) {
      return;
    }
    if (_selectedPath == null || _activePlaylistTracks.isEmpty) {
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

  void _disposePlaylistState() {
    _playlistStateController.close();
    _playlistStateNotifier.dispose();
  }
}
