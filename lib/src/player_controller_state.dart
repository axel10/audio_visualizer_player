import 'player_models.dart';

/// Snapshot of the current player and playlist state.
class PlayerControllerState {
  const PlayerControllerState({
    required this.position,
    required this.duration,
    required this.volume,
    required this.currentState,
    required this.playlists,
    required this.shuffleEnabled,
    required this.repeatMode,
    this.activePlaylistId,
    this.currentIndex,
    this.track,
  });

  /// Current playback position.
  final Duration position;

  /// Total duration of the current track.
  final Duration duration;

  /// Current playback volume (0.0 to 1.0).
  final double volume;

  /// Current playback status.
  final PlayerState currentState;

  /// All available playlists.
  final List<Playlist> playlists;

  /// Whether shuffle order is enabled.
  final bool shuffleEnabled;

  /// Active repeat mode.
  final RepeatMode repeatMode;

  /// ID of currently active playlist, or `null` if none selected.
  final String? activePlaylistId;

  /// Current index in active playlist, or `null` if no active playlist or nothing selected.
  final int? currentIndex;

  /// Currently active track, if any.
  final AudioTrack? track;

  /// Alias for compatibility with old tests/UI
  AudioTrack? get currentTrack => track;

  /// Currently active playlist, or `null` if none selected.
  Playlist? get activePlaylist {
    if (activePlaylistId == null) return null;
    try {
      return playlists.firstWhere((p) => p.id == activePlaylistId);
    } catch (e) {
      return null;
    }
  }

  /// Current tracks in active playlist.
  List<AudioTrack> get items => activePlaylist?.items ?? const <AudioTrack>[];

  @override
  String toString() {
    return 'PlayerControllerState(position: $position, duration: $duration, volume: $volume, currentState: $currentState, track: ${track?.title})';
  }
}
