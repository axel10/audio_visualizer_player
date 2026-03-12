import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'audio_visualizer_player_method_channel.dart';

abstract class AudioVisualizerPlayerPlatform extends PlatformInterface {
  /// Constructs a AudioVisualizerPlayerPlatform.
  AudioVisualizerPlayerPlatform() : super(token: _token);

  static final Object _token = Object();

  static AudioVisualizerPlayerPlatform _instance =
      MethodChannelAudioVisualizerPlayer();

  /// The default instance of [AudioVisualizerPlayerPlatform] to use.
  ///
  /// Defaults to [MethodChannelAudioVisualizerPlayer].
  static AudioVisualizerPlayerPlatform get instance => _instance;

  /// Platform-specific implementations should set this with their own
  /// platform-specific class that extends [AudioVisualizerPlayerPlatform] when
  /// they register themselves.
  static set instance(AudioVisualizerPlayerPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  Future<String?> getPlatformVersion() {
    throw UnimplementedError('platformVersion() has not been implemented.');
  }
}
