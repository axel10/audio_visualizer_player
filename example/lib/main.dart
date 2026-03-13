import 'package:flutter/material.dart';
import 'package:audio_visualizer_player/audio_visualizer_player.dart';
import 'package:desktop_drop/desktop_drop.dart';

import 'dart:async';
import 'dart:math' as math;

Future<void> main() async {
  await RustLib.init();
  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  Timer? _fftTimer;
  bool _isDragging = false;
  bool _isPlaying = false;
  String? _loadedPath;
  String? _error;
  List<double> _fft = const [];

  @override
  void initState() {
    super.initState();
    _loadedPath = getLoadedAudioPath();
    _isPlaying = isAudioPlaying();

    _fftTimer = Timer.periodic(const Duration(milliseconds: 33), (_) {
      if (!mounted) {
        return;
      }

      final values = getLatestFft();
      setState(() {
        _fft = values.toList(growable: false);
        _isPlaying = isAudioPlaying();
      });
    });
  }

  @override
  void dispose() {
    _fftTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadAndPlay(String path) async {
    try {
      await loadAudioFile(path: path);
      if (!mounted) {
        return;
      }
      setState(() {
        _loadedPath = path;
        _isPlaying = true;
        _error = null;
      });
    } catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = e.toString();
      });
    }
  }

  Future<void> _togglePlayPause() async {
    if (_loadedPath == null) {
      setState(() {
        _error = 'Please drag an audio file first.';
      });
      return;
    }

    try {
      final next = await toggleAudio();
      if (!mounted) {
        return;
      }
      setState(() {
        _isPlaying = next;
        _error = null;
      });
    } catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = e.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final dropText = _loadedPath == null
        ? 'Drag an audio file here'
        : 'Loaded: ${_loadedPath!.split('\\').last}';

    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(title: const Text('Rodio Player + FFT')),
        body: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: DropTarget(
                  onDragEntered: (_) => setState(() => _isDragging = true),
                  onDragExited: (_) => setState(() => _isDragging = false),
                  onDragDone: (details) {
                    setState(() => _isDragging = false);
                    if (details.files.isNotEmpty) {
                      _loadAndPlay(details.files.first.path);
                    }
                  },
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 180),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: _isDragging ? Colors.blue : Colors.grey,
                        width: 2,
                      ),
                      color: _isDragging
                          ? Colors.blue.withValues(alpha: 0.08)
                          : Colors.grey.withValues(alpha: 0.08),
                    ),
                    child: Center(
                      child: Text(
                        dropText,
                        style: const TextStyle(fontSize: 16),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                height: 140,
                child: CustomPaint(
                  painter: _FftPainter(_fft),
                  child: const SizedBox.expand(),
                ),
              ),
              const SizedBox(height: 12),
              ElevatedButton.icon(
                onPressed: _togglePlayPause,
                icon: Icon(_isPlaying ? Icons.pause : Icons.play_arrow),
                label: Text(_isPlaying ? 'Pause' : 'Play'),
              ),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(_error!, style: const TextStyle(color: Colors.red)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _FftPainter extends CustomPainter {
  _FftPainter(this.values);

  final List<double> values;

  @override
  void paint(Canvas canvas, Size size) {
    final bg = Paint()..color = const Color(0xFF121722);
    canvas.drawRRect(
      RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(10)),
      bg,
    );

    if (values.isEmpty) {
      return;
    }

    final barWidth = size.width / values.length;
    final paint = Paint()..color = const Color(0xFF47C2FF);

    for (var i = 0; i < values.length; i++) {
      final v = values[i];
      final normalized = (v / 6.0).clamp(0.0, 1.0);
      final h = math.max(1.0, normalized * size.height);
      final rect = Rect.fromLTWH(
        i * barWidth,
        size.height - h,
        math.max(1.0, barWidth - 1),
        h,
      );
      canvas.drawRect(rect, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _FftPainter oldDelegate) {
    return oldDelegate.values != values;
  }
}
