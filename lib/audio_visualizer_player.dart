
import 'audio_visualizer_player_platform_interface.dart';

class AudioVisualizerPlayer {
  Future<String?> getPlatformVersion() {
    return AudioVisualizerPlayerPlatform.instance.getPlatformVersion();
  }
}
