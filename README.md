# Audio Visualizer Player

A powerful Flutter audio player plugin with real-time FFT analysis and visualization capabilities, supporting both **Android** and **Windows**.

## 🏗 Project Architecture

The plugin is designed with a high-level Dart controller that orchestrates playback and provides processed visualization data, while delegating heavy lifting to platform-specific native implementations.

### System Overview

```text
+-----------------------------------------------------------+
|                  Flutter UI (CustomPainters)              |
+-----------------------------------------------------------+
                             ^
                             | (Streams: FftFrame, PlaylistState)
+-----------------------------------------------------------+
|          AudioVisualizerPlayerController (Dart)           |
|  - Playback Logic        - Playlist Management            |
|  - FFT Post-processing (Smoothing, Gravity, Normalization) |
+-----------------------------------------------------------+
             /                               \
            /                                 \
+-------------------------+         +-------------------------+
|      Android Side       |         |      Windows Side       |
|  - MediaPlayer          |         |  - Media Foundation     |
|  - Visualizer API       |         |  - Custom FFT (PFFFT)   |
|  - Method/Event Channel |         |  - Dart FFI (MavNative) |
+-------------------------+         +-------------------------+
```

### Platform Details

- **Android**: 
    - **Playback**: Uses the native `MediaPlayer`.
    - **Analysis**: Uses the `Visualizer` API to capture waveforms/FFT.
    - **Communication**: Uses `MethodChannel` for controls and `EventChannel` for streaming raw FFT data.
- **Windows**:
    - **Playback**: Uses **Media Foundation** for low-latency audio decoding and playback.
    - **Analysis**: Uses **PFFFT** (a pretty fast FFT library) for high-performance spectral analysis.
    - **Communication**: Uses **Dart FFI** for direct, synchronous memory access to native audio buffers and analysis results.

---

## 🚀 Getting Started

### Installation

Add the following to your `pubspec.yaml`:

```yaml
dependencies:
  audio_visualizer_player:
    path: ../audio_visualizer_player
```

### Android Permissions

To use the visualizer on Android, you must request the `RECORD_AUDIO` permission. Add this to your `AndroidManifest.xml`:

```xml
<uses-permission android:name="android.permission.RECORD_AUDIO" />
```

---

## 📖 API Reference

### `AudioVisualizerPlayerController`

The main class to control audio playback and access visualization data.

#### Core Methods

| Method | Description | Example |
| :--- | :--- | :--- |
| `initialize()` | Initializes native resources and starts analysis timers. | `await controller.initialize();` |
| `loadFromPath(String path)` | Loads an audio file from a local path. | `await controller.loadFromPath('/path/to/audio.mp3');` |
| `play()` / `pause()` | Controls playback state. | `await controller.play();` |
| `seek(Duration target)` | Seeks to a specific position. | `await controller.seek(Duration(seconds: 30));` |
| `setVolume(double volume)` | Sets volume (0.0 to 1.0). | `await controller.setVolume(0.8);` |
| `requestPermissions()` | Requests necessary permissions on Android. | `await controller.requestPermissions();` |

#### Visualization Streams

| Stream | Description |
| :--- | :--- |
| `optimizedFftStream` | **Recommended.** Provides smoothed, grouped, and normalized FFT data ready for bars. |
| `rawFftStream` | Provides raw FFT magnitudes directly from the native analyzer. |

---

### `VisualizerOptimizationOptions`

Configure how raw FFT data is transformed into visual bars.

| Property | Default | Description |
| :--- | :--- | :--- |
| `frequencyGroups` | `32` | Number of bars to output. |
| `smoothingCoefficient` | `0.55` | Temporal smoothing (0.0-1.0). Higher = more stable. |
| `gravityCoefficient` | `1.2` | How fast bars fall. Higher = faster. |
| `logarithmicScale` | `2.0` | Boosts quiet frequencies for better visibility. |
| `aggregationMode` | `peak` | How to group bins (`peak`, `mean`, `rms`). |

---

### `Playlist Management`

The controller includes built-in playlist support.

| Method | Description |
| :--- | :--- |
| `setPlaylist(List<AudioTrack> items)` | Replaces current playlist and starts at `startIndex`. |
| `addTrack(AudioTrack track)` | Appends a track to the end. |
| `playNext()` / `playPrevious()` | Navigates through the playlist. |
| `setShuffleEnabled(bool)` | Enables/disables shuffle mode. |
| `setRepeatMode(RepeatMode)` | Sets repeat mode (`off`, `one`, `all`). |

---

## 💻 Usage Examples

### 1. Basic Playback

```dart
final controller = AudioVisualizerPlayerController();

// 1. Initialize
await controller.initialize();

// 2. Load and play
await controller.loadFromPath('/storage/emulated/0/Music/song.mp3');
await controller.play();
```

### 2. Real-time Visualization

Use `optimizedFftStream` with a `StreamBuilder` or a listener to drive your UI.

```dart
// In your State class
List<double> _amplitudes = [];

@override
void initState() {
  super.initState();
  _controller.optimizedFftStream.listen((frame) {
    setState(() {
      _amplitudes = frame.values; // e.g., 64 normalized values (0.0 - 1.0)
    });
  });
}

// In build()
CustomPaint(
  painter: MyVisualizerPainter(_amplitudes),
)
```

### 3. Advanced Playlist Setup

```dart
await controller.setPlaylist([
  AudioTrack(id: '1', uri: '/music/1.mp3', title: 'Song One'),
  AudioTrack(id: '2', uri: '/music/2.mp3', title: 'Song Two'),
], autoPlay: true);

controller.setRepeatMode(RepeatMode.all);
controller.setShuffleEnabled(true);
```

### 4. Customizing Visualization

```dart
final controller = AudioVisualizerPlayerController(
  fftSize: 2048,
  visualOptions: const VisualizerOptimizationOptions(
    frequencyGroups: 64,
    smoothingCoefficient: 0.7,
    gravityCoefficient: 2.5,
    logarithmicScale: 4.0,
    aggregationMode: FftAggregationMode.rms,
  ),
);
```

---

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
