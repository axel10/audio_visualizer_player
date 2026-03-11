#include "../include/my_audio_visualizer_native.h"
#include "../include/fft_utils.h"

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
#include <propvarutil.h>

using Microsoft::WRL::ComPtr;

#pragma comment(lib, "mfplat.lib")
#pragma comment(lib, "mfreadwrite.lib")
#pragma comment(lib, "mfuuid.lib")
#pragma comment(lib, "shlwapi.lib")

#endif

static float* g_audio_samples = nullptr;
static uint64_t g_audio_frame_count = 0;
static uint32_t g_audio_sample_rate = 0;

#ifdef _WIN32
// Player state
static ComPtr<IMFMediaEngine> g_media_engine = nullptr;
static ComPtr<IMFMediaEngineClassFactory> g_engine_factory = nullptr;

// Analysis (streaming) state
static ComPtr<IMFSourceReader> g_analysis_reader = nullptr;
static uint32_t g_analysis_channels = 0;
static uint32_t g_analysis_sample_rate = 0;
static uint64_t g_analysis_duration_ms = 0;
static std::vector<float> g_stream_cache;
static uint64_t g_cache_start_frame = 0;
static uint64_t g_cache_frame_count = 0;

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

static void mav_release_audio_buffer(void) {
    // fprintf(stderr, "mav: mav_release_audio_buffer\n");
    if (g_audio_samples != nullptr) {
        free(g_audio_samples);
        g_audio_samples = nullptr;
    }
    g_audio_frame_count = 0;
    g_audio_sample_rate = 0;
}

static void mav_release_stream_cache(void) {
#ifdef _WIN32
    g_stream_cache.clear();
    g_cache_start_frame = 0;
    g_cache_frame_count = 0;
#endif
}

static void mav_release_analysis_reader(void) {
#ifdef _WIN32
    g_analysis_reader.Reset();
    g_analysis_channels = 0;
    g_analysis_sample_rate = 0;
    g_analysis_duration_ms = 0;
    mav_release_stream_cache();
#endif
}

MAV_EXPORT int32_t mav_create_fft(int32_t fft_size) {
    return fft_internal_create(fft_size);
}

MAV_EXPORT void mav_dispose_fft(void) {
    // fprintf(stderr, "mav: mav_dispose_fft\n");
    mav_release_audio_buffer();
    fft_internal_dispose();
#ifdef _WIN32
    g_media_engine.Reset();
    g_engine_factory.Reset();
    mav_release_analysis_reader();
#endif
}

MAV_EXPORT int32_t mav_load_audio_file(const char* file_path) {
    // fprintf(stderr, "mav: mav_load_audio_file file_path=%s\n", (file_path?file_path:"(null)"));
    if (file_path == nullptr || file_path[0] == '\0') return -1;
#ifdef _WIN32
    if (FAILED(EnsureMFInit())) return -100;

    mav_release_audio_buffer();
    mav_release_analysis_reader();

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

    PROPVARIANT var;
    PropVariantInit(&var);
    hr = reader->GetPresentationAttribute(MF_SOURCE_READER_MEDIASOURCE, MF_PD_DURATION, &var);
    if (SUCCEEDED(hr) && var.vt == VT_UI8) {
        g_analysis_duration_ms = (uint64_t)(var.uhVal.QuadPart / 10000ULL);
    } else {
        g_analysis_duration_ms = 0;
    }
    PropVariantClear(&var);

    g_analysis_reader = reader;
    g_analysis_channels = channels;
    g_analysis_sample_rate = sample_rate;
    mav_release_stream_cache();
    return 0;
#else
    return -999;
#endif
}

MAV_EXPORT int32_t mav_open_audio_for_playback(const char* file_path) {
#ifdef _WIN32

    // fprintf(stderr, "mav: mav_open_audio_for_playback file_path=%s\n", (file_path?file_path:"(null)"));
    // fprintf(stderr, "mav: mav_open_audio_for_playback start\n");
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
    // // fprintf(stderr, "mav: mav_open_audio_for_playback SetSource hr=0x%08x\n", (unsigned)hr);
    return SUCCEEDED(hr) ? 0 : -203;
#else
    return -999;
#endif
}

MAV_EXPORT int32_t mav_player_play(void) {
#ifdef _WIN32
    // // fprintf(stderr, "mav: mav_player_play\n");
    if (!g_media_engine.Get()) return -1;
    return SUCCEEDED(g_media_engine->Play()) ? 0 : -1;
#else
    return -1;
#endif
}

MAV_EXPORT int32_t mav_player_pause(void) {
#ifdef _WIN32
    // fprintf(stderr, "mav: mav_player_pause\n");
    if (!g_media_engine.Get()) return -1;
    return SUCCEEDED(g_media_engine->Pause()) ? 0 : -1;
#else
    return -1;
#endif
}

MAV_EXPORT int32_t mav_player_seek_ms(int32_t position_ms) {
#ifdef _WIN32
    // fprintf(stderr, "mav: mav_player_seek_ms position_ms=%d\n", position_ms);
    if (!g_media_engine.Get()) return -1;
    return SUCCEEDED(g_media_engine->SetCurrentTime((double)position_ms / 1000.0)) ? 0 : -1;
#else
    return -1;
#endif
}

MAV_EXPORT int32_t mav_player_get_position_ms(void) {
#ifdef _WIN32
    // fprintf(stderr, "mav: mav_player_get_position_ms\n");
    if (!g_media_engine.Get()) return 0;
    return (int32_t)(g_media_engine->GetCurrentTime() * 1000.0);
#else
    return 0;
#endif
}

MAV_EXPORT int32_t mav_player_is_playing(void) {
#ifdef _WIN32
    // fprintf(stderr, "mav: mav_player_is_playing\n");
    if (!g_media_engine.Get()) return 0;
    bool paused = g_media_engine->IsPaused();
    return !paused ? 1 : 0;
#else
    return 0;
#endif
}

MAV_EXPORT int32_t mav_player_set_volume(float volume) {
#ifdef _WIN32
    // fprintf(stderr, "mav: mav_player_set_volume volume=%f\n", volume);
    if (!g_media_engine.Get()) return -1;
    double vol = (double)((volume < 0.0f) ? 0.0f : (volume > 1.0f ? 1.0f : volume));
    return SUCCEEDED(g_media_engine->SetVolume(vol)) ? 0 : -1;
#else
    return -999;
#endif
}

MAV_EXPORT void mav_unload_audio_file(void) {
#ifdef _WIN32
    // fprintf(stderr, "mav: mav_unload_audio_file\n");
    if (g_media_engine.Get()) {
        g_media_engine->Pause();
        g_media_engine.Reset();
    }
#endif
    mav_release_audio_buffer();
    mav_release_analysis_reader();
    // g_smoothed_bands is now handled in fft_utils.cpp via mav_dispose_fft_internal
}

MAV_EXPORT int32_t mav_get_audio_duration_ms(void) {
    // fprintf(stderr, "mav: mav_get_audio_duration_ms\n");
#ifdef _WIN32
    if (g_analysis_duration_ms > 0) return (int32_t)g_analysis_duration_ms;
#endif
    if (g_audio_samples == nullptr || g_audio_sample_rate == 0) return 0;
    return (int32_t)((g_audio_frame_count * 1000ULL) / g_audio_sample_rate);
}

MAV_EXPORT int32_t mav_compute_spectrum_at_ms(int32_t position_ms, float* out_magnitudes, int32_t out_count) {
    // fprintf(stderr, "mav: mav_compute_spectrum_at_ms position_ms=%d out_count=%d\n", position_ms, out_count);
    int32_t fft_size = fft_internal_get_size();
#ifdef _WIN32
    if (!g_analysis_reader.Get() || g_analysis_sample_rate == 0 || g_analysis_channels == 0 || fft_size <= 0) return -10;

    uint64_t center = ((uint64_t)position_ms * g_analysis_sample_rate) / 1000ULL;
    int64_t start = (int64_t)center - (fft_size / 2);
    uint64_t start_frame = (start < 0) ? 0 : (uint64_t)start;
    uint64_t needed_frames = (start < 0) ? (uint64_t)(fft_size + start) : (uint64_t)fft_size;

    if (needed_frames > 0) {
        uint64_t cache_end = g_cache_start_frame + g_cache_frame_count;
        bool cache_ok = (g_cache_frame_count > 0 &&
            start_frame >= g_cache_start_frame &&
            (start_frame + needed_frames) <= cache_end);

        if (!cache_ok) {
            g_stream_cache.clear();
            g_cache_start_frame = start_frame;
            g_cache_frame_count = 0;

            PROPVARIANT var;
            PropVariantInit(&var);
            var.vt = VT_I8;
            uint64_t pos_100ns = (start_frame * 10000000ULL) / (uint64_t)g_analysis_sample_rate;
            var.hVal.QuadPart = (LONGLONG)pos_100ns;
            HRESULT hr_seek = g_analysis_reader->SetCurrentPosition(GUID_NULL, var);
            PropVariantClear(&var);
            if (FAILED(hr_seek)) return -11;

            while (g_cache_frame_count < needed_frames) {
                DWORD flags = 0;
                ComPtr<IMFSample> sample;
                HRESULT hr = g_analysis_reader->ReadSample((DWORD)MF_SOURCE_READER_FIRST_AUDIO_STREAM, 0, nullptr, &flags, nullptr, &sample);
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
                    size_t total_floats = len / sizeof(float);
                    size_t total_frames = total_floats / g_analysis_channels;
                    size_t frames_to_copy = total_frames;
                    if (g_cache_frame_count + frames_to_copy > needed_frames) {
                        frames_to_copy = (size_t)(needed_frames - g_cache_frame_count);
                    }
                    size_t floats_to_copy = frames_to_copy * g_analysis_channels;
                    g_stream_cache.insert(g_stream_cache.end(), f_data, f_data + floats_to_copy);
                    g_cache_frame_count += frames_to_copy;
                    buffer->Unlock();
                }
            }
        }
    }

    float* frame = (float*)pffft_aligned_malloc((size_t)fft_size * sizeof(float));
    for (int32_t i = 0; i < fft_size; ++i) {
        int64_t index = start + i;
        if (index < 0) {
            frame[i] = 0.0f;
            continue;
        }
        uint64_t uindex = (uint64_t)index;
        if (uindex < g_cache_start_frame || uindex >= (g_cache_start_frame + g_cache_frame_count)) {
            frame[i] = 0.0f;
            continue;
        }
        uint64_t local = uindex - g_cache_start_frame;
        uint64_t base = local * g_analysis_channels;
        float mixed = 0.0f;
        for (uint32_t c = 0; c < g_analysis_channels; ++c) {
            mixed += g_stream_cache[base + c];
        }
        frame[i] = mixed / (float)g_analysis_channels;
    }

    int32_t result = fft_internal_compute_spectrum(frame, fft_size, out_magnitudes, out_count);
    pffft_aligned_free(frame);
    return result;
#else
    if (g_audio_samples == nullptr || g_audio_sample_rate == 0 || fft_size <= 0) return -10;
    float* frame = (float*)pffft_aligned_malloc((size_t)fft_size * sizeof(float));
    uint64_t center = ((uint64_t)position_ms * g_audio_sample_rate) / 1000ULL;
    int64_t start = (int64_t)center - (fft_size / 2);
    for (int32_t i = 0; i < fft_size; ++i) {
        int64_t index = start + i;
        frame[i] = (index >= 0 && (uint64_t)index < g_audio_frame_count) ? g_audio_samples[index] : 0.0f;
    }
    int32_t result = fft_internal_compute_spectrum(frame, fft_size, out_magnitudes, out_count);
    pffft_aligned_free(frame);
    return result;
#endif
}

MAV_EXPORT int32_t mav_compute_compressed_bands_at_ms(int32_t position_ms, float* out_bands, int32_t band_count) {
    // fprintf(stderr, "mav: mav_compute_compressed_bands_at_ms position_ms=%d band_count=%d\n", position_ms, band_count);
    int32_t fft_size = fft_internal_get_size();
    if (out_bands == nullptr || band_count <= 0 || fft_size <= 0) return -20;
    int32_t nyquist_bins = fft_size / 2;
    std::vector<float> magnitudes(nyquist_bins);
    int32_t bins = mav_compute_spectrum_at_ms(position_ms, magnitudes.data(), nyquist_bins);
    if (bins <= 0) return bins;

    return fft_internal_compute_compressed_bands(magnitudes.data(), bins, out_bands, band_count);
}

MAV_EXPORT int32_t mav_fill_test_signal(float* out_samples, int32_t sample_count, float phase_step) {
    return fft_internal_fill_test_signal(out_samples, sample_count, phase_step);
}

MAV_EXPORT int32_t mav_compute_spectrum(const float* input_samples, int32_t sample_count, float* out_magnitudes, int32_t out_count) {
    return fft_internal_compute_spectrum(input_samples, sample_count, out_magnitudes, out_count);
}

MAV_EXPORT int32_t mav_simd_width(void) {
    return fft_internal_simd_width();
}

} // extern "C"
