import 'package:audio_visualizer_player/audio_visualizer_player.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AudioVisualizerPlayerController playlist API', () {
    test('starts with empty playlist state', () {
      final controller = AudioVisualizerPlayerController();
      addTearDown(controller.dispose);

      expect(controller.playlist, isEmpty);
      expect(controller.currentIndex, isNull);
      expect(controller.currentTrack, isNull);
      expect(controller.shuffleEnabled, isFalse);
      expect(controller.repeatMode, RepeatMode.off);

      final state = controller.playlistState;
      expect(state.items, isEmpty);
      expect(state.currentIndex, isNull);
      expect(state.currentTrack, isNull);
      expect(state.shuffleEnabled, isFalse);
      expect(state.repeatMode, RepeatMode.off);
    });

    test('repeat and shuffle changes are reflected in state streams', () async {
      final controller = AudioVisualizerPlayerController();
      final emitted = <PlayerControllerState>[];
      final subscription = controller.playlistStream.listen(emitted.add);

      addTearDown(() async {
        await subscription.cancel();
        controller.dispose();
      });

      await controller.setRepeatMode(RepeatMode.all);
      await controller.setShuffleEnabled(true, seed: 7);

      expect(controller.repeatMode, RepeatMode.all);
      expect(controller.shuffleEnabled, isTrue);
      expect(controller.playlistListenable.value.repeatMode, RepeatMode.all);
      expect(controller.playlistListenable.value.shuffleEnabled, isTrue);
      expect(emitted, hasLength(2));
      expect(emitted.first.repeatMode, RepeatMode.all);
      expect(emitted.first.shuffleEnabled, isFalse);
      expect(emitted.last.repeatMode, RepeatMode.all);
      expect(emitted.last.shuffleEnabled, isTrue);
    });

    test('next and previous return false for empty playlist', () async {
      final controller = AudioVisualizerPlayerController();
      addTearDown(controller.dispose);

      expect(await controller.playNext(), isFalse);
      expect(await controller.playPrevious(), isFalse);
    });

    test('clearPlaylist resets state without native initialization', () async {
      final controller = AudioVisualizerPlayerController();
      final notifications = <void>[];
      void listener() => notifications.add(null);
      controller.addListener(listener);

      addTearDown(() {
        controller.removeListener(listener);
        controller.dispose();
      });

      await controller.setRepeatMode(RepeatMode.one);
      await controller.setShuffleEnabled(true, seed: 11);
      await controller.clearPlaylist();

      expect(controller.selectedPath, isNull);
      expect(controller.position, Duration.zero);
      expect(controller.duration, Duration.zero);
      expect(controller.isPlaying, isFalse);
      expect(controller.playlist, isEmpty);
      expect(controller.currentIndex, isNull);
      expect(controller.currentTrack, isNull);
      expect(controller.playlistListenable.value.items, isEmpty);
      expect(notifications, isNotEmpty);
    });
  });

  group('AudioVisualizerPlayerController multi-playlist management', () {
    test('createPlaylist creates new playlist with id and name', () async {
      final controller = AudioVisualizerPlayerController();
      addTearDown(controller.dispose);

      const id = 'test-playlist-1';
      const name = 'My Test Playlist';

      await controller.createPlaylist(id, name);

      expect(controller.playlists, hasLength(1));
      expect(controller.playlists.first.id, id);
      expect(controller.playlists.first.name, name);
      expect(controller.playlists.first.items, isEmpty);
    });

    test('createPlaylist with setAsActive makes it active', () async {
      final controller = AudioVisualizerPlayerController();
      addTearDown(controller.dispose);

      const id = 'active-test';
      const name = 'Active Playlist';
      await controller.createPlaylist(id, name, setAsActive: true);

      expect(controller.playlistState.activePlaylistId, id);
      expect(controller.activePlaylist?.id, id);
    });

    test('getPlaylistById returns correct playlist', () async {
      final controller = AudioVisualizerPlayerController();
      addTearDown(controller.dispose);

      const id = 'fetch-test';
      const name = 'Fetch Test';
      await controller.createPlaylist(id, name);

      final fetched = controller.getPlaylistById(id);
      expect(fetched, isNotNull);
      expect(fetched!.id, id);
      expect(fetched.name, name);

      final notFound = controller.getPlaylistById('non-existent');
      expect(notFound, isNull);
    });

    test('updatePlaylist changes name and items', () async {
      final controller = AudioVisualizerPlayerController();
      addTearDown(controller.dispose);

      const id = 'update-test';
      await controller.createPlaylist(id, 'Original Name');

      const newName = 'Updated Name';
      final track = AudioTrack(
        id: 't1',
        uri: 'path/to/audio.mp3',
        title: 'Test Track',
      );
      await controller.updatePlaylist(id, name: newName, items: [track]);

      final updated = controller.getPlaylistById(id);
      expect(updated!.name, newName);
      expect(updated.items, hasLength(1));
      expect(updated.items.first.id, 't1');
    });

    test('deletePlaylist removes playlist from collection', () async {
      final controller = AudioVisualizerPlayerController();
      addTearDown(controller.dispose);

      await controller.createPlaylist('pl1', 'Playlist 1');
      await controller.createPlaylist('pl2', 'Playlist 2');
      expect(controller.playlists, hasLength(2));

      await controller.deletePlaylist('pl1');
      expect(controller.playlists, hasLength(1));
      expect(controller.playlists.first.id, 'pl2');
    });

    test(
      'deletePlaylist switches active if deleting active playlist',
      () async {
        final controller = AudioVisualizerPlayerController();
        addTearDown(controller.dispose);

        await controller.createPlaylist('pl1', 'Playlist 1', setAsActive: true);
        await controller.createPlaylist('pl2', 'Playlist 2');

        expect(controller.playlistState.activePlaylistId, 'pl1');

        await controller.deletePlaylist('pl1');

        expect(controller.playlistState.activePlaylistId, 'pl2');
        expect(controller.playlists, hasLength(1));
      },
    );

    test('setActivePlaylistById switches active playlist', () async {
      final controller = AudioVisualizerPlayerController();
      addTearDown(controller.dispose);

      const track1 = AudioTrack(id: 't1', uri: 'path1', title: 'Track 1');
      const track2 = AudioTrack(id: 't2', uri: 'path2', title: 'Track 2');

      await controller.createPlaylist('pl1', 'Playlist 1', items: [track1]);
      await controller.createPlaylist('pl2', 'Playlist 2', items: [track2]);

      await controller.setActivePlaylistById('pl1');
      expect(controller.playlistState.activePlaylistId, 'pl1');
      expect(controller.playlist, hasLength(1));
      expect(controller.playlist.first.id, 't1');

      await controller.setActivePlaylistById('pl2');
      expect(controller.playlistState.activePlaylistId, 'pl2');
      expect(controller.playlist, hasLength(1));
      expect(controller.playlist.first.id, 't2');
    });

    test('movePlaylist reorders playlists', () async {
      final controller = AudioVisualizerPlayerController();
      addTearDown(controller.dispose);

      await controller.createPlaylist('pl1', 'First');
      await controller.createPlaylist('pl2', 'Second');
      await controller.createPlaylist('pl3', 'Third');

      expect(controller.playlists.map((p) => p.id).toList(), [
        'pl1',
        'pl2',
        'pl3',
      ]);

      await controller.movePlaylist(0, 2);

      expect(controller.playlists.map((p) => p.id).toList(), [
        'pl2',
        'pl3',
        'pl1',
      ]);
    });

    test('track operations work on active playlist only', () async {
      final controller = AudioVisualizerPlayerController();
      addTearDown(controller.dispose);

      const track1 = AudioTrack(id: 't1', uri: 'p1', title: 'T1');
      const track2 = AudioTrack(id: 't2', uri: 'p2', title: 'T2');

      await controller.createPlaylist('pl1', 'Playlist 1', setAsActive: true);
      await controller.createPlaylist('pl2', 'Playlist 2');

      await controller.addTracks([track1, track2]);

      expect(controller.playlist, hasLength(2));
      expect(controller.playlists[0].items, hasLength(2));
      expect(controller.playlists[1].items, isEmpty);

      await controller.setActivePlaylistById('pl2');
      const track3 = AudioTrack(id: 't3', uri: 'p3', title: 'T3');
      await controller.addTrack(track3);

      expect(controller.playlist, hasLength(1));
      expect(controller.playlists[0].items, hasLength(2)); // pl1 unchanged
      expect(controller.playlists[1].items, hasLength(1)); // pl2 now has 1
    });

    test('deletePlaylist with no other playlists clears active', () async {
      final controller = AudioVisualizerPlayerController();
      addTearDown(controller.dispose);

      await controller.createPlaylist(
        'only',
        'Only Playlist',
        setAsActive: true,
      );
      expect(controller.playlistState.activePlaylistId, 'only');

      await controller.deletePlaylist('only');

      expect(controller.playlists, isEmpty);
      expect(controller.playlistState.activePlaylistId, isNull);
    });
  });
}
