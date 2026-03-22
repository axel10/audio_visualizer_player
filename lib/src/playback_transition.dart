import 'dart:async';
import 'player_controller.dart';
import 'rust/api/simple_api.dart';

/// Defines the strategy for transitioning between two audio tracks.
abstract class PlaybackTransition {
  const PlaybackTransition();

  /// Executes the transition logic.
  Future<void> execute({
    required PlayerController player,
    required String uri,
    required bool autoPlay,
    Duration? position,
  });
}

/// A sequential fade transition: fade out current track, then load and fade in new track.
class SequentialFadeTransition extends PlaybackTransition {
  const SequentialFadeTransition({
    required this.duration,
    required this.targetVolume,
  });

  final Duration duration;
  final double targetVolume;

  @override
  Future<void> execute({
    required PlayerController player,
    required String uri,
    required bool autoPlay,
    Duration? position,
  }) async {
    player.nextFadeSequence();
    final seq = player.fadeSequence;

    if (player.isPlaying) {
      player.setFadeActive(true);
      try {
        final fadedOut = await player.fadeNativeVolume(
          from: player.volume,
          to: 0.0,
          duration: duration,
          sequence: seq,
        );
        if (!fadedOut) return;
      } finally {
        // Only set inactive if we're not about to fade in
        if (!autoPlay) player.setFadeActive(false);
      }
    }

    await player.load(uri, nativeVolume: autoPlay ? 0.0 : player.volume);
    if (player.fadeSequence != seq) return;

    if (position != null) await player.seek(position);

    if (autoPlay) {
      player.setFadeActive(true);
      try {
        await player.play();
        await player.fadeNativeVolume(
          from: 0.0,
          to: targetVolume,
          duration: duration,
          sequence: seq,
          followTargetVolume: true,
        );
      } finally {
        player.setFadeActive(false);
      }
    }
  }
}

/// A crossfade transition: starts playing the new track while the old one is still playing.
class CrossfadeTransition extends PlaybackTransition {
  const CrossfadeTransition({required this.duration});

  final Duration duration;

  @override
  Future<void> execute({
    required PlayerController player,
    required String uri,
    required bool autoPlay,
    Duration? position,
  }) async {
    player.nextFadeSequence();
    final seq = player.fadeSequence;

    // Rust side crossfade
    await crossfadeToAudioFile(
      path: uri,
      durationMs: duration.inMilliseconds,
    );
    
    if (player.fadeSequence != seq) return;

    final durationMs = await getAudioDurationMs();
    player.applySnapshot(
      uri,
      Duration.zero,
      Duration(milliseconds: durationMs.toInt()),
      true, // Crossfade implicitly starts playing
      player.volume,
    );
  }
}

/// An immediate transition: stops current track and loads new track immediately.
class ImmediateTransition extends PlaybackTransition {
  const ImmediateTransition();

  @override
  Future<void> execute({
    required PlayerController player,
    required String uri,
    required bool autoPlay,
    Duration? position,
  }) async {
    player.nextFadeSequence();
    await player.load(uri);
    if (position != null) await player.seek(position);
    if (autoPlay) await player.play();
  }
}
