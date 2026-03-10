#include "../include/my_audio_visualizer_native.h"

#include <math.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#include <vector>
#include <memory>

#ifdef _WIN32
#include <malloc.h>
#include <windows.h>
#include <mfapi.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <mfmediaengine.h>
#include <wrl/client.h>
#include <shlwapi.h>
#include <audioclient.h>

using Microsoft::WRL::ComPtr;

#pragma comment(lib, "mfplat.lib")
#pragma comment(lib, "mfreadwrite.lib")
#pragma comment(lib, "mfuuid.lib")
#pragma comment(lib, "shlwapi.lib")

#endif

extern "C" {
#include "../third_part/pffft.h"
#include "../third_part/pffft.c"
}

static PFFFT_Setup* g_fft_setup = nullptr;
static int32_t g_fft_size = 0;
static float* g_audio_samples = nullptr;
static uint64_t g_audio_frame_count = 0;
static uint32_t g_audio_sample_rate = 0;
static float* g_smoothed_bands = nullptr;
static int32_t g_smoothed_band_count = 0;

#ifdef _WIN32
// Player state
static ComPtr<IMFMediaEngine> g_media_engine = nullptr;
static ComPtr<IMFMediaEngineClassFactory> g_engine_factory = nullptr;

class MediaEngineNotify : public IMFMediaEngineNotify {
public:
    STDMETHODIMP QueryInterface(REFIID riid, void** ppv) override {
        if (__uuidof(IMFMediaEngineNotify) == riid || __uuidof(IUnknown) == riid) {
            *ppv = static_cast<IMFMediaEngineNotify*>(this);
            return S_OK;
        }
        return E_NOINTERFACE;
    }
    STDMETHODIMP_(ULONG) AddRef() override { return 1; }
    STDMETHODIMP_(ULONG) Release() override { return 1; }
    STDMETHODIMP EventNotify(DWORD event, DWORD_PTR param1, DWORD param2) override { return S_OK; }
};

static MediaEngineNotify g_notify_callback;

static HRESULT EnsureMFInit() {
    static bool inited = false;
    if (inited) return S_OK;
    HRESULT hr = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    if (FAILED(hr) && hr != RPC_E_CHANGED_MODE) return hr;
    hr = MFStartup(MF_VERSION);
    if (FAILED(hr)) return hr;
    inited = true;
    return S_OK;
}
#endif

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

static void mav_release_audio_buffer(void) {
    if (g_audio_samples != nullptr) {
        free(g_audio_samples);
        g_audio_samples = nullptr;
    }
    g_audio_frame_count = 0;
    g_audio_sample_rate = 0;
}

static void mav_release_smoothed_bands(void) {
    if (g_smoothed_bands != nullptr) {
        free(g_smoothed_bands);
        g_smoothed_bands = nullptr;
    }
    g_smoothed_band_count = 0;
}

MAV_EXPORT int32_t mav_create_fft(int32_t fft_size) {
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

MAV_EXPORT void mav_dispose_fft(void) {
    mav_release_audio_buffer();
    mav_release_smoothed_bands();
    if (g_fft_setup != nullptr) {
        pffft_destroy_setup(g_fft_setup);
        g_fft_setup = nullptr;
        g_fft_size = 0;
    }
#ifdef _WIN32
    g_media_engine.Reset();
    g_engine_factory.Reset();
#endif
}

MAV_EXPORT int32_t mav_load_audio_file(const char* file_path) {
    if (file_path == nullptr || file_path[0] == '\0') return -1;
#ifdef _WIN32
    if (FAILED(EnsureMFInit())) return -100;

    int wide_len = MultiByteToWideChar(CP_UTF8, 0, file_path, -1, nullptr, 0);
    std::vector<wchar_t> wide_path(wide_len);
    MultiByteToWideChar(CP_UTF8, 0, file_path, -1, wide_path.data(), wide_len);

    ComPtr<IMFSourceReader> reader;
    HRESULT hr = MFCreateSourceReaderFromURL(wide_path.data(), nullptr, &reader);
    if (FAILED(hr)) return -101;

    // Set output type to Float PCM
    ComPtr<IMFMediaType> type;
    hr = MFCreateMediaType(&type);
    hr = type->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio);
    hr = type->SetGUID(MF_MT_SUBTYPE, MFAudioFormat_Float);
    hr = reader->SetCurrentMediaType((DWORD)MF_SOURCE_READER_FIRST_AUDIO_STREAM, nullptr, type.Get());
    if (FAILED(hr)) return -102;

    // Get real format
    ComPtr<IMFMediaType> current_type;
    hr = reader->GetCurrentMediaType((DWORD)MF_SOURCE_READER_FIRST_AUDIO_STREAM, &current_type);
    UINT32 channels = 0, sample_rate = 0;
    current_type->GetUINT32(MF_MT_AUDIO_NUM_CHANNELS, &channels);
    current_type->GetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND, &sample_rate);

    if (channels == 0 || sample_rate == 0) return -103;

    std::vector<float> all_samples;
    while (true) {
        DWORD flags = 0;
        ComPtr<IMFSample> sample;
        hr = reader->ReadSample((DWORD)MF_SOURCE_READER_FIRST_AUDIO_STREAM, 0, nullptr, &flags, nullptr, &sample);
        if (FAILED(hr) || (flags & MF_SOURCE_READERF_ENDOFSTREAM)) break;
        if (!sample) continue;

        ComPtr<IMFMediaBuffer> buffer;
        hr = sample->ConvertToContiguousBuffer(&buffer);
        if (FAILED(hr)) continue;
        BYTE* data = nullptr;
        DWORD len = 0;
        hr = buffer->Lock(&data, nullptr, &len);
        if (SUCCEEDED(hr)) {
            float* f_data = (float*)data;
            size_t count = len / sizeof(float);
            for (size_t i = 0; i < count; i += channels) {
                float mixed = 0;
                for (size_t c = 0; c < channels && (i + c) < count; c++) mixed += f_data[i + c];
                all_samples.push_back(mixed / (float)channels);
            }
            buffer->Unlock();
        }
    }

    mav_release_audio_buffer();
    if (all_samples.size() > 0) {
        g_audio_samples = (float*)malloc(all_samples.size() * sizeof(float));
        memcpy(g_audio_samples, all_samples.data(), all_samples.size() * sizeof(float));
    }
    g_audio_frame_count = all_samples.size();
    g_audio_sample_rate = sample_rate;
    return 0;
#else
    return -999;
#endif
}

MAV_EXPORT int32_t mav_open_audio_for_playback(const char* file_path) {
#ifdef _WIN32

    fprintf(stderr, "mav_open_audio_for_playback executing\n");
    fprintf(stderr, "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\n");
    if (FAILED(EnsureMFInit())) return -200;
    
    if (g_media_engine.Get()) {
        g_media_engine->Pause();
        g_media_engine.Reset();
    }

    if (!g_engine_factory.Get()) {
        HRESULT hr = CoCreateInstance(CLSID_MFMediaEngineClassFactory, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&g_engine_factory));
        if (FAILED(hr)) return -201;
    }

    ComPtr<IMFAttributes> attr;
    MFCreateAttributes(&attr, 1);
    attr->SetUnknown(MF_MEDIA_ENGINE_CALLBACK, &g_notify_callback);
    attr->SetUINT32(MF_MEDIA_ENGINE_AUDIO_CATEGORY, AudioCategory_Other);

    HRESULT hr = g_engine_factory->CreateInstance(0, attr.Get(), &g_media_engine);
    if (FAILED(hr)) return -202;

    int wide_len = MultiByteToWideChar(CP_UTF8, 0, file_path, -1, nullptr, 0);
    std::vector<wchar_t> wide_path(wide_len);
    MultiByteToWideChar(CP_UTF8, 0, file_path, -1, wide_path.data(), wide_len);
    
    BSTR bstr_url = SysAllocString(wide_path.data());
    hr = g_media_engine->SetSource(bstr_url);
    SysFreeString(bstr_url);
    
    return SUCCEEDED(hr) ? 0 : -203;
#else
    return -999;
#endif
}

MAV_EXPORT int32_t mav_player_play(void) {
#ifdef _WIN32
    if (!g_media_engine.Get()) return -1;
    return SUCCEEDED(g_media_engine->Play()) ? 0 : -1;
#else
    return -1;
#endif
}

MAV_EXPORT int32_t mav_player_pause(void) {
#ifdef _WIN32
    if (!g_media_engine.Get()) return -1;
    return SUCCEEDED(g_media_engine->Pause()) ? 0 : -1;
#else
    return -1;
#endif
}

MAV_EXPORT int32_t mav_player_seek_ms(int32_t position_ms) {
#ifdef _WIN32
    if (!g_media_engine.Get()) return -1;
    return SUCCEEDED(g_media_engine->SetCurrentTime((double)position_ms / 1000.0)) ? 0 : -1;
#else
    return -1;
#endif
}

MAV_EXPORT int32_t mav_player_get_position_ms(void) {
#ifdef _WIN32
    if (!g_media_engine.Get()) return 0;
    return (int32_t)(g_media_engine->GetCurrentTime() * 1000.0);
#else
    return 0;
#endif
}

MAV_EXPORT int32_t mav_player_is_playing(void) {
#ifdef _WIN32
    if (!g_media_engine.Get()) return 0;
    bool paused = g_media_engine->IsPaused();
    return !paused ? 1 : 0;
#else
    return 0;
#endif
}

MAV_EXPORT int32_t mav_player_set_volume(float volume) {
#ifdef _WIN32
    if (!g_media_engine.Get()) return -1;
    double vol = (double)((volume < 0.0f) ? 0.0f : (volume > 1.0f ? 1.0f : volume));
    return SUCCEEDED(g_media_engine->SetVolume(vol)) ? 0 : -1;
#else
    return -999;
#endif
}

MAV_EXPORT void mav_unload_audio_file(void) {
#ifdef _WIN32
    if (g_media_engine.Get()) {
        g_media_engine->Pause();
        g_media_engine.Reset();
    }
#endif
    mav_release_audio_buffer();
    mav_release_smoothed_bands();
}

MAV_EXPORT int32_t mav_get_audio_duration_ms(void) {
    if (g_audio_samples == nullptr || g_audio_sample_rate == 0) return 0;
    return (int32_t)((g_audio_frame_count * 1000ULL) / g_audio_sample_rate);
}

static int32_t mav_compute_spectrum_internal(const float* input_samples, int32_t sample_count, float* out_magnitudes, int32_t out_count) {
    if (g_fft_setup == nullptr || g_fft_size <= 0) return -1;
    float* fft_in = (float*)pffft_aligned_malloc((size_t)g_fft_size * sizeof(float));
    float* fft_out = (float*)pffft_aligned_malloc((size_t)g_fft_size * sizeof(float));
    float* work = (float*)pffft_aligned_malloc((size_t)g_fft_size * sizeof(float));
    
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

MAV_EXPORT int32_t mav_compute_spectrum_at_ms(int32_t position_ms, float* out_magnitudes, int32_t out_count) {
    if (g_audio_samples == nullptr || g_audio_sample_rate == 0 || g_fft_size <= 0) return -10;
    float* frame = (float*)pffft_aligned_malloc((size_t)g_fft_size * sizeof(float));
    uint64_t center = ((uint64_t)position_ms * g_audio_sample_rate) / 1000ULL;
    int64_t start = (int64_t)center - (g_fft_size / 2);
    for (int32_t i = 0; i < g_fft_size; ++i) {
        int64_t index = start + i;
        frame[i] = (index >= 0 && (uint64_t)index < g_audio_frame_count) ? g_audio_samples[index] : 0.0f;
    }
    int32_t result = mav_compute_spectrum_internal(frame, g_fft_size, out_magnitudes, out_count);
    pffft_aligned_free(frame);
    return result;
}

MAV_EXPORT int32_t mav_compute_compressed_bands_at_ms(int32_t position_ms, float* out_bands, int32_t band_count) {
    if (out_bands == nullptr || band_count <= 0 || g_fft_size <= 0) return -20;
    int32_t nyquist_bins = g_fft_size / 2;
    std::vector<float> magnitudes(nyquist_bins);
    int32_t bins = mav_compute_spectrum_at_ms(position_ms, magnitudes.data(), nyquist_bins);
    if (bins <= 0) return bins;

    if (g_smoothed_band_count != band_count) {
        mav_release_smoothed_bands();
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
        for (int32_t i = start; i < end; ++i) if (magnitudes[i] > peak) peak = magnitudes[i];

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

MAV_EXPORT int32_t mav_fill_test_signal(float* out_samples, int32_t sample_count, float phase_step) {
    if (out_samples == nullptr || sample_count <= 0) return -1;
    float phase = 0.0f;
    for (int32_t i = 0; i < sample_count; ++i) {
        out_samples[i] = sinf(phase);
        phase += phase_step;
    }
    return sample_count;
}

MAV_EXPORT int32_t mav_compute_spectrum(const float* input_samples, int32_t sample_count, float* out_magnitudes, int32_t out_count) {
    return mav_compute_spectrum_internal(input_samples, sample_count, out_magnitudes, out_count);
}

MAV_EXPORT int32_t mav_simd_width(void) { return pffft_simd_size(); }

} // extern "C"
