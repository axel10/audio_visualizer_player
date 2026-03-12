#include "../include/my_audio_visualizer_native.h"

#include <math.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#include <vector>
#include <mutex>
#include <memory>

#ifdef _WIN32
#include <windows.h>
#include <mfapi.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <wrl/client.h>
#include <propvarutil.h>

#include "soloud.h"
#include "soloud_audiosource.h"
#include "soloud_file.h"

using Microsoft::WRL::ComPtr;

#pragma comment(lib, "mfplat.lib")
#pragma comment(lib, "mfreadwrite.lib")
#pragma comment(lib, "mfuuid.lib")

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

class MFStreamSource;

class MFStreamInstance : public SoLoud::AudioSourceInstance {
public:
    MFStreamSource* mParent;
    ComPtr<IMFSourceReader> mReader;
    bool mEnded;
    std::vector<float> mLeftover;
    size_t mLeftoverPos;
    
    MFStreamInstance(MFStreamSource* parent);
    virtual ~MFStreamInstance();

    virtual unsigned int getAudio(float *aBuffer, unsigned int aSamplesToRead, unsigned int aBufferSize) override;
    virtual bool hasEnded() override;
    virtual SoLoud::result seek(SoLoud::time aSeconds, float *mScratch, unsigned int mScratchSize) override;
    virtual SoLoud::result rewind() override;
};

class MFStreamSource : public SoLoud::AudioSource {
public:
    std::wstring mPath;
    uint64_t mDurationMs;

    MFStreamSource() : mDurationMs(0) {
        mChannels = 2;
        mBaseSamplerate = 44100;
    }
    virtual ~MFStreamSource() {}

    int load(const char* file_path);
    virtual SoLoud::AudioSourceInstance *createInstance() override;
};

MFStreamInstance::MFStreamInstance(MFStreamSource* parent) : mParent(parent), mEnded(false), mLeftoverPos(0) {
    if (!parent || parent->mPath.empty()) {
        mEnded = true;
        return;
    }
    
    EnsureMFInit();
    
    HRESULT hr = MFCreateSourceReaderFromURL(parent->mPath.c_str(), nullptr, &mReader);
    if (FAILED(hr)) {
        mEnded = true;
        return;
    }
    
    ComPtr<IMFMediaType> type;
    MFCreateMediaType(&type);
    type->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio);
    type->SetGUID(MF_MT_SUBTYPE, MFAudioFormat_Float);
    hr = mReader->SetCurrentMediaType((DWORD)MF_SOURCE_READER_FIRST_AUDIO_STREAM, nullptr, type.Get());
    if (FAILED(hr)) {
        mEnded = true;
        return;
    }
    
    mReader->SetStreamSelection((DWORD)MF_SOURCE_READER_ALL_STREAMS, FALSE);
    mReader->SetStreamSelection((DWORD)MF_SOURCE_READER_FIRST_AUDIO_STREAM, TRUE);
}

MFStreamInstance::~MFStreamInstance() {}

bool MFStreamInstance::hasEnded() {
    return mEnded;
}

SoLoud::result MFStreamInstance::rewind() {
    return seek(0, nullptr, 0);
}

SoLoud::result MFStreamInstance::seek(SoLoud::time aSeconds, float *mScratch, unsigned int mScratchSize) {
    if (!mReader) return SoLoud::UNKNOWN_ERROR;
    
    PROPVARIANT var;
    PropVariantInit(&var);
    var.vt = VT_I8;
    var.hVal.QuadPart = (LONGLONG)(aSeconds * 10000000.0);
    
    HRESULT hr = mReader->SetCurrentPosition(GUID_NULL, var);
    PropVariantClear(&var);

    if (SUCCEEDED(hr)) {
        this->mStreamPosition = aSeconds;
        this->mStreamTime = aSeconds;
        mLeftover.clear();
        mLeftoverPos = 0;
        mEnded = false;
        return SoLoud::SO_NO_ERROR;
    }
    return SoLoud::UNKNOWN_ERROR;
}

unsigned int MFStreamInstance::getAudio(float *aBuffer, unsigned int aSamplesToRead, unsigned int aBufferSize) {
    if (mEnded || !mReader) return 0;
    
    unsigned int samplesWritten = 0;
    unsigned int channels = mChannels;
    if (channels == 0) channels = 1;
    
    while (samplesWritten < aSamplesToRead && !mEnded) {
        size_t availableFrames = (mLeftover.size() - mLeftoverPos) / channels;
        if (availableFrames > 0) {
            unsigned int framesToCopy = aSamplesToRead - samplesWritten;
            if (framesToCopy > availableFrames) framesToCopy = (unsigned int)availableFrames;
            
            for (unsigned int c = 0; c < channels; ++c) {
                for (unsigned int i = 0; i < framesToCopy; ++i) {
                    aBuffer[c * aBufferSize + samplesWritten + i] = mLeftover[mLeftoverPos + i * channels + c];
                }
            }
            
            samplesWritten += framesToCopy;
            mLeftoverPos += framesToCopy * channels;
            continue;
        }
        
        DWORD flags = 0;
        ComPtr<IMFSample> sample;
        HRESULT hr = mReader->ReadSample((DWORD)MF_SOURCE_READER_FIRST_AUDIO_STREAM, 0, nullptr, &flags, nullptr, &sample);
        
        if (FAILED(hr) || (flags & MF_SOURCE_READERF_ENDOFSTREAM)) {
            mEnded = true;
            break;
        }
        
        if (!sample) continue;
        
        ComPtr<IMFMediaBuffer> buffer;
        hr = sample->ConvertToContiguousBuffer(&buffer);
        if (FAILED(hr)) continue;
        
        BYTE* data = nullptr;
        DWORD len = 0;
        if (SUCCEEDED(buffer->Lock(&data, nullptr, &len))) {
            size_t numFloats = len / sizeof(float);
            float* f_data = (float*)data;
            mLeftover.assign(f_data, f_data + numFloats);
            mLeftoverPos = 0;
            buffer->Unlock();
        }
    }
    
    return samplesWritten;
}

int MFStreamSource::load(const char* file_path) {
    EnsureMFInit();
    
    int wide_len = MultiByteToWideChar(CP_UTF8, 0, file_path, -1, nullptr, 0);
    if (wide_len <= 0) return -1;
    mPath.resize(wide_len);
    MultiByteToWideChar(CP_UTF8, 0, file_path, -1, &mPath[0], wide_len);
    if (!mPath.empty() && mPath.back() == L'\0') {
        mPath.pop_back();
    }
    
    ComPtr<IMFSourceReader> reader;
    HRESULT hr = MFCreateSourceReaderFromURL(mPath.c_str(), nullptr, &reader);
    if (FAILED(hr)) return -2;
    
    ComPtr<IMFMediaType> type;
    MFCreateMediaType(&type);
    type->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio);
    type->SetGUID(MF_MT_SUBTYPE, MFAudioFormat_Float);
    hr = reader->SetCurrentMediaType((DWORD)MF_SOURCE_READER_FIRST_AUDIO_STREAM, nullptr, type.Get());
    if (FAILED(hr)) return -3;
    
    ComPtr<IMFMediaType> current_type;
    hr = reader->GetCurrentMediaType((DWORD)MF_SOURCE_READER_FIRST_AUDIO_STREAM, &current_type);
    UINT32 channels = 0, sample_rate = 0;
    if (SUCCEEDED(hr)) {
        current_type->GetUINT32(MF_MT_AUDIO_NUM_CHANNELS, &channels);
        current_type->GetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND, &sample_rate);
    }
    if (channels == 0) channels = 2;
    if (sample_rate == 0) sample_rate = 44100;
    
    mBaseSamplerate = (float)sample_rate;
    mChannels = channels;
    
    PROPVARIANT var;
    PropVariantInit(&var);
    hr = reader->GetPresentationAttribute(MF_SOURCE_READER_MEDIASOURCE, MF_PD_DURATION, &var);
    if (SUCCEEDED(hr) && var.vt == VT_UI8) {
        mDurationMs = (uint64_t)(var.uhVal.QuadPart / 10000ULL);
    } else {
        mDurationMs = 0;
    }
    PropVariantClear(&var);
    
    return 0;
}

SoLoud::AudioSourceInstance* MFStreamSource::createInstance() {
    return new MFStreamInstance(this);
}

static std::recursive_mutex g_mav_mutex;
static SoLoud::Soloud g_soloud;
static bool g_soloud_inited = false;
static MFStreamSource* g_current_source = nullptr;
static int g_current_handle = 0;
static float g_current_volume = 1.0f;
static float* g_smoothed_bands = nullptr;
static int32_t g_smoothed_band_count = 0;

static void EnsureSoloudInited() {
    if (!g_soloud_inited) {
        g_soloud.init();
        g_soloud.setVisualizationEnable(1);
        g_soloud_inited = true;
    }
}
#endif // _WIN32

extern "C" {

MAV_EXPORT int32_t mav_create_fft(int32_t fft_size) {
    // We ignore fft_size because SoLoud uses fixed 1024 bands for its visualizer
    return 0;
}

MAV_EXPORT void mav_dispose_fft(void) {
    std::lock_guard<std::recursive_mutex> lock(g_mav_mutex);
#ifdef _WIN32
    if (g_smoothed_bands != nullptr) {
        free(g_smoothed_bands);
        g_smoothed_bands = nullptr;
    }
    g_smoothed_band_count = 0;
    
    if (g_soloud_inited) {
        g_soloud.deinit();
        g_soloud_inited = false;
    }
    if (g_current_source) {
        delete g_current_source;
        g_current_source = nullptr;
    }
    g_current_handle = 0;
#endif
}

MAV_EXPORT int32_t mav_load_audio_file(const char* file_path) {
    std::lock_guard<std::recursive_mutex> lock(g_mav_mutex);
#ifdef _WIN32
    if (!file_path || file_path[0] == '\0') return -1;
    EnsureSoloudInited();
    
    if (g_current_source) {
        g_soloud.stopAll();
        delete g_current_source;
        g_current_source = nullptr;
    }
    
    g_current_source = new MFStreamSource();
    if (g_current_source->load(file_path) != 0) {
        delete g_current_source;
        g_current_source = nullptr;
        return -2;
    }
    return 0;
#else
    return -999;
#endif
}

MAV_EXPORT int32_t mav_open_audio_for_playback(const char* file_path) {
    return mav_load_audio_file(file_path);
}

MAV_EXPORT int32_t mav_player_play(void) {
    std::lock_guard<std::recursive_mutex> lock(g_mav_mutex);
#ifdef _WIN32
    if (!g_current_source) return -1;
    EnsureSoloudInited();
    
    if (g_soloud.isValidVoiceHandle(g_current_handle) && g_soloud.getPause(g_current_handle)) {
        g_soloud.setPause(g_current_handle, 0);
        return 0;
    }
    
    g_current_handle = g_soloud.play(*g_current_source, g_current_volume);
    return 0;
#else
    return -1;
#endif
}

MAV_EXPORT int32_t mav_player_pause(void) {
    std::lock_guard<std::recursive_mutex> lock(g_mav_mutex);
#ifdef _WIN32
    EnsureSoloudInited();
    if (g_soloud.isValidVoiceHandle(g_current_handle)) {
        g_soloud.setPause(g_current_handle, 1);
    }
    return 0;
#else
    return -1;
#endif
}

MAV_EXPORT int32_t mav_player_seek_ms(int32_t position_ms) {
    std::lock_guard<std::recursive_mutex> lock(g_mav_mutex);
#ifdef _WIN32
    EnsureSoloudInited();
    if (g_soloud.isValidVoiceHandle(g_current_handle)) {
        g_soloud.seek(g_current_handle, position_ms / 1000.0);
    }
    return 0;
#else
    return -1;
#endif
}

MAV_EXPORT int32_t mav_player_get_position_ms(void) {
    std::lock_guard<std::recursive_mutex> lock(g_mav_mutex);
#ifdef _WIN32
    EnsureSoloudInited();
    if (g_soloud.isValidVoiceHandle(g_current_handle)) {
        return (int32_t)(g_soloud.getStreamPosition(g_current_handle) * 1000.0);
    }
    return 0;
#else
    return 0;
#endif
}

MAV_EXPORT int32_t mav_player_is_playing(void) {
    std::lock_guard<std::recursive_mutex> lock(g_mav_mutex);
#ifdef _WIN32
    EnsureSoloudInited();
    if (g_soloud.isValidVoiceHandle(g_current_handle)) {
        return !g_soloud.getPause(g_current_handle) ? 1 : 0;
    }
    return 0;
#else
    return 0;
#endif
}

MAV_EXPORT int32_t mav_player_set_volume(float volume) {
    std::lock_guard<std::recursive_mutex> lock(g_mav_mutex);
#ifdef _WIN32
    EnsureSoloudInited();
    g_current_volume = volume;
    if (g_soloud.isValidVoiceHandle(g_current_handle)) {
        g_soloud.setVolume(g_current_handle, volume);
    }
    return 0;
#else
    return -999;
#endif
}

MAV_EXPORT void mav_unload_audio_file(void) {
    std::lock_guard<std::recursive_mutex> lock(g_mav_mutex);
#ifdef _WIN32
    EnsureSoloudInited();
    g_soloud.stopAll();
    if (g_current_source) {
        delete g_current_source;
        g_current_source = nullptr;
    }
    g_current_handle = 0;
#endif
}

MAV_EXPORT int32_t mav_get_audio_duration_ms(void) {
    std::lock_guard<std::recursive_mutex> lock(g_mav_mutex);
#ifdef _WIN32
    if (g_current_source) return (int32_t)g_current_source->mDurationMs;
#endif
    return 0;
}

MAV_EXPORT int32_t mav_compute_spectrum_at_ms(int32_t position_ms, float* out_magnitudes, int32_t out_count) {
    std::lock_guard<std::recursive_mutex> lock(g_mav_mutex);
#ifdef _WIN32
    EnsureSoloudInited();
    if (!out_magnitudes || out_count <= 0) return -10;
    
    // Soloud provides 1024 buckets
    float* fft = g_soloud.calcFFT();
    
    // Resample/map 1024 down/up to out_count evenly
    for (int32_t i = 0; i < out_count; ++i) {
        int index = (i * 1024) / out_count;
        if (index > 1023) index = 1023;
        if (index < 0) index = 0;
        out_magnitudes[i] = fft[index];
    }
    return out_count;
#else
    return -10;
#endif
}

MAV_EXPORT int32_t mav_compute_compressed_bands_at_ms(int32_t position_ms, float* out_bands, int32_t band_count) {
    std::lock_guard<std::recursive_mutex> lock(g_mav_mutex);
#ifdef _WIN32
    EnsureSoloudInited();
    if (!out_bands || band_count <= 0) return -20;
    
    if (g_smoothed_band_count != band_count) {
        if (g_smoothed_bands) free(g_smoothed_bands);
        g_smoothed_bands = (float*)calloc((size_t)band_count, sizeof(float));
        g_smoothed_band_count = band_count;
    }
    
    float* fft = g_soloud.calcFFT();
    int32_t bins = 1024;
    
    // Same log-scaling logic as before
    for (int32_t b = 0; b < band_count; ++b) {
        float t0 = (float)b / (float)band_count;
        float t1 = (float)(b + 1) / (float)band_count;
        int32_t start = (int32_t)(powf((float)bins, t0));
        int32_t end = (int32_t)(powf((float)bins, t1));
        
        if (start < 0) start = 0;
        if (end >= bins) end = bins - 1;
        if (start > end) start = end;
        
        float max_val = 0.0f;
        for (int32_t i = start; i <= end; ++i) {
            float v = fft[i];
            if (v > max_val) max_val = v;
        }
        
        // Smoothing
        float prev = g_smoothed_bands[b];
        float cur = max_val;
        if (cur < prev) {
            cur = prev * 0.8f + cur * 0.2f;
        } else {
            cur = prev * 0.2f + cur * 0.8f;
        }
        g_smoothed_bands[b] = cur;
        out_bands[b] = cur;
    }
    return band_count;
#else
    return -20;
#endif
}

MAV_EXPORT int32_t mav_fill_test_signal(float* out_samples, int32_t sample_count, float phase_step) {
    return 0; // Stub out testing logic to simplify
}

MAV_EXPORT int32_t mav_compute_spectrum(const float* input_samples, int32_t sample_count, float* out_magnitudes, int32_t out_count) {
    return 0; // Stub, Soloud handles FFT now
}

MAV_EXPORT int32_t mav_simd_width(void) {
    return 4;
}

} // extern "C"
