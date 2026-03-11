---
name: audio_visualizer_player
description: "Use when: modifying the core playback architecture, implementing new cross-platform features, or debugging audio/FFT issues. Covers C++ (Windows) via dart-ffi and Kotlin (Android) via MethodChannel."
---

# Audio Visualizer Player Development Skill

This skill provides a standardized workflow for maintaining and extending the `audio_visualizer_player` Flutter plugin. The plugin uses a hybrid architecture:
- **Windows**: Native C++ playback engine (`native/`) exposed via `dart-ffi` ([lib/src/mav_native.dart](lib/src/mav_native.dart)).
- **Android**: Kotlin-based player using `ExoPlayer` or similar ([android/src/main/kotlin/](android/src/main/kotlin/)) exposed via `MethodChannel` ([lib/audio_visualizer_player_method_channel.dart](lib/audio_visualizer_player_method_channel.dart)).
- **Shared Logic**: FFT processing and high-level control in Dart ([lib/src/](lib/src/)).

## Core Workflow

### 1. Architectural Changes
When modifying the core playback or FFT logic:
- **Update the Platform Interface**: Modify `audio_visualizer_player_platform_interface.dart` first to define the new contract.
- **Implement Windows (C++/FFI)**:
    - Update `native/include/my_audio_visualizer_native.h` for function signatures.
    - Update `native/src/my_audio_visualizer_native.cpp` for implementation.
    - Synchronize definitions in `lib/src/mav_native.dart`.
- **Implement Android (Kotlin/Channel)**:
    - Update `android/src/main/kotlin/.../AudioVisualizerPlayerPlugin.kt` to handle new `MethodCall` items.
    - Update `lib/audio_visualizer_player_method_channel.dart` to invoke the platform methods.
- **Update Controller**: Expose the functionality in `lib/src/visualizer_player_controller.dart`.

### 2. Feature Implementation Checklist
- [ ] **Cross-Platform Parity**: Ensure every new public method in the controller has a corresponding implementation for both Windows and Android.
- [ ] **Thread Safety**: 
    - Windows: C++ playback often runs on a high-priority audio thread; ensure FFI calls are non-blocking or properly synchronized.
    - Android: Use `Handler(Looper.getMainLooper())` for `MethodChannel` results if needed.
- [ ] **Memory Management**: Check for memory leaks in C++ and ensure `pointer` cleanup in Dart-FFI.
- [ ] **FFT Precision**: If changing FFT logic, verify `lib/src/fft_processor.dart` logic matches the data output from both native sides.

### 3. Debugging Strategy
- **Windows Logs**: Check standard output/debug console for `std::cout` or `printf` from the C++ layer.
- **Android Logs**: Use `Logd` or `Loge` in Kotlin and monitor via `adb logcat`.
- **FFI Boundary**: Use `print()` in Dart right before/after FFI calls to verify data crossing the boundary.
- **Performance**: Monitor the `FftFrame` emission rate in `visualizer_player_controller.dart` to ensure visual smoothness.

## Quality Criteria
- Minimum latency between audio playback and FFT frame emission.
- Clean separation between platform-specific native code and the shared Dart controller.
- Comprehensive error handling for file-not-found or permission-denied scenarios on both platforms.

## Example Prompts
- "Add a 'setPlaybackSpeed' method to the player, implementing it on both Windows (FFI) and Android (MethodChannel)."
- "Debug why the FFT values on Windows seem significantly different from Android when playing the same file."
- "Refactor the volume control to use a more precise logarithmic scale across all platforms."
