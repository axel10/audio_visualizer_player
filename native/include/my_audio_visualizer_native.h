#ifndef MY_AUDIO_VISUALIZER_NATIVE_H
#define MY_AUDIO_VISUALIZER_NATIVE_H

#include <stdint.h>

#ifdef _WIN32
#define MAV_EXPORT __declspec(dllexport)
#else
#define MAV_EXPORT __attribute__((visibility("default")))
#endif

#ifdef __cplusplus
extern "C" {
#endif

MAV_EXPORT int32_t mav_create_fft(int32_t fft_size);
MAV_EXPORT void mav_dispose_fft(void);
MAV_EXPORT int32_t mav_load_audio_file(const char* file_path);
MAV_EXPORT int32_t mav_open_audio_for_playback(const char* file_path);
MAV_EXPORT int32_t mav_player_play(void);
MAV_EXPORT int32_t mav_player_pause(void);
MAV_EXPORT int32_t mav_player_seek_ms(int32_t position_ms);
MAV_EXPORT int32_t mav_player_get_position_ms(void);
MAV_EXPORT int32_t mav_player_is_playing(void);
MAV_EXPORT int32_t mav_player_is_stream_ended(void);
MAV_EXPORT int32_t mav_player_set_volume(float volume);
MAV_EXPORT void mav_unload_audio_file(void);
MAV_EXPORT int32_t mav_get_audio_duration_ms(void);
MAV_EXPORT int32_t mav_compute_spectrum_at_ms(int32_t position_ms, float* out_magnitudes, int32_t out_count);
MAV_EXPORT int32_t mav_compute_compressed_bands_at_ms(int32_t position_ms, float* out_bands, int32_t band_count);
MAV_EXPORT int32_t mav_get_whole_track_waveform(const char* file_path, float* out_buffer, int32_t out_count, int32_t use_fast_mode);

MAV_EXPORT int32_t mav_fill_test_signal(float* out_samples, int32_t sample_count, float phase_step);
MAV_EXPORT int32_t mav_compute_spectrum(const float* input_samples, int32_t sample_count, float* out_magnitudes, int32_t out_count);
MAV_EXPORT int32_t mav_simd_width(void);

#ifdef __cplusplus
}
#endif

#endif
