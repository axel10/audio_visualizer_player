#include "include/audio_visualizer_player/audio_visualizer_player_plugin_c_api.h"

#include <flutter/plugin_registrar_windows.h>

#include "audio_visualizer_player_plugin.h"

void AudioVisualizerPlayerPluginCApiRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  audio_visualizer_player::AudioVisualizerPlayerPlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}
