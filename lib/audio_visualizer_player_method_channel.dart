import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'audio_visualizer_player_platform_interface.dart';

/// An implementation of [AudioVisualizerPlayerPlatform] that uses method channels.
class MethodChannelAudioVisualizerPlayer extends AudioVisualizerPlayerPlatform {
  /// The method channel used to interact with the native platform.
  @visibleForTesting
  final methodChannel = const MethodChannel('audio_visualizer_player');

  @override
  Future<String?> getPlatformVersion() async {
    final version = await methodChannel.invokeMethod<String>(
      'getPlatformVersion',
    );
    return version;
  }
}
