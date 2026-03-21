import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'playlist_models.dart';

/// Manages playlists, tracks, and playback order (shuffle/repeat).
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

  bool _shuffleEnabled = false;
  PlaylistMode _playlistMode = PlaylistMode.queue;
  final math.Random _shuffleRandom = math.Random();

  /// All user-visible playlists.
  List<Playlist> get playlists => List<Playlist>.unmodifiable(
    _playlists.where((p) => p.id != _defaultPlaylistId).toList(),
  );

  /// Current active playlist.
  Playlist? get activePlaylist {
    if (_activePlaylistId == null) return null;
    return _playlists.firstWhere(
      (p) => p.id == _activePlaylistId,
      orElse: () => _playlists.first,
    );
  }

  /// Current active tracks.
  List<AudioTrack> get items =>
      List<AudioTrack>.unmodifiable(_activePlaylistTracks);

  int? get currentIndex => _currentIndex;

  AudioTrack? get currentTrack =>
      _currentIndex == null || _currentIndex! >= _activePlaylistTracks.length
      ? null
      : _activePlaylistTracks[_currentIndex!];

  bool get shuffleEnabled => _shuffleEnabled;
  PlaylistMode get mode => _playlistMode;

  String? get activePlaylistId => _activePlaylistId;

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

  Future<void> setActivePlaylist(
    String id, {
    int startIndex = 0,
    bool autoPlay = false,
  }) async {
    final pl = _playlists.firstWhere(
      (p) => p.id == id,
      orElse: () => throw StateError('Not found'),
    );
    _activePlaylistId = id;
    _activePlaylistTracks.clear();
    _activePlaylistTracks.addAll(pl.items);

    if (_activePlaylistTracks.isEmpty) {
      _currentIndex = null;
    } else {
      _currentIndex = startIndex.clamp(0, _activePlaylistTracks.length - 1);
    }

    _rebuildPlayOrder(keepCurrentAtFront: _shuffleEnabled);
    if (_currentIndex != null) {
      await _onLoadTrack(autoPlay: autoPlay);
    }
    notifyListeners();
    _onNotifyParent();
  }

  Future<void> addTrack(AudioTrack track) async {
    if (_activePlaylistId == null) await _ensureDefaultPlaylist();
    _activePlaylistTracks.add(track);
    if (_currentIndex == null) {
      _currentIndex = 0;
      _rebuildPlayOrder(keepCurrentAtFront: _shuffleEnabled);
      await _onLoadTrack(autoPlay: false);
    } else {
      _rebuildPlayOrder(keepCurrentAtFront: _shuffleEnabled);
    }
    await _syncActivePlaylist();
    notifyListeners();
    _onNotifyParent();
  }

  Future<void> addTracks(List<AudioTrack> tracks) async {
    if (tracks.isEmpty) return;
    if (_activePlaylistId == null) await _ensureDefaultPlaylist();
    final wasEmpty = _activePlaylistTracks.isEmpty;
    _activePlaylistTracks.addAll(tracks);
    if (wasEmpty) {
      _currentIndex = 0;
      _rebuildPlayOrder(keepCurrentAtFront: _shuffleEnabled);
      await _onLoadTrack(autoPlay: false);
    } else {
      _rebuildPlayOrder(keepCurrentAtFront: _shuffleEnabled);
    }
    await _syncActivePlaylist();
    notifyListeners();
    _onNotifyParent();
  }

  Future<bool> playNext({PlaybackReason reason = PlaybackReason.user}) async {
    final next = resolveAdjacentIndex(next: true);
    if (next == null) return false;
    _currentIndex = next;
    syncOrderCursorFromCurrentIndex();
    await _onLoadTrack(autoPlay: reason != PlaybackReason.playlistChanged);
    notifyListeners();
    _onNotifyParent();
    return true;
  }

  Future<bool> playPrevious({
    PlaybackReason reason = PlaybackReason.user,
  }) async {
    final prev = resolveAdjacentIndex(next: false);
    if (prev == null) return false;
    _currentIndex = prev;
    syncOrderCursorFromCurrentIndex();
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

    // Update currentIndex if affected
    if (_currentIndex != null) {
      if (_currentIndex == oldIndex) {
        _currentIndex = newIndex;
      } else if (oldIndex < _currentIndex! && newIndex >= _currentIndex!) {
        _currentIndex = _currentIndex! - 1;
      } else if (oldIndex > _currentIndex! && newIndex <= _currentIndex!) {
        _currentIndex = _currentIndex! + 1;
      }
    }

    _rebuildPlayOrder(keepCurrentAtFront: _shuffleEnabled);
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
      _currentIndex = index.clamp(0, _activePlaylistTracks.length - 1);
      _rebuildPlayOrder(keepCurrentAtFront: _shuffleEnabled);
      await _onLoadTrack(autoPlay: false);
    } else {
      if (_currentIndex != null && index < _currentIndex!) {
        _currentIndex = _currentIndex! - 1;
      }
      _rebuildPlayOrder(keepCurrentAtFront: _shuffleEnabled);
    }
    await _syncActivePlaylist();
    notifyListeners();
    _onNotifyParent();
  }

  Future<void> clear() async {
    _activePlaylistTracks.clear();
    _playOrder.clear();
    _currentIndex = null;
    _currentOrderCursor = null;
    await _onClearPlayback();
    await _syncActivePlaylist();
    notifyListeners();
    _onNotifyParent();
  }

  void setMode(PlaylistMode mode) {
    _playlistMode = mode;
    notifyListeners();
    _onNotifyParent();
  }

  void setShuffle(bool enabled) {
    if (_shuffleEnabled == enabled) return;
    _shuffleEnabled = enabled;
    _rebuildPlayOrder(keepCurrentAtFront: true);
    notifyListeners();
    _onNotifyParent();
  }

  int? resolveAdjacentIndex({required bool next}) {
    if (_activePlaylistTracks.isEmpty || _playOrder.isEmpty) return null;
    if (_currentIndex == null) return 0;

    final cursor = _currentOrderCursor ?? _playOrder.indexOf(_currentIndex!);
    if (cursor < 0) return 0;

    if (next) {
      if (cursor < _playOrder.length - 1) {
        return _playOrder[cursor + 1];
      } else {
        if (_playlistMode == PlaylistMode.queueLoop ||
            _playlistMode == PlaylistMode.autoQueueLoop) {
          return _playOrder[0];
        }
        return null;
      }
    } else {
      if (cursor > 0) {
        return _playOrder[cursor - 1];
      } else {
        if (_playlistMode == PlaylistMode.queueLoop ||
            _playlistMode == PlaylistMode.autoQueueLoop) {
          return _playOrder.last;
        }
        return null;
      }
    }
  }

  void syncOrderCursorFromCurrentIndex() {
    if (_currentIndex != null && _playOrder.contains(_currentIndex!)) {
      _currentOrderCursor = _playOrder.indexOf(_currentIndex!);
    }
  }

  // --- Internal ---

  void _rebuildPlayOrder({bool keepCurrentAtFront = false}) {
    final len = _activePlaylistTracks.length;
    _playOrder.clear();
    if (len == 0) {
      _currentOrderCursor = null;
      return;
    }

    final indices = List<int>.generate(len, (i) => i);
    if (_shuffleEnabled) {
      if (keepCurrentAtFront && _currentIndex != null) {
        indices.remove(_currentIndex);
        indices.shuffle(_shuffleRandom);
        _playOrder.add(_currentIndex!);
        _playOrder.addAll(indices);
        _currentOrderCursor = 0;
      } else {
        indices.shuffle(_shuffleRandom);
        _playOrder.addAll(indices);
        _currentOrderCursor = _currentIndex != null
            ? _playOrder.indexOf(_currentIndex!)
            : 0;
      }
    } else {
      _playOrder.addAll(indices);
      _currentOrderCursor = _currentIndex ?? 0;
    }
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
        const Playlist(id: _defaultPlaylistId, name: 'Queue', items: []),
      );
    }
    _activePlaylistId = _defaultPlaylistId;
  }

  void updateCurrentIndex(int? index) {
    _currentIndex = index;
    syncOrderCursorFromCurrentIndex();
  }
}
