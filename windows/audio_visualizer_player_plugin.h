#ifndef FLUTTER_PLUGIN_AUDIO_VISUALIZER_PLAYER_PLUGIN_H_
#define FLUTTER_PLUGIN_AUDIO_VISUALIZER_PLAYER_PLUGIN_H_

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>

#include <memory>

namespace audio_visualizer_player {

class AudioVisualizerPlayerPlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows *registrar);

  AudioVisualizerPlayerPlugin();

  virtual ~AudioVisualizerPlayerPlugin();

  // Disallow copy and assign.
  AudioVisualizerPlayerPlugin(const AudioVisualizerPlayerPlugin&) = delete;
  AudioVisualizerPlayerPlugin& operator=(const AudioVisualizerPlayerPlugin&) = delete;

  // Called when a method is called on this plugin's channel from Dart.
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue> &method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
};

}  // namespace audio_visualizer_player

#endif  // FLUTTER_PLUGIN_AUDIO_VISUALIZER_PLAYER_PLUGIN_H_
