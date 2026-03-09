import 'package:flutter_test/flutter_test.dart';
import 'package:audio_visualizer_player/audio_visualizer_player.dart';
import 'package:audio_visualizer_player/audio_visualizer_player_platform_interface.dart';
import 'package:audio_visualizer_player/audio_visualizer_player_method_channel.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class MockAudioVisualizerPlayerPlatform
    with MockPlatformInterfaceMixin
    implements AudioVisualizerPlayerPlatform {
  @override
  Future<String?> getPlatformVersion() => Future.value('42');
}

void main() {
  final AudioVisualizerPlayerPlatform initialPlatform = AudioVisualizerPlayerPlatform.instance;

  test('$MethodChannelAudioVisualizerPlayer is the default instance', () {
    expect(initialPlatform, isInstanceOf<MethodChannelAudioVisualizerPlayer>());
  });

  test('getPlatformVersion', () async {
    AudioVisualizerPlayer audioVisualizerPlayerPlugin = AudioVisualizerPlayer();
    MockAudioVisualizerPlayerPlatform fakePlatform = MockAudioVisualizerPlayerPlatform();
    AudioVisualizerPlayerPlatform.instance = fakePlatform;

    expect(await audioVisualizerPlayerPlugin.getPlatformVersion(), '42');
  });
}
