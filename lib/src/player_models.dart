/// A track item used by playlist APIs.
class AudioTrack {
  const AudioTrack({
    required this.id,
    required this.uri,
    this.title,
    this.artist,
    this.album,
    this.duration,
    this.extras = const <String, Object?>{},
  });

  /// Stable unique track id.
  final String id;

  /// Audio URI/path understood by the plugin.
  final String uri;

  /// Optional display title.
  final String? title;

  /// Optional artist name.
  final String? artist;

  /// Optional album name.
  final String? album;

  /// Optional known duration.
  final Duration? duration;

  /// Optional custom metadata.
  final Map<String, Object?> extras;
}

/// A collection of audio tracks with metadata.
class Playlist {
  const Playlist({required this.id, required this.name, required this.items});

  /// Unique playlist identifier.
  final String id;

  /// Display name of the playlist.
  final String name;

  /// List of tracks in this playlist.
  final List<AudioTrack> items;

  /// Creates a copy with optionally replaced fields.
  Playlist copyWith({String? id, String? name, List<AudioTrack>? items}) {
    return Playlist(
      id: id ?? this.id,
      name: name ?? this.name,
      items: items ?? this.items,
    );
  }
}

/// Repeat behavior used by playlist playback.
enum RepeatMode { off, one, all }

/// Reason for a track transition.
enum PlaybackReason { user, autoNext, ended, playlistChanged }

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

class PlayerControllerState {
  const PlayerControllerState({
    required this.position,
    required this.duration,
    required this.volume,
    required this.currentState,
    required this.playlists,
    required this.shuffleEnabled,
    required this.repeatMode,
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

  /// Whether shuffle order is enabled.
  final bool shuffleEnabled;

  /// Active repeat mode.
  final RepeatMode repeatMode;

  /// Currently active playlist, or `null` if none selected.
  final Playlist? activePlaylist;

  /// Current index in active playlist, or `null` if no active playlist or nothing selected.
  final int? currentIndex;

  /// Currently active track, if any.
  final AudioTrack? track;

  /// Alias for compatibility with old tests/UI
  AudioTrack? get currentTrack => track;

  /// Current tracks in active playlist.
  List<AudioTrack> get items => activePlaylist?.items ?? const <AudioTrack>[];

  @override
  String toString() {
    return 'PlayerControllerState(position: $position, duration: $duration, volume: $volume, currentState: $currentState, track: ${track?.title})';
  }
}
