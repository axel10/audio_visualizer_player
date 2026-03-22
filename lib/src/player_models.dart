import 'playlist_models.dart';
import 'random_playback_models.dart';

/// Internal interface for sub-controllers to communicate with the main controller.
abstract class AudioVisualizerParent {
  void notifyListeners();

  /// Called when a track needs to be loaded (e.g., from playlist navigation).
  Future<void> loadTrack({required bool autoPlay, Duration? position});

  /// Called when playback should be cleared.
  Future<void> clearPlayback();

  /// Called when a play request is made.
  Future<bool> handlePlayRequested();
}

/// Track transition mode.
enum FadeMode {
  /// Fade out the old track, then start and fade in the new one.
  sequential,

  /// Keep both tracks alive and overlap them during the transition window.
  crossfade,
}

/// Playback states for the player.
enum PlayerState {
  /// 初始状态：播放器已实例化，但尚未加载任何媒体源。
  idle,

  /// 加载中：正在解析文件头、缓冲网络流或初始化解码器。
  buffering,

  /// 就绪/停止：媒体已加载，进度条已更新，但未开始播放。
  ready,

  /// 播放中：音频时钟正在运行。
  playing,

  /// 暂停：保留当前播放位置。
  paused,

  /// 播放结束：到达文件末尾。
  completed,

  /// 错误：如文件损坏、解码失败等。
  error,
}

/// Represents the high-level state of a player session.
class PlayerControllerState {
  const PlayerControllerState({
    required this.position,
    required this.duration,
    required this.volume,
    required this.currentState,
    required this.playlists,
    this.randomPolicy,
    required this.playlistMode,
    this.activePlaylist,
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

  /// Active random policy, or `null` when playback is sequential.
  final RandomPolicy? randomPolicy;

  /// Active playlist mode.
  final PlaylistMode playlistMode;

  /// Currently active playlist, or `null` if none selected.
  final Playlist? activePlaylist;

  /// Current index in active playlist, or `null` if no active playlist or nothing selected.
  final int? currentIndex;

  /// Currently active track, if any.
  final AudioTrack? track;

  /// Whether shuffle/random playback is enabled.
  bool get shuffleEnabled => randomPolicy != null;

  /// Alias for compatibility with old tests/UI
  AudioTrack? get currentTrack => track;

  /// Current tracks in active playlist.
  List<AudioTrack> get items => activePlaylist?.items ?? const <AudioTrack>[];

  @override
  String toString() {
    return 'PlayerControllerState(position: $position, duration: $duration, volume: $volume, currentState: $currentState, track: ${track?.title}, randomPolicy: ${randomPolicy?.key})';
  }
}
