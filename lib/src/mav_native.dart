import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

typedef _CreateFftNative = Int32 Function(Int32);
typedef _CreateFftDart = int Function(int);

typedef _DisposeFftNative = Void Function();
typedef _DisposeFftDart = void Function();

typedef _LoadAudioFileNative = Int32 Function(Pointer<Char>);
typedef _LoadAudioFileDart = int Function(Pointer<Char>);

typedef _GetDurationNative = Int32 Function();
typedef _GetDurationDart = int Function();

typedef _OpenAudioForPlaybackNative = Int32 Function(Pointer<Char>);
typedef _OpenAudioForPlaybackDart = int Function(Pointer<Char>);

typedef _PlayerPlayNative = Int32 Function();
typedef _PlayerPlayDart = int Function();

typedef _PlayerPauseNative = Int32 Function();
typedef _PlayerPauseDart = int Function();

typedef _PlayerSeekMsNative = Int32 Function(Int32);
typedef _PlayerSeekMsDart = int Function(int);

typedef _PlayerGetPositionMsNative = Int32 Function();
typedef _PlayerGetPositionMsDart = int Function();

typedef _PlayerIsPlayingNative = Int32 Function();
typedef _PlayerIsPlayingDart = int Function();

typedef _SetVolumeNative = Int32 Function(Float);
typedef _SetVolumeDart = int Function(double);

typedef _ComputeBandsAtMsNative = Int32 Function(Int32, Pointer<Float>, Int32);
typedef _ComputeBandsAtMsDart = int Function(int, Pointer<Float>, int);
typedef _ComputeSpectrumAtMsNative =
    Int32 Function(Int32, Pointer<Float>, Int32);
typedef _ComputeSpectrumAtMsDart = int Function(int, Pointer<Float>, int);

/// Low-level native FFI bindings for audio loading, playback, and FFT queries.
///
/// Most apps should use [AudioVisualizerPlayerController] instead.
class MavNative {
  MavNative._(DynamicLibrary lib)
    : _createFft = lib.lookupFunction<_CreateFftNative, _CreateFftDart>(
        'mav_create_fft',
      ),
      _disposeFft = lib.lookupFunction<_DisposeFftNative, _DisposeFftDart>(
        'mav_dispose_fft',
      ),
      _loadAudioFile = lib
          .lookupFunction<_LoadAudioFileNative, _LoadAudioFileDart>(
            'mav_load_audio_file',
          ),
      _openAudioForPlayback = lib
          .lookupFunction<
            _OpenAudioForPlaybackNative,
            _OpenAudioForPlaybackDart
          >('mav_open_audio_for_playback'),
      _playerPlay = lib.lookupFunction<_PlayerPlayNative, _PlayerPlayDart>(
        'mav_player_play',
      ),
      _playerPause = lib.lookupFunction<_PlayerPauseNative, _PlayerPauseDart>(
        'mav_player_pause',
      ),
      _playerSeekMs = lib
          .lookupFunction<_PlayerSeekMsNative, _PlayerSeekMsDart>(
            'mav_player_seek_ms',
          ),
      _playerGetPositionMs = lib
          .lookupFunction<_PlayerGetPositionMsNative, _PlayerGetPositionMsDart>(
            'mav_player_get_position_ms',
          ),
      _playerIsPlaying = lib
          .lookupFunction<_PlayerIsPlayingNative, _PlayerIsPlayingDart>(
            'mav_player_is_playing',
          ),
      _setVolume = lib.lookupFunction<_SetVolumeNative, _SetVolumeDart>(
        'mav_player_set_volume',
      ),
      _getDurationMs = lib.lookupFunction<_GetDurationNative, _GetDurationDart>(
        'mav_get_audio_duration_ms',
      ),
      _computeSpectrumAtMs = lib
          .lookupFunction<_ComputeSpectrumAtMsNative, _ComputeSpectrumAtMsDart>(
            'mav_compute_spectrum_at_ms',
          ),
      _computeBandsAtMs = lib
          .lookupFunction<_ComputeBandsAtMsNative, _ComputeBandsAtMsDart>(
            'mav_compute_compressed_bands_at_ms',
          );
  final _CreateFftDart _createFft;
  final _DisposeFftDart _disposeFft;
  final _LoadAudioFileDart _loadAudioFile;
  final _OpenAudioForPlaybackDart _openAudioForPlayback;
  final _PlayerPlayDart _playerPlay;
  final _PlayerPauseDart _playerPause;
  final _PlayerSeekMsDart _playerSeekMs;
  final _PlayerGetPositionMsDart _playerGetPositionMs;
  final _PlayerIsPlayingDart _playerIsPlaying;
  final _SetVolumeDart _setVolume;
  final _GetDurationDart _getDurationMs;
  final _ComputeSpectrumAtMsDart _computeSpectrumAtMs;
  final _ComputeBandsAtMsDart _computeBandsAtMs;

  /// Opens platform dynamic library and returns an FFI binding instance.
  static MavNative open() {
    if (Platform.isWindows) {
      return MavNative._(
        DynamicLibrary.open('audio_visualizer_player_plugin.dll'),
      );
    }
    if (Platform.isAndroid) {
      return MavNative._(
        DynamicLibrary.open('libaudio_visualizer_player_plugin.so'),
      );
    }
    throw UnsupportedError('Only Android and Windows are supported.');
  }

  /// Creates FFT context with the provided [fftSize].
  int createFft(int fftSize) => _createFft(fftSize);

  /// Loads an audio file for analysis.
  int loadAudioFile(String filePath) {
    final nativePath = filePath.toNativeUtf8();
    try {
      return _loadAudioFile(nativePath.cast());
    } finally {
      calloc.free(nativePath);
    }
  }

  /// Opens an audio file for playback.
  int openAudioForPlayback(String filePath) {
    final nativePath = filePath.toNativeUtf8();
    try {
      return _openAudioForPlayback(nativePath.cast());
    } finally {
      calloc.free(nativePath);
    }
  }

  /// Starts playback.
  int playerPlay() => _playerPlay();

  /// Pauses playback.
  int playerPause() => _playerPause();

  /// Seeks playback position in milliseconds.
  int playerSeekMs(int positionMs) => _playerSeekMs(positionMs);

  /// Returns current playback position in milliseconds.
  int playerGetPositionMs() => _playerGetPositionMs();

  /// Returns whether native player is currently playing.
  bool playerIsPlaying() => _playerIsPlaying() == 1;

  /// Sets output volume in range `0..1`.
  int playerSetVolume(double volume) => _setVolume(volume);

  /// Returns current audio duration in milliseconds.
  int getDurationMs() => _getDurationMs();

  /// Returns full spectrum magnitudes at [positionMs].
  ///
  /// [outCount] controls requested result length.
  List<double> getSpectrumAtMs({
    required int positionMs,
    required int outCount,
  }) {
    final out = calloc<Float>(outCount);
    try {
      final count = _computeSpectrumAtMs(positionMs, out, outCount);
      if (count <= 0) {
        return const [];
      }
      final list = out.asTypedList(count);
      return List<double>.generate(count, (i) => list[i].toDouble());
    } finally {
      calloc.free(out);
    }
  }

  /// Returns compressed normalized bands at [positionMs].
  ///
  /// [bandCount] controls requested output length.
  List<double> getCompressedBandsAtMs({
    required int positionMs,
    required int bandCount,
  }) {
    final out = calloc<Float>(bandCount);
    try {
      final count = _computeBandsAtMs(positionMs, out, bandCount);
      if (count <= 0) {
        return List<double>.filled(bandCount, 0.0);
      }
      final list = out.asTypedList(count);
      return List<double>.generate(
        bandCount,
        (i) => i < count ? list[i].clamp(0.0, 1.0).toDouble() : 0.0,
      );
    } finally {
      calloc.free(out);
    }
  }

  /// Releases native FFT resources.
  void dispose() => _disposeFft();
}
