//
//  Generated file. Do not edit.
//

// clang-format off

#include "generated_plugin_registrant.h"

#include <audio_decoder/audio_decoder_plugin_c_api.h>
#include <audio_visualizer_player/audio_visualizer_player_plugin_c_api.h>
#include <desktop_drop/desktop_drop_plugin.h>
#include <permission_handler_windows/permission_handler_windows_plugin.h>

void RegisterPlugins(flutter::PluginRegistry* registry) {
  AudioDecoderPluginCApiRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("AudioDecoderPluginCApi"));
  AudioVisualizerPlayerPluginCApiRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("AudioVisualizerPlayerPluginCApi"));
  DesktopDropPluginRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("DesktopDropPlugin"));
  PermissionHandlerWindowsPluginRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("PermissionHandlerWindowsPlugin"));
}
