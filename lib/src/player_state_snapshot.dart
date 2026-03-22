import 'package:flutter/foundation.dart';
import 'player_models.dart';
import 'playlist_models.dart';
import 'random_playback_models.dart';
import 'rust/api/simple_api.dart';

/// An immutable snapshot of the entire player state at a specific point in time.
@immutable
class PlayerStateSnapshot {
  const PlayerStateSnapshot({
    required this.position,
    required this.duration,
    required this.volume,
    required this.currentState,
    required this.playlists,
    required this.randomPolicy,
    required this.playlistMode,
    this.activePlaylist,
    this.currentIndex,
    this.track,
    this.error,
    required this.equalizerConfig,
    this.isTransitioning = false,
  });

  final Duration position;
  final Duration duration;
  final double volume;
  final PlayerState currentState;
  final List<Playlist> playlists;
  final RandomPolicy? randomPolicy;
  final PlaylistMode playlistMode;
  final Playlist? activePlaylist;
  final int? currentIndex;
  final AudioTrack? track;
  final String? error;
  final EqualizerConfig equalizerConfig;
  final bool isTransitioning;

  PlayerStateSnapshot copyWith({
    Duration? position,
    Duration? duration,
    double? volume,
    PlayerState? currentState,
    List<Playlist>? playlists,
    RandomPolicy? randomPolicy,
    PlaylistMode? playlistMode,
    Playlist? activePlaylist,
    int? currentIndex,
    AudioTrack? track,
    String? error,
    EqualizerConfig? equalizerConfig,
    bool? isTransitioning,
  }) {
    return PlayerStateSnapshot(
      position: position ?? this.position,
      duration: duration ?? this.duration,
      volume: volume ?? this.volume,
      currentState: currentState ?? this.currentState,
      playlists: playlists ?? this.playlists,
      randomPolicy: randomPolicy ?? this.randomPolicy,
      playlistMode: playlistMode ?? this.playlistMode,
      activePlaylist: activePlaylist ?? this.activePlaylist,
      currentIndex: currentIndex ?? this.currentIndex,
      track: track ?? this.track,
      error: error ?? this.error,
      equalizerConfig: equalizerConfig ?? this.equalizerConfig,
      isTransitioning: isTransitioning ?? this.isTransitioning,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PlayerStateSnapshot &&
          runtimeType == other.runtimeType &&
          position == other.position &&
          duration == other.duration &&
          volume == other.volume &&
          currentState == other.currentState &&
          listEquals(playlists, other.playlists) &&
          randomPolicy == other.randomPolicy &&
          playlistMode == other.playlistMode &&
          activePlaylist == other.activePlaylist &&
          currentIndex == other.currentIndex &&
          track == other.track &&
          error == other.error &&
          equalizerConfig == other.equalizerConfig &&
          isTransitioning == other.isTransitioning;

  @override
  int get hashCode =>
      position.hashCode ^
      duration.hashCode ^
      volume.hashCode ^
      currentState.hashCode ^
      playlists.hashCode ^
      randomPolicy.hashCode ^
      playlistMode.hashCode ^
      activePlaylist.hashCode ^
      currentIndex.hashCode ^
      track.hashCode ^
      error.hashCode ^
      equalizerConfig.hashCode ^
      isTransitioning.hashCode;

  @override
  String toString() {
    return 'PlayerStateSnapshot(track: ${track?.title}, state: $currentState, pos: ${position.inSeconds}s/${duration.inSeconds}s)';
  }
}
