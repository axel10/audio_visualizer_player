#include "../include/fft_utils.h"
#include <math.h>
#include <stdlib.h>
#include <string.h>
#include <vector>

extern "C" {
#include "../third_part/pffft.h"
#include "../third_part/pffft.c"
}

static PFFFT_Setup* g_fft_setup = nullptr;
static int32_t g_fft_size = 0;
static float* g_smoothed_bands = nullptr;
static int32_t g_smoothed_band_count = 0;

extern "C" {

void* pffft_aligned_malloc(size_t nb_bytes) {
#ifdef _WIN32
    return _aligned_malloc(nb_bytes, 64);
#else
    void* ptr = nullptr;
    if (posix_memalign(&ptr, 64, nb_bytes) != 0) return nullptr;
    return ptr;
#endif
}

void pffft_aligned_free(void* ptr) {
#ifdef _WIN32
    _aligned_free(ptr);
#else
    free(ptr);
#endif
}

static void mav_release_smoothed_bands_internal(void) {
    if (g_smoothed_bands != nullptr) {
        free(g_smoothed_bands);
        g_smoothed_bands = nullptr;
    }
    g_smoothed_band_count = 0;
}

int32_t fft_internal_create(int32_t fft_size) {
    if (fft_size <= 0 || !pffft_is_valid_size(fft_size, PFFFT_REAL)) return -1;
    if (g_fft_setup != nullptr) {
        pffft_destroy_setup(g_fft_setup);
        g_fft_setup = nullptr;
        g_fft_size = 0;
    }
    g_fft_setup = pffft_new_setup(fft_size, PFFFT_REAL);
    if (g_fft_setup == nullptr) return -2;
    g_fft_size = fft_size;
    return 0;
}

void fft_internal_dispose(void) {
    mav_release_smoothed_bands_internal();
    if (g_fft_setup != nullptr) {
        pffft_destroy_setup(g_fft_setup);
        g_fft_setup = nullptr;
        g_fft_size = 0;
    }
}

int32_t fft_internal_get_size(void) {
    return g_fft_size;
}

int32_t fft_internal_compute_spectrum(const float* input_samples, int32_t sample_count, float* out_magnitudes, int32_t out_count) {
    if (g_fft_setup == nullptr || g_fft_size <= 0) return -1;
    
    float* fft_in = (float*)pffft_aligned_malloc((size_t)g_fft_size * sizeof(float));
    float* fft_out = (float*)pffft_aligned_malloc((size_t)g_fft_size * sizeof(float));
    float* work = (float*)pffft_aligned_malloc((size_t)g_fft_size * sizeof(float));

    // Apply Hanning Window
    for (int32_t i = 0; i < g_fft_size; ++i) {
        float window = 0.5f - (0.5f * cosf((2.0f * 3.14159265f * (float)i) / (float)(g_fft_size - 1)));
        fft_in[i] = input_samples[i] * window;
    }

    pffft_transform_ordered(g_fft_setup, fft_in, fft_out, work, PFFFT_FORWARD);
    
    int32_t nyquist_bins = g_fft_size / 2;
    int32_t bins_to_copy = (out_count < nyquist_bins) ? out_count : nyquist_bins;
    
    for (int32_t k = 0; k < bins_to_copy; ++k) {
        float re = fft_out[2 * k];
        float im = fft_out[(2 * k) + 1];
        out_magnitudes[k] = sqrtf((re * re) + (im * im));
    }

    pffft_aligned_free(work);
    pffft_aligned_free(fft_out);
    pffft_aligned_free(fft_in);
    
    return bins_to_copy;
}

int32_t fft_internal_compute_compressed_bands(const float* magnitudes, int32_t bins, float* out_bands, int32_t band_count) {
    if (out_bands == nullptr || band_count <= 0 || g_fft_size <= 0) return -20;

    if (g_smoothed_band_count != band_count) {
        mav_release_smoothed_bands_internal();
        g_smoothed_bands = (float*)calloc((size_t)band_count, sizeof(float));
        g_smoothed_band_count = band_count;
    }

    for (int32_t b = 0; b < band_count; ++b) {
        float t0 = (float)b / (float)band_count;
        float t1 = (float)(b + 1) / (float)band_count;
        int32_t start = (int32_t)(powf((float)bins, t0));
        int32_t end = (int32_t)(powf((float)bins, t1));
        if (start < 1) start = 1;
        if (end <= start) end = start + 1;
        if (end > bins) end = bins;

        float peak = 0.0f;
        for (int32_t i = start; i < end; ++i) {
            if (magnitudes[i] > peak) peak = magnitudes[i];
        }

        float db = 20.0f * log10f(peak + 1.0e-6f);
        float normalized = (db + 80.0f) / 80.0f;
        if (normalized < 0.0f) normalized = 0.0f;
        if (normalized > 1.0f) normalized = 1.0f;

        float& smoothed = g_smoothed_bands[b];
        float attack = 0.70f, decay = 0.90f;
        smoothed = (normalized > smoothed) ? (attack * smoothed + (1.0f - attack) * normalized) : (decay * smoothed + (1.0f - decay) * normalized);
        out_bands[b] = smoothed;
    }
    return band_count;
}

int32_t fft_internal_fill_test_signal(float* out_samples, int32_t sample_count, float phase_step) {
    if (out_samples == nullptr || sample_count <= 0) return -1;
    float phase = 0.0f;
    for (int32_t i = 0; i < sample_count; ++i) {
        out_samples[i] = sinf(phase);
        phase += phase_step;
    }
    return sample_count;
}

int32_t fft_internal_simd_width(void) {
    return pffft_simd_size();
}

} // extern "C"
