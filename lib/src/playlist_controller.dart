
import 'package:flutter/foundation.dart';

import 'playlist_models.dart';
import 'random_playback_models.dart';
import 'random_playback_manager.dart';

/// Manages playlists, tracks, and playback order.
class PlaylistController extends ChangeNotifier {
  PlaylistController({
    required Future<void> Function({required bool autoPlay, Duration? position})
    onLoadTrack,
    required Future<void> Function() onClearPlayback,
    required void Function() onNotifyParent,
  }) : _onLoadTrack = onLoadTrack,
       _onClearPlayback = onClearPlayback,
       _onNotifyParent = onNotifyParent;

  final Future<void> Function({required bool autoPlay, Duration? position})
  _onLoadTrack;
  final Future<void> Function() _onClearPlayback;
  final void Function() _onNotifyParent;

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
  Playlist? get activePlaylist {
    return playlistById(_activePlaylistId);
  }

  /// Current active tracks.
  List<AudioTrack> get items =>
      List<AudioTrack>.unmodifiable(_activePlaylistTracks);

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

  /// Whether any shuffle mode is currently enabled.
  bool get shuffleEnabled => _randomManager.policy != null;

  /// Whether the simple shuffle API is currently enabled.
  bool get isShuffleEnabled => _randomManager.policy != null;

  /// Stable id for the built-in queue playlist.
  String get queuePlaylistId => _defaultPlaylistId;

  String? get activePlaylistId => _activePlaylistId;

  /// Random history snapshot for UI/debugging.
  List<RandomHistoryEntry> get randomHistory => _randomManager.history;

  /// Current song index inside the active shuffle range.
  int? get currentRangeIndex => _currentRangeIndex();

  /// Current song index inside the shuffle history.
  int? get currentHistoryIndex => _currentHistoryIndex();

  /// Returns a playlist by id, or `null` if it does not exist.
  Playlist? playlistById(String? id) {
    if (id == null) return null;
    for (final playlist in _playlists) {
      if (playlist.id == id) return playlist;
    }
    return null;
  }

  // --- Methods ---

  Future<void> createPlaylist(
    String id,
    String name, {
    List<AudioTrack> items = const [],
  }) async {
    if (id == _defaultPlaylistId) throw StateError('Reserved ID');
    if (_playlists.any((p) => p.id == id)) throw StateError('Exists');
    _playlists.add(Playlist(id: id, name: name, items: items));
    notifyListeners();
    _onNotifyParent();
  }

  Future<void> removePlaylist(String id) async {
    _playlists.removeWhere((p) => p.id == id);
    if (_activePlaylistId == id) {
      await switchPlaylist(_defaultPlaylistId);
    }
    notifyListeners();
    _onNotifyParent();
  }

  Future<void> setActivePlaylist(
    String id, {
    int startIndex = 0,
    bool autoPlay = false,
  }) async {
    final playlist = playlistById(id);
    if (playlist == null) return;

    final isSamePlaylist = _activePlaylistId == id;
    if (isSamePlaylist && _currentIndex == startIndex) {
      // Still need to trigger a load if we are forcing it (e.g. current track replay)
      await _onLoadTrack(autoPlay: autoPlay);
      return;
    }

    _activePlaylistId = id;
    if (!isSamePlaylist) {
      _activePlaylistTracks
        ..clear()
        ..addAll(playlist.items);
      _rebuildPlayOrder();
    }

    if (_activePlaylistTracks.isNotEmpty) {
      _currentIndex = startIndex.clamp(0, _activePlaylistTracks.length - 1).toInt();
    } else {
      _currentIndex = null;
    }
    
    syncOrderCursorFromCurrentIndex();
    reconcileRandomState();
    await _onLoadTrack(autoPlay: autoPlay);
    
    notifyListeners();
    _onNotifyParent();
  }

  Future<void> switchPlaylist(String id) async {
    await setActivePlaylist(id);
  }

  Future<void> addTracks(List<AudioTrack> tracks) async {
    final wasEmpty = _activePlaylistTracks.isEmpty;
    await _ensureDefaultPlaylist();
    _activePlaylistTracks.addAll(tracks);
    _rebuildPlayOrder();

    if (wasEmpty && _activePlaylistTracks.isNotEmpty) {
      _currentIndex = 0;
      reconcileRandomState();
      await _onLoadTrack(autoPlay: false);
    } else {
      reconcileRandomState();
    }

    await _syncActivePlaylist();
    notifyListeners();
    _onNotifyParent();
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
          reconcileRandomState();
          await _onLoadTrack(autoPlay: false);
        } else {
          reconcileRandomState();
        }
      }
      notifyListeners();
      _onNotifyParent();
    }
  }

  Future<void> updatePlaylistTracks(
    String id,
    List<AudioTrack> newTracks,
  ) async {
    final idx = _playlists.indexWhere((p) => p.id == id);
    if (idx >= 0) {
      _playlists[idx] = _playlists[idx].copyWith(items: newTracks);
      if (_activePlaylistId == id) {
        _activePlaylistTracks
          ..clear()
          ..addAll(newTracks);

        final currentId = currentTrack?.id;
        final wasEmpty = _activePlaylistTracks.isEmpty;
        _rebuildPlayOrder();

        if (currentId != null) {
          final newIdx = _activePlaylistTracks.indexWhere((t) => t.id == currentId);
          _currentIndex = newIdx >= 0 ? newIdx : null;
          reconcileRandomState();
          if (newIdx < 0) {
            // Current track removed, load next available or clear
            await _onLoadTrack(autoPlay: false);
          }
        } else {
          _currentIndex = _activePlaylistTracks.isNotEmpty ? 0 : null;
          reconcileRandomState();
          if (wasEmpty && _currentIndex != null) {
            await _onLoadTrack(autoPlay: false);
          }
        }
      }
    }
    notifyListeners();
    _onNotifyParent();
  }

  Future<void> insertTrack(int index, AudioTrack track) async {
    final wasEmpty = _activePlaylistTracks.isEmpty;
    _activePlaylistTracks.insert(index, track);
    _rebuildPlayOrder();

    if (wasEmpty) {
      _currentIndex = 0;
      reconcileRandomState();
      await _onLoadTrack(autoPlay: false);
    } else {
      if (_currentIndex != null && index <= _currentIndex!) {
        _currentIndex = _currentIndex! + 1;
      }
      reconcileRandomState();
    }

    await _syncActivePlaylist();
    notifyListeners();
    _onNotifyParent();
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
      if (current != null &&
          current.id == track.id &&
          current.uri != track.uri) {
        await _onLoadTrack(autoPlay: false);
      }
      notifyListeners();
      _onNotifyParent();
    }
  }

  /// 跳到下一首，随机模式下会优先沿用随机历史。
  Future<bool> playNext({PlaybackReason reason = PlaybackReason.user}) async {
    final resolution = _resolveAdjacentIndex(next: true, peek: false);
    if (resolution.index == null) return false;
    _currentIndex = resolution.index;
    _afterCurrentIndexChanged(resolution);
    await _onLoadTrack(autoPlay: reason != PlaybackReason.playlistChanged);
    notifyListeners();
    _onNotifyParent();
    return true;
  }

  /// 跳到上一首，随机模式下会回退随机历史。
  Future<bool> playPrevious({
    PlaybackReason reason = PlaybackReason.user,
  }) async {
    final resolution = _resolveAdjacentIndex(next: false, peek: false);
    if (resolution.index == null) return false;
    _currentIndex = resolution.index;
    _afterCurrentIndexChanged(resolution);
    await _onLoadTrack(autoPlay: reason != PlaybackReason.playlistChanged);
    notifyListeners();
    _onNotifyParent();
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
    reconcileRandomState();
    await _syncActivePlaylist();
    notifyListeners();
    _onNotifyParent();
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
      reconcileRandomState();
      await _onLoadTrack(autoPlay: false);
    } else {
      if (_currentIndex != null && index < _currentIndex!) {
        _currentIndex = _currentIndex! - 1;
      }
      _rebuildPlayOrder();
      reconcileRandomState();
    }
    await _syncActivePlaylist();
    notifyListeners();
    _onNotifyParent();
  }

  /// 清空当前播放列表和播放状态。
  Future<void> clear() async {
    _activePlaylistTracks.clear();
    _playOrder.clear();
    _currentIndex = null;
    _currentOrderCursor = null;
    _randomManager.setPolicy(null);
    await _onClearPlayback();
    await _syncActivePlaylist();
    notifyListeners();
    _onNotifyParent();
  }

  /// 确保内置队列播放列表已创建。
  Future<void> ensureQueuePlaylist() async {
    await _ensureDefaultPlaylist();
  }

  /// 设置顺序播放模式。
  void setMode(PlaylistMode mode) {
    _playlistMode = mode;
    notifyListeners();
    _onNotifyParent();
  }

  /// Configures the simple shuffle API used by most app code.
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
    reconcileRandomState();
    notifyListeners();
    _onNotifyParent();
  }

  /// Legacy convenience alias for enabling or disabling shuffle quickly.
  void setShuffleEnabled(bool enabled) {
    if (!enabled) {
      clearShuffle();
      return;
    }
    setShuffle();
  }

  /// Turns off the simple shuffle API and clears its history.
  void clearShuffle() {
    _randomManager.setPolicy(null);
    notifyListeners();
    _onNotifyParent();
  }

  /// 设置完整随机策略。
  void setRandomPolicy(RandomPolicy? policy) {
    _randomManager.setPolicy(policy);
    reconcileRandomState();
    notifyListeners();
    _onNotifyParent();
  }

  /// 清除随机历史，但保留当前随机策略。
  void clearRandomHistory() {
    _randomManager.clearHistory();
    notifyListeners();
    _onNotifyParent();
  }

  /// Clears the simple shuffle history without disabling shuffle.
  void clearShuffleHistory() {
    clearRandomHistory();
  }

  /// 让随机历史与当前播放状态对齐。
  void reconcileRandomState() {
    _randomManager.reconcile(
      playlistId: _activePlaylistId,
      tracks: _activePlaylistTracks,
      currentTrack: currentTrack,
    );
  }

  /// 仅计算下一首或上一首索引，不真正切歌。
  int? resolveAdjacentIndex({required bool next}) {
    return _resolveAdjacentIndex(next: next, peek: true).index;
  }

  /// 把当前索引同步到顺序播放游标。
  void syncOrderCursorFromCurrentIndex() {
    if (_currentIndex == null) {
      _currentOrderCursor = null;
      return;
    }
    final cursor = _playOrder.indexOf(_currentIndex!);
    _currentOrderCursor = cursor >= 0 ? cursor : null;
  }

  /// 直接更新当前索引，并同步相关状态。
  void updateCurrentIndex(int? index) {
    _currentIndex = index;
    syncOrderCursorFromCurrentIndex();
    reconcileRandomState();
  }

  // --- Internal ---

  _NavigationResolution _resolveAdjacentIndex({
    required bool next,
    bool peek = false,
  }) {
    if (_activePlaylistTracks.isEmpty) {
      return const _NavigationResolution(index: null);
    }

    if (_playlistMode == PlaylistMode.single) {
      return const _NavigationResolution(index: null);
    }

    if (_playlistMode == PlaylistMode.singleLoop) {
      return _NavigationResolution(
        index: _currentIndex ?? 0,
      );
    }

    if (shuffleEnabled) {
      final index = _randomManager.resolveAdjacentIndex(
        next: next,
        playlistId: _activePlaylistId,
        tracks: _activePlaylistTracks,
        loop: _playlistMode == PlaylistMode.queueLoop ||
            _playlistMode == PlaylistMode.autoQueueLoop,
        peek: peek,
      );
      return _NavigationResolution(index: index);
    }

    return _resolveSequentialAdjacentIndex(next: next);
  }

  _NavigationResolution _resolveSequentialAdjacentIndex({required bool next}) {
    if (_playOrder.isEmpty) return const _NavigationResolution(index: null);
    if (_currentIndex == null) return const _NavigationResolution(index: 0);

    final cursor = _currentOrderCursor ?? _playOrder.indexOf(_currentIndex!);
    if (cursor < 0) {
      return const _NavigationResolution(index: 0);
    }

    if (next) {
      if (cursor < _playOrder.length - 1) {
        return _NavigationResolution(index: _playOrder[cursor + 1]);
      }
      if (_playlistMode == PlaylistMode.queueLoop ||
          _playlistMode == PlaylistMode.autoQueueLoop) {
        return _NavigationResolution(index: _playOrder[0]);
      }
      return const _NavigationResolution(index: null);
    }

    if (cursor > 0) {
      return _NavigationResolution(index: _playOrder[cursor - 1]);
    }
    if (_playlistMode == PlaylistMode.queueLoop ||
        _playlistMode == PlaylistMode.autoQueueLoop) {
      return _NavigationResolution(index: _playOrder.last);
    }
    return const _NavigationResolution(index: null);
  }

  void _afterCurrentIndexChanged(_NavigationResolution resolution) {
    syncOrderCursorFromCurrentIndex();
    reconcileRandomState();
  }

  Future<void> _syncActivePlaylist() async {
    if (_activePlaylistId == null) return;
    final idx = _playlists.indexWhere((p) => p.id == _activePlaylistId);
    if (idx >= 0) {
      _playlists[idx] = _playlists[idx].copyWith(
        items: List.from(_activePlaylistTracks),
      );
    }
  }

  Future<void> _ensureDefaultPlaylist() async {
    if (_activePlaylistId != null) return;
    if (!_playlists.any((p) => p.id == _defaultPlaylistId)) {
      _playlists.add(
        Playlist(id: _defaultPlaylistId, name: 'Queue', items: []),
      );
    }
    _activePlaylistId = _defaultPlaylistId;
  }

  void _rebuildPlayOrder() {
    _playOrder
      ..clear()
      ..addAll(List<int>.generate(_activePlaylistTracks.length, (i) => i));
    syncOrderCursorFromCurrentIndex();
  }

  int? _currentRangeIndex() {
    return _randomManager.currentRangeIndex(
      playlistId: _activePlaylistId,
      tracks: _activePlaylistTracks,
      currentTrack: currentTrack,
    );
  }

  int? _currentHistoryIndex() {
    return _randomManager.currentHistoryIndex(
      playlistId: _activePlaylistId,
      currentTrack: currentTrack,
    );
  }
}

class _NavigationResolution {
  const _NavigationResolution({
    required this.index,
  });
  final int? index;
}
