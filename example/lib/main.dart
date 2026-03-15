import 'dart:async';
import 'dart:io';

import 'package:cross_file/cross_file.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:audio_visualizer_player/audio_visualizer_player.dart';
import 'package:file_picker/file_picker.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Audio Visualizer Player Demo',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      home: const VisualizerDemoPage(),
    );
  }
}

class VisualizerDemoPage extends StatefulWidget {
  const VisualizerDemoPage({super.key});

  @override
  State<VisualizerDemoPage> createState() => _VisualizerDemoPageState();
}

class _VisualizerDemoPageState extends State<VisualizerDemoPage> {
  late final AudioVisualizerPlayerController _controller;
  StreamSubscription<FftFrame>? _sub;
  List<double> _bands = const [];

  List<double> _waveform = [];
  final int _waveformChunks = 500;
  int _waveformStride = 2;

  @override
  void initState() {
    super.initState();
    _controller = AudioVisualizerPlayerController(
      fftSize: 1024,
      analysisFrequencyHz: 30,
      fadeDuration: const Duration(milliseconds: 500),
      visualOptions: const VisualizerOptimizationOptions(
        smoothingCoefficient: 0.35,
        gravityCoefficient: 10,
        logarithmicScale: 4,
        normalizationFloorDb: -85,
        aggregationMode: FftAggregationMode.peak,
        frequencyGroups: 64,
        targetFrameRate: 60,
        groupContrastExponent: 1.6,
        overallMultiplier: 1.2,
      ),
    );
    _controller.initialize();
    _sub = _controller.optimizedFftStream.listen((frame) {
      if (!mounted) {
        return;
      }
      setState(() {
        _bands = frame.values;
      });
    });
  }

  Future<void> _pickAudio() async {
    if (!_controller.isInitialized) {
      await _controller.initialize();
    }
    final result = await FilePicker.platform.pickFiles(
      type: FileType.audio,
      allowMultiple: true,
    );
    if (result == null || result.files.isEmpty) {
      return;
    }

    final tracks = result.files
        .map((file) {
          final path = file.path;
          if (path == null || path.isEmpty) {
            return null;
          }
          return AudioTrack(id: path, title: file.name, uri: path);
        })
        .whereType<AudioTrack>()
        .toList();

    if (tracks.isEmpty) {
      return;
    }

    await _controller.addTracks(tracks);
    if (!_controller.isPlaying && _controller.selectedPath != null) {
      await _controller.play();
    }
  }

  Future<void> _loadWaveform() async {
    final waveform = await _controller.getWaveform(
      expectedChunks: _waveformChunks,
      sampleStride: _waveformStride,
    );
    if (!mounted) return;
    debugPrint(waveform.toString());
    setState(() {
      _waveform = waveform;
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        return Scaffold(
          appBar: AppBar(
            title: const Text('Audio Visualizer Player Plugin Demo'),
            backgroundColor: Theme.of(context).colorScheme.inversePrimary,
          ),
          body: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                Row(
                  children: [
                    ElevatedButton(
                      onPressed: _controller.isSupported ? _pickAudio : null,
                      child: const Text('Select Audio'),
                    ),
                    const SizedBox(width: 12),

                    ElevatedButton(
                      onPressed: _controller.selectedPath != null
                          ? _controller.playPrevious
                          : null,
                      child: const Icon(Icons.skip_previous),
                    ),
                    const SizedBox(width: 12),
                    ElevatedButton(
                      onPressed: _controller.selectedPath != null
                          ? _controller.togglePlayPause
                          : null,
                      child: Icon(
                        _controller.isPlaying ? Icons.pause : Icons.play_arrow,
                      ),
                    ),
                    const SizedBox(width: 12),
                    ElevatedButton(
                      onPressed: _controller.selectedPath != null
                          ? _controller.playNext
                          : null,
                      child: const Icon(Icons.skip_next),
                    ),
                    const SizedBox(width: 12),
                    DropdownButton<PlaylistMode>(
                      value: _controller.playlistMode,
                      items: PlaylistMode.values.map((mode) {
                        return DropdownMenuItem(
                          value: mode,
                          child: Text(mode.name.toUpperCase()),
                        );
                      }).toList(),
                      onChanged: (mode) {
                        if (mode != null) {
                          _controller.setPlaylistMode(mode);
                        }
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    _controller.selectedPath ?? 'No file selected',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (_controller.selectedPath != null)
                  ElevatedButton(
                    onPressed: () => _loadWaveform(),
                    child: const Text('Extract Full Waveform (Fast)'),
                  ),
                if (_controller.selectedPath != null)
                  Row(
                    children: [
                      const Text('Waveform Stride'),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Slider(
                          min: 1,
                          max: 32,
                          divisions: 31,
                          value: _waveformStride.toDouble(),
                          label: '$_waveformStride',
                          onChanged: (value) {
                            setState(() {
                              _waveformStride = value.round().clamp(1, 32);
                            });
                          },
                        ),
                      ),
                      SizedBox(
                        width: 36,
                        child: Text(
                          '$_waveformStride',
                          textAlign: TextAlign.right,
                        ),
                      ),
                    ],
                  ),
                if (_controller.playlist.isNotEmpty)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'Playlist: ${(_controller.currentIndex ?? -1) + 1} / ${_controller.playlist.length}',
                    ),
                  ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    '${_format(_controller.position)} / ${_format(_controller.duration)}',
                  ),
                ),
                Slider(
                  value: _controller.duration.inMilliseconds > 0
                      ? _controller.position.inMilliseconds.toDouble().clamp(
                          0,
                          _controller.duration.inMilliseconds.toDouble(),
                        )
                      : 0.0,
                  max: _controller.duration.inMilliseconds.toDouble() > 0
                      ? _controller.duration.inMilliseconds.toDouble()
                      : 1.0,
                  onChanged: (value) {
                    _controller.seek(Duration(milliseconds: value.toInt()));
                  },
                ),
                if (_controller.error != null) ...[
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      _controller.error!,
                      style: const TextStyle(color: Colors.red),
                    ),
                  ),
                ],
                const SizedBox(height: 16),
                SizedBox(
                  height: 60,
                  width: double.infinity,
                  child: CustomPaint(
                    painter: WaveformPainter(
                      _waveform,
                      _controller.duration.inMilliseconds > 0
                          ? _controller.position.inMilliseconds /
                                _controller.duration.inMilliseconds
                          : 0.0,
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Expanded(
                  child: AudioDropRegion(
                    controller: _controller,
                    child: Container(
                      width: double.infinity,
                      decoration: BoxDecoration(
                        color: Colors.black,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: CustomPaint(
                        painter: DemoSpectrumPainter(_bands),
                        child: const SizedBox.expand(),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  String _format(Duration d) {
    final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }
}

class WaveformPainter extends CustomPainter {
  WaveformPainter(this.waveform, this.progress);

  final List<double> waveform;
  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    if (waveform.isEmpty) return;

    final barWidth = size.width / waveform.length;
    final maxBarHeight = size.height;

    final playedPaint = Paint()
      ..color = Colors.blue
      ..style = PaintingStyle.fill;

    final unplayedPaint = Paint()
      ..color = Colors.grey.withOpacity(0.5)
      ..style = PaintingStyle.fill;

    for (var i = 0; i < waveform.length; i++) {
      final value = waveform[i];
      final height = (value * maxBarHeight).clamp(2.0, maxBarHeight);
      final left = i * barWidth;
      final top = (maxBarHeight - height) / 2; // Center vertically

      final rect = Rect.fromLTWH(left, top, barWidth - 1, height);
      final isPlayed = (i / waveform.length) <= progress;

      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(2)),
        isPlayed ? playedPaint : unplayedPaint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant WaveformPainter oldDelegate) {
    // Usually you'd check specifically if waveform array identity changed or progress changed
    return true;
  }
}

class DemoSpectrumPainter extends CustomPainter {
  DemoSpectrumPainter(this.bands);

  final List<double> bands;

  @override
  void paint(Canvas canvas, Size size) {
    if (bands.isEmpty) {
      return;
    }
    const safeTop = 6.0;
    const safeBottom = 6.0;
    const gap = 2.0;
    const minBarHeight = 2.0;
    final usableHeight = (size.height - safeTop - safeBottom).clamp(
      0.0,
      size.height,
    );
    final barWidth = ((size.width - (bands.length + 1) * gap) / bands.length)
        .clamp(1.0, 20.0);

    final bodyPaint = Paint()..color = const Color(0xFF2AD4FF);
    final glowPaint = Paint()
      ..color = const Color(0x802AD4FF)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4);
    final baseline = size.height - safeBottom;

    canvas.save();
    canvas.clipRect(Rect.fromLTWH(0, safeTop, size.width, usableHeight));
    for (var i = 0; i < bands.length; i++) {
      final v = bands[i].clamp(0.0, 1.0);
      final h = (v * usableHeight).clamp(minBarHeight, usableHeight);
      final left = gap + i * (barWidth + gap);
      final top = baseline - h;
      final rect = RRect.fromRectAndRadius(
        Rect.fromLTWH(left, top, barWidth, h),
        const Radius.circular(2),
      );
      canvas.drawRRect(rect, glowPaint);
      canvas.drawRRect(rect, bodyPaint);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant DemoSpectrumPainter oldDelegate) {
    return oldDelegate.bands != bands;
  }
}

class AudioDropRegion extends StatefulWidget {
  const AudioDropRegion({
    super.key,
    required this.controller,
    required this.child,
    this.overlayText = 'Drag an audio file here',
  });

  final AudioVisualizerPlayerController controller;
  final Widget child;
  final String overlayText;

  @override
  State<AudioDropRegion> createState() => _AudioDropRegionState();
}

class _AudioDropRegionState extends State<AudioDropRegion> {
  bool _isDragging = false;

  bool get _enabled => Platform.isWindows;

  Future<void> _handleDrop(List<XFile> files) async {
    if (!_enabled || files.isEmpty) {
      return;
    }
    if (!widget.controller.isInitialized) {
      await widget.controller.initialize();
    }
    final List<AudioTrack> tracks = [];
    for (final file in files) {
      final path = file.path;
      if (path.isNotEmpty && File(path).existsSync()) {
        tracks.add(AudioTrack(id: path, title: file.name, uri: path));
      }
    }
    if (tracks.isEmpty) return;

    await widget.controller.addTracks(tracks);
    if (!widget.controller.isPlaying &&
        widget.controller.selectedPath != null) {
      await widget.controller.play();
    }
  }

  @override
  Widget build(BuildContext context) {
    return DropTarget(
      enable: _enabled,
      onDragEntered: (_) => setState(() => _isDragging = true),
      onDragExited: (_) => setState(() => _isDragging = false),
      onDragDone: (detail) async {
        setState(() => _isDragging = false);
        await _handleDrop(detail.files);
      },
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: _isDragging ? const Color(0xFF2AD4FF) : Colors.transparent,
            width: 2,
          ),
        ),
        child: Stack(
          children: [
            widget.child,
            if (_enabled && widget.controller.selectedPath == null)
              Center(
                child: Text(
                  widget.overlayText,
                  style: const TextStyle(color: Colors.white70),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
