import 'package:flutter/foundation.dart';

import 'player_models.dart';
import 'playlist_models.dart';
import 'random_playback_models.dart';
import 'random_playback_manager.dart';

/// Manages playlists, tracks, and playback order.
class PlaylistController extends ChangeNotifier {
  PlaylistController({
    required AudioVisualizerParent parent,
  }) : _parent = parent;

  final AudioVisualizerParent _parent;

  static const String _defaultPlaylistId = '__default__';
  final List<Playlist> _playlists = <Playlist>[];
  String? _activePlaylistId;

  final List<AudioTrack> _activePlaylistTracks = <AudioTrack>[];
  final List<int> _playOrder = <int>[];
  int? _currentIndex;
  int? _currentOrderCursor;

  PlaylistMode _playlistMode = PlaylistMode.queue;
  final _randomManager = RandomPlaybackManager();

  /// All user-visible playlists.
  List<Playlist> get playlists => List<Playlist>.unmodifiable(
    _playlists.where((p) => p.id != _defaultPlaylistId).toList(),
  );

  /// Current active playlist.
  Playlist? get activePlaylist => playlistById(_activePlaylistId);

  /// Current active tracks.
  List<AudioTrack> get items => List<AudioTrack>.unmodifiable(_activePlaylistTracks);

  /// 当前播放项在活动列表中的索引。
  int? get currentIndex => _currentIndex;

  /// 当前正在播放的歌曲。
  AudioTrack? get currentTrack =>
      _currentIndex == null || _currentIndex! >= _activePlaylistTracks.length
      ? null
      : _activePlaylistTracks[_currentIndex!];

  /// 当前播放模式。
  PlaylistMode get mode => _playlistMode;

  /// Active random policy, or `null` if sequential playback is used.
  RandomPolicy? get randomPolicy => _randomManager.policy;
  String? get activePlaylistId => _activePlaylistId;
  String get queuePlaylistId => _defaultPlaylistId;
  List<RandomHistoryEntry> get randomHistory => _randomManager.history;

  /// Returns a playlist by id, or `null` if it does not exist.
  Playlist? playlistById(String? id) {
    if (id == null) return null;
    for (final playlist in _playlists) {
      if (playlist.id == id) return playlist;
    }
    return null;
  }

  // --- Methods ---

  Future<void> createPlaylist(String id, String name, {List<AudioTrack> items = const []}) async {
    if (id == _defaultPlaylistId) throw StateError('Reserved ID');
    if (_playlists.any((p) => p.id == id)) throw StateError('Exists');
    _playlists.add(Playlist(id: id, name: name, items: items));
    _notify();
  }

  Future<void> removePlaylist(String id) async {
    _playlists.removeWhere((p) => p.id == id);
    if (_activePlaylistId == id) {
      await switchPlaylist(_defaultPlaylistId);
    }
    _notify();
  }

  Future<void> setActivePlaylist(String id, {int startIndex = 0, bool autoPlay = false}) async {
    final playlist = playlistById(id);
    if (playlist == null) return;

    final isSamePlaylist = _activePlaylistId == id;
    if (isSamePlaylist && _currentIndex == startIndex) {
      await _parent.loadTrack(autoPlay: autoPlay);
      return;
    }

    _activePlaylistId = id;
    if (!isSamePlaylist) {
      _activePlaylistTracks..clear()..addAll(playlist.items);
      _rebuildPlayOrder();
    }

    _currentIndex = _activePlaylistTracks.isEmpty ? null : startIndex.clamp(0, _activePlaylistTracks.length - 1).toInt();
    
    _syncOrderCursor();
    _reconcileRandom();
    await _parent.loadTrack(autoPlay: autoPlay);
    _notify();
  }

  Future<void> switchPlaylist(String id) async => setActivePlaylist(id);

  Future<void> addTracks(List<AudioTrack> tracks) async {
    final wasEmpty = _activePlaylistTracks.isEmpty;
    await _ensureDefaultPlaylist();
    _activePlaylistTracks.addAll(tracks);
    _rebuildPlayOrder();

    if (wasEmpty && _activePlaylistTracks.isNotEmpty) {
      _currentIndex = 0;
      _reconcileRandom();
      await _parent.loadTrack(autoPlay: false);
    } else {
      _reconcileRandom();
    }

    await _syncActivePlaylistData();
    _notify();
  }

  Future<void> addTracksToPlaylist(String id, List<AudioTrack> tracks) async {
    final idx = _playlists.indexWhere((p) => p.id == id);
    if (idx >= 0) {
      _playlists[idx] = _playlists[idx].copyWith(
        items: [..._playlists[idx].items, ...tracks],
      );
      if (_activePlaylistId == id) {
        final wasEmpty = _activePlaylistTracks.isEmpty;
        _activePlaylistTracks.addAll(tracks);
        _rebuildPlayOrder();

        if (wasEmpty && _activePlaylistTracks.isNotEmpty) {
          _currentIndex = 0;
          _reconcileRandom();
          await _parent.loadTrack(autoPlay: false);
        } else {
          _reconcileRandom();
        }
      }
      _notify();
    }
  }

  Future<void> updatePlaylistTracks(String id, List<AudioTrack> newTracks) async {
    final idx = _playlists.indexWhere((p) => p.id == id);
    if (idx >= 0) {
      _playlists[idx] = _playlists[idx].copyWith(items: newTracks);
      if (_activePlaylistId == id) {
        final currentId = currentTrack?.id;
        _activePlaylistTracks..clear()..addAll(newTracks);
        _rebuildPlayOrder();

        if (currentId != null) {
          final newIdx = _activePlaylistTracks.indexWhere((t) => t.id == currentId);
          _currentIndex = newIdx >= 0 ? newIdx : null;
          _reconcileRandom();
          if (newIdx < 0) await _parent.loadTrack(autoPlay: false);
        } else {
          _currentIndex = _activePlaylistTracks.isNotEmpty ? 0 : null;
          _reconcileRandom();
          if (newTracks.isNotEmpty) await _parent.loadTrack(autoPlay: false);
        }
      }
      _notify();
    }
  }

  Future<void> insertTrack(int index, AudioTrack track) async {
    final wasEmpty = _activePlaylistTracks.isEmpty;
    _activePlaylistTracks.insert(index, track);
    _rebuildPlayOrder();

    if (wasEmpty) {
      _currentIndex = 0;
      _reconcileRandom();
      await _parent.loadTrack(autoPlay: false);
    } else {
      if (_currentIndex != null && index <= _currentIndex!) {
        _currentIndex = _currentIndex! + 1;
      }
      _reconcileRandom();
    }

    await _syncActivePlaylistData();
    _notify();
  }

  Future<void> replaceTrack(AudioTrack track) async {
    var changed = false;

    for (var i = 0; i < _activePlaylistTracks.length; i++) {
      if (_activePlaylistTracks[i].id == track.id) {
        _activePlaylistTracks[i] = track;
        changed = true;
      }
    }

    for (var i = 0; i < _playlists.length; i++) {
      final items = _playlists[i].items;
      var replacedAny = false;
      final replaced = <AudioTrack>[];
      for (final item in items) {
        if (item.id == track.id) {
          replaced.add(track);
          replacedAny = true;
        } else {
          replaced.add(item);
        }
      }
      if (replacedAny) {
        _playlists[i] = _playlists[i].copyWith(items: replaced);
        changed = true;
      }
    }

    if (changed) {
      final current = currentTrack;
      if (current != null && current.id == track.id && current.uri != track.uri) {
        await _parent.loadTrack(autoPlay: false);
      }
      _notify();
    }
  }

  Future<bool> playNext({PlaybackReason reason = PlaybackReason.user}) async {
    final resolution = _resolveAdjacentIndex(next: true);
    if (resolution == null) return false;
    _currentIndex = resolution;
    _syncOrderCursor();
    _reconcileRandom();
    await _parent.loadTrack(autoPlay: reason != PlaybackReason.playlistChanged);
    _notify();
    return true;
  }

  Future<bool> playPrevious({PlaybackReason reason = PlaybackReason.user}) async {
    final resolution = _resolveAdjacentIndex(next: false);
    if (resolution == null) return false;
    _currentIndex = resolution;
    _syncOrderCursor();
    _reconcileRandom();
    await _parent.loadTrack(autoPlay: reason != PlaybackReason.playlistChanged);
    _notify();
    return true;
  }

  Future<void> moveTrack(int oldIndex, int newIndex) async {
    if (oldIndex < 0 ||
        oldIndex >= _activePlaylistTracks.length ||
        newIndex < 0 ||
        newIndex >= _activePlaylistTracks.length) {
      return;
    }

    final track = _activePlaylistTracks.removeAt(oldIndex);
    _activePlaylistTracks.insert(newIndex, track);

    if (_currentIndex != null) {
      if (_currentIndex == oldIndex) {
        _currentIndex = newIndex;
      } else if (oldIndex < _currentIndex! && newIndex >= _currentIndex!) {
        _currentIndex = _currentIndex! - 1;
      } else if (oldIndex > _currentIndex! && newIndex <= _currentIndex!) {
        _currentIndex = _currentIndex! + 1;
      }
    }

    _rebuildPlayOrder();
    _reconcileRandom();
    await _syncActivePlaylistData();
    _notify();
  }

  Future<void> removeTrackAt(int index) async {
    if (index < 0 || index >= _activePlaylistTracks.length) return;
    final removedCurrent = _currentIndex == index;
    _activePlaylistTracks.removeAt(index);

    if (_activePlaylistTracks.isEmpty) {
      await clear();
      return;
    }

    if (removedCurrent) {
      _currentIndex = index.clamp(0, _activePlaylistTracks.length - 1).toInt();
      _rebuildPlayOrder();
      _reconcileRandom();
      await _parent.loadTrack(autoPlay: false);
    } else {
      if (_currentIndex != null && index < _currentIndex!) _currentIndex = _currentIndex! - 1;
      _rebuildPlayOrder();
      _reconcileRandom();
    }
    await _syncActivePlaylistData();
    _notify();
  }

  Future<void> clear() async {
    _activePlaylistTracks.clear();
    _playOrder.clear();
    _currentIndex = null;
    _currentOrderCursor = null;
    _randomManager.setPolicy(null);
    await _parent.clearPlayback();
    await _syncActivePlaylistData();
    _notify();
  }

  Future<void> ensureQueuePlaylist() async => _ensureDefaultPlaylist();

  void setMode(PlaylistMode mode) {
    _playlistMode = mode;
    _notify();
  }

  void setShuffle({
    RandomScope? scope,
    RandomStrategy? strategy,
    int avoidRecent = 2,
    int historySize = 200,
    int? seed,
  }) {
    final policy = RandomPolicy(
      scope: scope ?? RandomScope.all(),
      strategy: strategy ?? RandomStrategy.fisherYates(),
      history: RandomHistoryPolicy(
        maxEntries: historySize,
        recentWindow: avoidRecent,
      ),
      seed: seed,
      label: 'shuffle',
    );
    _randomManager.setPolicy(policy);
    _reconcileRandom();
    _notify();
  }

  void clearShuffle() => setRandomPolicy(null);

  void clearRandomHistory() {
    _randomManager.clearHistory();
    _notify();
  }

  void clearShuffleHistory() => clearRandomHistory();

  void setRandomPolicy(RandomPolicy? policy) {
    _randomManager.setPolicy(policy);
    _reconcileRandom();
    _notify();
  }

  int? resolveAdjacentIndex({required bool next}) => _resolveAdjacentIndex(next: next, peek: true);

  // --- Internal ---

  int? _resolveAdjacentIndex({required bool next, bool peek = false}) {
    if (_activePlaylistTracks.isEmpty || _playlistMode == PlaylistMode.single) return null;
    if (_playlistMode == PlaylistMode.singleLoop) return _currentIndex ?? 0;

    if (_randomManager.policy != null) {
      return _randomManager.resolveAdjacentIndex(
        next: next,
        playlistId: _activePlaylistId,
        tracks: _activePlaylistTracks,
        loop: _playlistMode == PlaylistMode.queueLoop || _playlistMode == PlaylistMode.autoQueueLoop,
        peek: peek,
      );
    }

    return _resolveSequentialAdjacentIndex(next: next);
  }

  int? _resolveSequentialAdjacentIndex({required bool next}) {
    if (_playOrder.isEmpty) return null;
    if (_currentIndex == null) return 0;

    final cursor = _currentOrderCursor ?? _playOrder.indexOf(_currentIndex!);
    if (cursor < 0) return 0;

    if (next) {
      if (cursor < _playOrder.length - 1) return _playOrder[cursor + 1];
      if (_playlistMode == PlaylistMode.queueLoop || _playlistMode == PlaylistMode.autoQueueLoop) return _playOrder[0];
      return null;
    }

    if (cursor > 0) return _playOrder[cursor - 1];
    if (_playlistMode == PlaylistMode.queueLoop || _playlistMode == PlaylistMode.autoQueueLoop) return _playOrder.last;
    return null;
  }

  void _syncOrderCursor() {
    if (_currentIndex == null) {
      _currentOrderCursor = null;
    } else {
      final cursor = _playOrder.indexOf(_currentIndex!);
      _currentOrderCursor = cursor >= 0 ? cursor : null;
    }
  }

  void _reconcileRandom() {
    _randomManager.reconcile(
      playlistId: _activePlaylistId,
      tracks: _activePlaylistTracks,
      currentTrack: currentTrack,
    );
  }

  Future<void> _syncActivePlaylistData() async {
    if (_activePlaylistId == null) return;
    final idx = _playlists.indexWhere((p) => p.id == _activePlaylistId);
    if (idx >= 0) {
      _playlists[idx] = _playlists[idx].copyWith(items: List.from(_activePlaylistTracks));
    }
  }

  Future<void> _ensureDefaultPlaylist() async {
    if (_activePlaylistId != null) return;
    if (!_playlists.any((p) => p.id == _defaultPlaylistId)) {
      _playlists.add(Playlist(id: _defaultPlaylistId, name: 'Queue', items: []));
    }
    _activePlaylistId = _defaultPlaylistId;
  }

  void _rebuildPlayOrder() {
    _playOrder..clear()..addAll(List<int>.generate(_activePlaylistTracks.length, (i) => i));
    _syncOrderCursor();
  }

  void _notify() {
    notifyListeners();
    _parent.notifyListeners();
  }
}
