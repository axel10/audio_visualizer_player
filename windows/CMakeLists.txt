# The Flutter tooling requires that developers have a version of Visual Studio
# installed that includes CMake 3.14 or later. You should not increase this
# version, as doing so will cause the plugin to fail to compile for some
# customers of the plugin.
cmake_minimum_required(VERSION 3.14)

# Project-level configuration.
set(PROJECT_NAME "audio_visualizer_player")
project(${PROJECT_NAME} LANGUAGES CXX C)

# Explicitly opt in to modern CMake behaviors to avoid warnings with recent
# versions of CMake.
cmake_policy(VERSION 3.14...3.25)

# This value is used when generating builds using this plugin, so it must
# not be changed
set(PLUGIN_NAME "audio_visualizer_player_plugin")

# Any new source files that you add to the plugin should be added here.
set(NATIVE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../native")
set(SOLOUD_DIR "${NATIVE_DIR}/third_part/soloud")

file(GLOB SOLOUD_SOURCES
  "${SOLOUD_DIR}/src/core/*.cpp"
  "${SOLOUD_DIR}/src/audiosource/wav/*.cpp"
  "${SOLOUD_DIR}/src/audiosource/wav/*.c"
  "${SOLOUD_DIR}/src/filter/*.cpp"
  "${SOLOUD_DIR}/src/backend/wasapi/*.cpp"
)

set_source_files_properties(${SOLOUD_SOURCES} PROPERTIES LANGUAGE CXX)

list(APPEND PLUGIN_SOURCES
  "audio_visualizer_player_plugin.cpp"
  "audio_visualizer_player_plugin.h"
  "${NATIVE_DIR}/src/my_audio_visualizer_native.cpp"
  ${SOLOUD_SOURCES}
)

# Define the plugin library target. Its name must not be changed (see comment
# on PLUGIN_NAME above).
add_library(${PLUGIN_NAME} SHARED
  "include/audio_visualizer_player/audio_visualizer_player_plugin_c_api.h"
  "audio_visualizer_player_plugin_c_api.cpp"
  ${PLUGIN_SOURCES}
)

target_include_directories(${PLUGIN_NAME} PRIVATE "${SOLOUD_DIR}/include")
target_compile_definitions(${PLUGIN_NAME} PRIVATE WITH_WASAPI)

# Apply a standard set of build settings that are configured in the
# application-level CMakeLists.txt. This can be removed for plugins that want
# full control over build settings.
apply_standard_settings(${PLUGIN_NAME})
target_compile_options(${PLUGIN_NAME} PRIVATE /W3)
if(MSVC)
  target_compile_options(${PLUGIN_NAME} PRIVATE /WX-)
endif()

# Symbols are hidden by default to reduce the chance of accidental conflicts
# between plugins. This should not be removed; any symbols that should be
# exported should be explicitly exported with the FLUTTER_PLUGIN_EXPORT macro.
set_target_properties(${PLUGIN_NAME} PROPERTIES
  CXX_VISIBILITY_PRESET hidden)
target_compile_definitions(${PLUGIN_NAME} PRIVATE FLUTTER_PLUGIN_IMPL)
target_compile_definitions(${PLUGIN_NAME} PRIVATE PFFFT_STATIC_DEFINE)

# Source include directories and library dependencies. Add any plugin-specific
# dependencies here.
target_include_directories(${PLUGIN_NAME} INTERFACE
  "${CMAKE_CURRENT_SOURCE_DIR}/include")
target_include_directories(${PLUGIN_NAME} PRIVATE
  "${NATIVE_DIR}/include"
  "${NATIVE_DIR}/third_part"
  "${NATIVE_DIR}/third_part/simd"
)
target_link_libraries(${PLUGIN_NAME} PRIVATE 
  flutter 
  flutter_wrapper_plugin
  winmm 
  ole32 
  avrt
  mfplat
  mfreadwrite
  mf
  mfuuid
  propsys
)

# List of absolute paths to libraries that should be bundled with the plugin.
# This list could contain prebuilt libraries, or libraries created by an
# external build triggered from this build file.
set(audio_visualizer_player_bundled_libraries
  ""
  PARENT_SCOPE
)

# === Tests ===
# These unit tests can be run from a terminal after building the example, or
# from Visual Studio after opening the generated solution file.

# Only enable test builds when building the example (which sets this variable)
# so that plugin clients aren't building the tests.
if (FALSE)
set(TEST_RUNNER "${PROJECT_NAME}_test")
enable_testing()

# Add the Google Test dependency.
include(FetchContent)
FetchContent_Declare(
  googletest
  URL https://github.com/google/googletest/archive/refs/tags/v1.15.2.zip
)
# Prevent overriding the parent project's compiler/linker settings
set(gtest_force_shared_crt ON CACHE BOOL "" FORCE)
# Disable install commands for gtest so it doesn't end up in the bundle.
set(INSTALL_GTEST OFF CACHE BOOL "Disable installation of googletest" FORCE)
FetchContent_MakeAvailable(googletest)

# The plugin's C API is not very useful for unit testing, so build the sources
# directly into the test binary rather than using the DLL.
add_executable(${TEST_RUNNER}
  test/audio_visualizer_player_plugin_test.cpp
  ${PLUGIN_SOURCES}
)
apply_standard_settings(${TEST_RUNNER})
target_compile_options(${TEST_RUNNER} PRIVATE /W3)
if(MSVC)
  target_compile_options(${TEST_RUNNER} PRIVATE /WX-)
endif()
target_compile_definitions(${TEST_RUNNER} PRIVATE PFFFT_STATIC_DEFINE)
target_include_directories(${TEST_RUNNER} PRIVATE 
  "${CMAKE_CURRENT_SOURCE_DIR}"
  "${NATIVE_DIR}/include"
  "${NATIVE_DIR}/third_part"
  "${NATIVE_DIR}/third_part/simd"
)
target_link_libraries(${TEST_RUNNER} PRIVATE flutter_wrapper_plugin)
target_link_libraries(${TEST_RUNNER} PRIVATE gtest_main gmock)
# flutter_wrapper_plugin has link dependencies on the Flutter DLL.
add_custom_command(TARGET ${TEST_RUNNER} POST_BUILD
  COMMAND ${CMAKE_COMMAND} -E copy_if_different
  "${FLUTTER_LIBRARY}" $<TARGET_FILE_DIR:${TEST_RUNNER}>
)

# Enable automatic test discovery.
include(GoogleTest)
gtest_discover_tests(${TEST_RUNNER})
endif()
set_source_files_properties(
  "/src/audiosource/wav/stb_vorbis.c" 
  PROPERTIES LANGUAGE CXX
)
