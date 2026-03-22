import 'dart:math' as math;

import 'playlist_models.dart';
import 'random_playback_models.dart';

/// Manages the state and logic for random playback (shuffle/random).
class RandomPlaybackManager {
  RandomPlaybackManager();

  /// The current policy being applied.
  RandomPolicy? _policy;

  /// The current random history for back/forward navigation.
  final List<RandomHistoryEntry> _history = [];

  /// Current position in history.
  int? _historyCursor;

  /// The current shuffle deck (for Fisher-Yates and Sequential).
  final List<int> _deck = [];

  /// The current position in the deck.
  int? _deckCursor;

  /// A signature used to detect when the candidate list has changed.
  String? _deckSignature;

  /// Random generator instance.
  math.Random _random = math.Random();

  // --- Getters ---

  RandomPolicy? get policy => _policy;
  List<RandomHistoryEntry> get history => List.unmodifiable(_history);
  int? get historyCursor => _historyCursor;
  List<int> get currentDeck => List.unmodifiable(_deck);
  int? get deckCursor => _deckCursor;

  // --- Calculated Getters ---

  /// Returns the current track's index within the active range (deck).
  int? currentRangeIndex({
    required String? playlistId,
    required List<AudioTrack> tracks,
    required AudioTrack? currentTrack,
  }) {
    if (currentTrack == null || _deck.isEmpty) return null;
    final currentId = currentTrack.id;
    for (var i = 0; i < _deck.length; i++) {
      if (tracks[_deck[i]].id == currentId) return i;
    }
    return null;
  }

  /// Returns the current track's index within the history.
  int? currentHistoryIndex({
    required String? playlistId,
    required AudioTrack? currentTrack,
  }) {
    if (currentTrack == null || _historyCursor == null) return null;
    return _historyCursor;
  }

  // --- Public API ---

  /// Updates the current policy and resets state if necessary.
  void setPolicy(RandomPolicy? policy) {
    if (_policy?.key == policy?.key) return;
    _policy = policy;
    _random = policy?.seed == null ? math.Random() : math.Random(policy!.seed!);
    _clearState();
  }

  /// Clears history but keeps the policy.
  void clearHistory() {
    _history.clear();
    _historyCursor = null;
  }

  /// Clears everything.
  void _clearState() {
    _history.clear();
    _historyCursor = null;
    _deck.clear();
    _deckCursor = null;
    _deckSignature = null;
  }

  /// Keeps the internal state in sync with the current playback status.
  void reconcile({
    required String? playlistId,
    required List<AudioTrack> tracks,
    required AudioTrack? currentTrack,
  }) {
    final policy = _policy;
    if (policy == null || currentTrack == null) {
      _clearState();
      return;
    }

    _trimHistory(policy.history.maxEntries);

    // Sync history cursor
    final lastCursor = _findLastHistoryCursorForTrackId(currentTrack.id);
    if (lastCursor != null) {
      _historyCursor = lastCursor;
    } else {
      // If not in history, append it (forcefully, since it's the current track)
      _appendHistory(
        track: currentTrack,
        playlistId: playlistId,
        index: tracks.indexWhere((t) => t.id == currentTrack.id),
        policyKey: policy.key,
        limit: policy.history.maxEntries,
      );
      _historyCursor = _history.length - 1;
    }

    // Sync deck if needed
    if (policy.strategy.kind == RandomStrategyKind.fisherYates ||
        policy.strategy.kind == RandomStrategyKind.sequential) {
      final context = _buildContext_internal(playlistId, tracks);
      final candidates = policy.scope.resolve(context);
      _syncDeck(context, candidates);
    }
  }

  /// Resolves the next (or previous) index.
  int? resolveAdjacentIndex({
    required bool next,
    required String? playlistId,
    required List<AudioTrack> tracks,
    required bool loop,
    bool peek = false,
  }) {
    final policy = _policy;
    if (policy == null || tracks.isEmpty) return null;

    final context = _buildContext_internal(playlistId, tracks);

    // 1. Deck-based strategies (Sequential, Fisher-Yates)
    if (policy.strategy.kind == RandomStrategyKind.sequential ||
        policy.strategy.kind == RandomStrategyKind.fisherYates) {
      final candidates = policy.scope.resolve(context);
      if (candidates.isEmpty) return null;

      _syncDeck(context, candidates);
      var cursor = _deckCursor ?? _findCurrentDeckCursor(tracks, context.currentIndex);

      if (next) {
        if (cursor != null && cursor < _deck.length - 1) {
          final target = cursor + 1;
          if (!peek) _deckCursor = target;
          return _deck[target];
        }
        if (loop) {
          if (!peek) _deckCursor = 0;
          return _deck[0];
        }
      } else {
        if (cursor != null && cursor > 0) {
          final target = cursor - 1;
          if (!peek) _deckCursor = target;
          return _deck[target];
        }
        if (loop) {
          final target = _deck.length - 1;
          if (!peek) _deckCursor = target;
          return _deck[target];
        }
      }
      return null;
    }

    // 2. Random-based strategies (Random, Weighted, Custom)
    final cursor = _historyCursor;
    if (cursor != null) {
      if (next && cursor < _history.length - 1) {
        final target = cursor + 1;
        if (!peek) _historyCursor = target;
        return _history[target].trackIndex;
      }
      if (!next && cursor > 0) {
        final target = cursor - 1;
        if (!peek) _historyCursor = target;
        return _history[target].trackIndex;
      }
      if (!next && loop && _history.isNotEmpty) {
        final target = _history.length - 1;
        if (!peek) _historyCursor = target;
        return _history[target].trackIndex;
      }
    }

    // If "previous" and we hit history start, can't go back unless loop (handled above)
    if (!next) return null;

    // Pick a new random candidate
    final candidates = policy.scope.resolve(context);
    if (candidates.isEmpty) return null;

    // Avoid recent tracks if configured
    final recentIds = _history
        .sublist(
          (_history.length - policy.history.recentWindow).clamp(0, _history.length),
        )
        .map((e) => e.trackId)
        .toSet();

    final filtered = candidates.where((idx) {
      final track = context.trackAt(idx);
      return track != null && !recentIds.contains(track.id);
    }).toList();

    final usable = filtered.isEmpty ? candidates : filtered;
    final selected = policy.strategy.select(_random, usable, context);

    if (peek) return selected;

    // Record in history if it's a new "next" selection
    _appendHistory(
      track: tracks[selected],
      playlistId: playlistId,
      index: selected,
      policyKey: policy.key,
      limit: policy.history.maxEntries,
    );
    _historyCursor = _history.length - 1;

    return selected;
  }

  // --- Internal Helpers ---

  RandomSelectionContext _buildContext_internal(
    String? playlistId,
    List<AudioTrack> tracks,
  ) {
    return RandomSelectionContext(
      playlistId: playlistId,
      tracks: tracks,
      currentIndex: _deckCursor != null && _deckCursor! < _deck.length
          ? _deck[_deckCursor!]
          : null, // This is tricky, usually we'd pass the actual current index
      history: _history,
      policyKey: _policy?.key ?? '',
    );
  }

  void _syncDeck(RandomSelectionContext context, List<int> candidates) {
    final signature = candidates
        .map((i) => context.trackAt(i)?.id ?? '$i')
        .join('|');
    if (_deckSignature == signature && _deck.length == candidates.length) {
      return;
    }

    _deckSignature = signature;
    _deck
      ..clear()
      ..addAll(candidates);

    if (_policy?.strategy.kind == RandomStrategyKind.fisherYates) {
      _deck.shuffle(_random);
    }
    _deckCursor = _findCurrentDeckCursor(context.tracks, context.currentIndex);
  }

  int? _findCurrentDeckCursor(List<AudioTrack> tracks, int? currentIndex) {
    if (currentIndex == null || _deck.isEmpty) return null;
    final currentId = tracks[currentIndex].id;
    for (var i = 0; i < _deck.length; i++) {
        if (tracks[_deck[i]].id == currentId) return i;
    }
    return null;
  }

  void _trimHistory(int limit) {
    if (limit <= 0) {
      _history.clear();
      _historyCursor = null;
      return;
    }
    while (_history.length > limit) {
      _history.removeAt(0);
      if (_historyCursor != null) {
        _historyCursor = (_historyCursor! - 1).clamp(0, _history.length - 1);
      }
    }
  }

  void _appendHistory({
    required AudioTrack track,
    required String? playlistId,
    required int index,
    required String policyKey,
    required int limit,
  }) {
    if (limit <= 0) return;
    
    // Avoid duplicate adjacent history entries of the same track
    if (_history.isNotEmpty && _history.last.trackId == track.id) {
        return;
    }

    _history.add(RandomHistoryEntry(
      trackId: track.id,
      playlistId: playlistId,
      trackIndex: index,
      generatedAt: DateTime.now(),
      policyKey: policyKey,
    ));
    _trimHistory(limit);
  }

  int? _findLastHistoryCursorForTrackId(String id) {
    for (var i = _history.length - 1; i >= 0; i--) {
      if (_history[i].trackId == id) return i;
    }
    return null;
  }
}
