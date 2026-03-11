#ifndef FFT_UTILS_H
#define FFT_UTILS_H

#include <stdint.h>
#include <stddef.h>

#ifdef _WIN32
#define MAV_EXPORT __declspec(dllexport)
#else
#define MAV_EXPORT __attribute__((visibility("default")))
#endif

#ifdef __cplusplus
extern "C" {
#endif

// FFT Management (Internal Implementation)
int32_t fft_internal_create(int32_t fft_size);
void fft_internal_dispose(void);
int32_t fft_internal_get_size(void);

// FFT Computation (Internal Implementation)
int32_t fft_internal_compute_spectrum(const float* input_samples, int32_t sample_count, float* out_magnitudes, int32_t out_count);
int32_t fft_internal_compute_compressed_bands(const float* magnitudes, int32_t bins, float* out_bands, int32_t band_count);

// System Utilities (Internal Implementation)
int32_t fft_internal_simd_width(void);
int32_t fft_internal_fill_test_signal(float* out_samples, int32_t sample_count, float phase_step);

// Memory Alignment Utilities (Needed for PFFFT)
void* pffft_aligned_malloc(size_t nb_bytes);
void pffft_aligned_free(void* ptr);

#ifdef __cplusplus
}
#endif

#endif // FFT_UTILS_H
