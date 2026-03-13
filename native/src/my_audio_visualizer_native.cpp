#include "../include/my_audio_visualizer_native.h"
#include "../third_part/pffft.h"

#include <math.h>
#include <stdint.h>
#include <vector>
#include <mutex>
#include <memory>
#include <atomic>
#include <string>
#include <algorithm>
#include <cstring>

#ifdef _WIN32
#include <windows.h>
#include <mfapi.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <propvarutil.h>
#include <wrl/client.h>

extern "C" {
    void* pffft_aligned_malloc(size_t nb_bytes) {
        return _aligned_malloc(nb_bytes, 64);
    }
    void pffft_aligned_free(void* ptr) {
        _aligned_free(ptr);
    }
}

#define MINIAUDIO_IMPLEMENTATION
#include "../third_part/miniaudio.h"

#define FFT_SIZE 1024

using Microsoft::WRL::ComPtr;

static std::once_flag g_mf_startup_once;
static std::atomic<bool> g_mf_started(false);

static bool EnsureComInitializedForCurrentThread() {
    thread_local bool comChecked = false;
    thread_local bool comReady = false;
    if (comChecked) return comReady;
    comChecked = true;

    HRESULT hr = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    if (SUCCEEDED(hr) || hr == RPC_E_CHANGED_MODE) {
        comReady = true;
    }
    return comReady;
}

static bool EnsureMediaFoundationStarted() {
    std::call_once(g_mf_startup_once, []() {
        if (!EnsureComInitializedForCurrentThread()) {
            g_mf_started.store(false);
            return;
        }
        HRESULT hr = MFStartup(MF_VERSION, MFSTARTUP_NOSOCKET);
        g_mf_started.store(SUCCEEDED(hr));
    });
    return g_mf_started.load();
}

// Helper: convert UTF-8 path to wide string for miniaudio on Windows
static std::wstring Utf8ToWide(const char* utf8) {
    int wide_len = MultiByteToWideChar(CP_UTF8, 0, utf8, -1, nullptr, 0);
    if (wide_len <= 0) return L"";
    std::wstring path(wide_len, L'\0');
    MultiByteToWideChar(CP_UTF8, 0, utf8, -1, &path[0], wide_len);
    if (!path.empty() && path.back() == L'\0') path.pop_back();
    return path;
}

// Represents a unified engine handling MF decode + miniaudio playback + FFT.
class AudioEngine {
public:
    uint64_t mDurationMs;
    uint32_t mChannels;
    uint32_t mSampleRate;

    ComPtr<IMFSourceReader> mReader;
    ma_device mDevice;
    bool mReaderInited;
    bool mDeviceInited;

    std::atomic<bool> mPlaying;
    std::atomic<float> mVolume;
    std::atomic<bool> mStreamEnded;

    std::mutex mDecodeMutex; // protects reader access (seek vs. read)
    std::vector<float> mDecodedCache;
    size_t mDecodedCacheFrameOffset;
    bool mReaderReachedEos;

    // FFT state
    PFFFT_Setup* mPffftSetup;
    std::mutex mRingMutex;
    std::vector<float> mRingBuffer; // Mono downmix for FFT
    size_t mRingPos;
    std::atomic<int64_t> mCurrentPositionMs;
    
    std::vector<float> mSmoothedBands;

    // Track frames delivered to audio output for accurate position
    std::atomic<uint64_t> mFramesPlayed;
    int64_t mSeekBaseMs;

    AudioEngine()
        : mDurationMs(0), mChannels(2), mSampleRate(44100),
                    mReaderInited(false), mDeviceInited(false),
          mPlaying(false), mVolume(1.0f), mStreamEnded(false),
          mRingPos(0), mCurrentPositionMs(0),
                    mFramesPlayed(0), mSeekBaseMs(0),
                    mDecodedCacheFrameOffset(0), mReaderReachedEos(false)
    {
        mPffftSetup = pffft_new_setup(FFT_SIZE, PFFFT_REAL);
        mRingBuffer.resize(FFT_SIZE * 2, 0.0f); // keep 2x FFT size
    }

    ~AudioEngine() {
        Shutdown();
        if (mPffftSetup) {
            pffft_destroy_setup(mPffftSetup);
            mPffftSetup = nullptr;
        }
    }

    void Shutdown() {
        mPlaying = false;
        if (mDeviceInited) {
            ma_device_uninit(&mDevice);
            mDeviceInited = false;
        }
        if (mReaderInited) {
            mReader.Reset();
            mReaderInited = false;
        }
        mDecodedCache.clear();
        mDecodedCacheFrameOffset = 0;
        mReaderReachedEos = false;
        mStreamEnded = false;
    }

    bool ReadMoreDecodedDataIntoCache() {
        if (!mReaderInited || !mReader) {
            return false;
        }
        if (!EnsureComInitializedForCurrentThread() || !EnsureMediaFoundationStarted()) {
            return false;
        }

        while (true) {
            DWORD flags = 0;
            ComPtr<IMFSample> sample;
            HRESULT hr = mReader->ReadSample(
                MF_SOURCE_READER_FIRST_AUDIO_STREAM,
                0,
                nullptr,
                &flags,
                nullptr,
                &sample);
            if (FAILED(hr)) {
                return false;
            }

            if ((flags & MF_SOURCE_READERF_ENDOFSTREAM) != 0) {
                mReaderReachedEos = true;
                return false;
            }

            if (!sample) {
                if ((flags & MF_SOURCE_READERF_CURRENTMEDIATYPECHANGED) != 0) {
                    continue;
                }
                return false;
            }

            ComPtr<IMFMediaBuffer> buffer;
            hr = sample->ConvertToContiguousBuffer(&buffer);
            if (FAILED(hr) || !buffer) {
                return false;
            }

            BYTE* data = nullptr;
            DWORD maxLen = 0;
            DWORD curLen = 0;
            hr = buffer->Lock(&data, &maxLen, &curLen);
            if (FAILED(hr) || !data || curLen == 0) {
                if (SUCCEEDED(hr)) {
                    buffer->Unlock();
                }
                return false;
            }

            size_t sampleCount = static_cast<size_t>(curLen / sizeof(float));
            if (sampleCount > 0) {
                size_t oldSize = mDecodedCache.size();
                mDecodedCache.resize(oldSize + sampleCount);
                memcpy(mDecodedCache.data() + oldSize, data, sampleCount * sizeof(float));
            }
            buffer->Unlock();

            return sampleCount > 0;
        }
    }

    ma_uint64 ReadDecodedPcmFrames(float* out, ma_uint64 requestedFrames) {
        if (!out || requestedFrames == 0 || mChannels == 0) {
            return 0;
        }

        ma_uint64 totalWritten = 0;
        while (totalWritten < requestedFrames) {
            size_t availableFrames = 0;
            if (mDecodedCache.size() >= mDecodedCacheFrameOffset * mChannels) {
                availableFrames = (mDecodedCache.size() / mChannels) - mDecodedCacheFrameOffset;
            }

            if (availableFrames == 0) {
                if (!ReadMoreDecodedDataIntoCache()) {
                    break;
                }
                continue;
            }

            ma_uint64 needFrames = requestedFrames - totalWritten;
            ma_uint64 copyFrames = (needFrames < availableFrames) ? needFrames : static_cast<ma_uint64>(availableFrames);
            size_t copySamples = static_cast<size_t>(copyFrames) * mChannels;
            size_t srcSampleOffset = mDecodedCacheFrameOffset * mChannels;

            memcpy(
                out + totalWritten * mChannels,
                mDecodedCache.data() + srcSampleOffset,
                copySamples * sizeof(float));

            totalWritten += copyFrames;
            mDecodedCacheFrameOffset += static_cast<size_t>(copyFrames);

            size_t totalCachedFrames = mDecodedCache.size() / mChannels;
            if (mDecodedCacheFrameOffset >= totalCachedFrames) {
                mDecodedCache.clear();
                mDecodedCacheFrameOffset = 0;
            }
        }

        return totalWritten;
    }

    // miniaudio data callback - runs on the audio thread
    static void DataCallback(ma_device* pDevice, void* pOutput, const void* pInput, ma_uint32 frameCount) {
        AudioEngine* engine = (AudioEngine*)pDevice->pUserData;
        float* fOutput = (float*)pOutput;
        if (!engine) {
            memset(pOutput, 0, frameCount * 2 * sizeof(float));
            return;
        }
        ma_uint32 ch = engine->mChannels;

        if (!engine->mPlaying.load()) {
            memset(pOutput, 0, frameCount * ch * sizeof(float));
            return;
        }

        // Try to acquire the decode lock; if a seek is in progress output silence.
        std::unique_lock<std::mutex> lock(engine->mDecodeMutex, std::try_to_lock);
        if (!lock.owns_lock()) {
            memset(pOutput, 0, frameCount * ch * sizeof(float));
            return;
        }

        ma_uint64 framesRead = engine->ReadDecodedPcmFrames(fOutput, frameCount);

        // Apply volume
        float vol = engine->mVolume.load();
        ma_uint64 totalSamples = framesRead * ch;
        for (ma_uint64 i = 0; i < totalSamples; i++) {
            fOutput[i] *= vol;
        }

        // Zero remaining frames if we didn't get enough (end of stream)
        if (framesRead < frameCount) {
            memset(fOutput + framesRead * ch, 0,
                   (frameCount - framesRead) * ch * sizeof(float));
            if (engine->mReaderReachedEos) {
                engine->mStreamEnded = true;
                engine->mPlaying = false;
            }
        }

        // Feed ring buffer for FFT
        engine->FeedRingBuffer(fOutput, (size_t)(framesRead * ch));

        // Update position based on frames delivered to output
        engine->mFramesPlayed.fetch_add((uint64_t)framesRead);
        int64_t posMs = engine->mSeekBaseMs +
            (int64_t)(engine->mFramesPlayed.load() * 1000ULL / engine->mSampleRate);
        engine->mCurrentPositionMs.store(posMs);

        (void)pInput;
    }

    int Load(const char* file_path) {
        Shutdown();
        if (!EnsureComInitializedForCurrentThread()) return -1;
        if (!EnsureMediaFoundationStarted()) return -2;

        mChannels = 2;
        mSampleRate = 44100;
        mDurationMs = 0;
        mCurrentPositionMs = 0;
        mStreamEnded = false;
        mSeekBaseMs = 0;
        mFramesPlayed = 0;
        mReaderReachedEos = false;
        mDecodedCache.clear();
        mDecodedCacheFrameOffset = 0;

        // Clear ring buffer so FFT doesn't show stale spectrum from
        // the previous track.
        {
            std::lock_guard<std::mutex> rLock(mRingMutex);
            std::fill(mRingBuffer.begin(), mRingBuffer.end(), 0.0f);
            mRingPos = 0;
        }
        mSmoothedBands.clear();

        std::wstring wpath = Utf8ToWide(file_path);
        if (wpath.empty()) return -1;
        ComPtr<IMFSourceReader> reader;
        HRESULT hr = MFCreateSourceReaderFromURL(wpath.c_str(), nullptr, &reader);
        if (FAILED(hr) || !reader) return -3;

        ComPtr<IMFMediaType> targetType;
        hr = MFCreateMediaType(&targetType);
        if (FAILED(hr) || !targetType) return -4;

        hr = targetType->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio);
        if (FAILED(hr)) return -4;
        hr = targetType->SetGUID(MF_MT_SUBTYPE, MFAudioFormat_Float);
        if (FAILED(hr)) return -4;

        hr = reader->SetCurrentMediaType(
            MF_SOURCE_READER_FIRST_AUDIO_STREAM,
            nullptr,
            targetType.Get());
        if (FAILED(hr)) return -5;

        hr = reader->SetStreamSelection(MF_SOURCE_READER_FIRST_AUDIO_STREAM, TRUE);
        if (FAILED(hr)) return -5;

        ComPtr<IMFMediaType> currentType;
        hr = reader->GetCurrentMediaType(MF_SOURCE_READER_FIRST_AUDIO_STREAM, &currentType);
        if (FAILED(hr) || !currentType) return -6;

        mChannels = MFGetAttributeUINT32(currentType.Get(), MF_MT_AUDIO_NUM_CHANNELS, 2);
        mSampleRate = MFGetAttributeUINT32(currentType.Get(), MF_MT_AUDIO_SAMPLES_PER_SECOND, 44100);
        if (mChannels == 0 || mSampleRate == 0) return -6;

        PROPVARIANT varDuration;
        PropVariantInit(&varDuration);
        hr = reader->GetPresentationAttribute(
            MF_SOURCE_READER_MEDIASOURCE,
            MF_PD_DURATION,
            &varDuration);
        if (SUCCEEDED(hr) && varDuration.vt == VT_UI8) {
            // MF duration is in 100ns units.
            mDurationMs = static_cast<uint64_t>(varDuration.uhVal.QuadPart / 10000ULL);
        }
        PropVariantClear(&varDuration);

        mReader = reader;
        mReaderInited = true;

        // Initialize playback device
        ma_device_config deviceConfig = ma_device_config_init(ma_device_type_playback);
        deviceConfig.playback.format   = ma_format_f32;
        deviceConfig.playback.channels = mChannels;
        deviceConfig.sampleRate        = mSampleRate;
        deviceConfig.dataCallback      = DataCallback;
        deviceConfig.pUserData         = this;

        ma_result result = ma_device_init(nullptr, &deviceConfig, &mDevice);
        if (result != MA_SUCCESS) {
            mReader.Reset();
            mReaderInited = false;
            return -7;
        }
        mDeviceInited = true;

        return 0;
    }

    void Play() {
        if (!mDeviceInited) return;

        // If the stream ended naturally, seek back to the beginning.
        if (mStreamEnded.load()) {
            Seek(0);
        }

        mPlaying = true;
        mStreamEnded = false;
        ma_device_start(&mDevice);
    }

    void Pause() {
        if (!mDeviceInited) return;
        mPlaying = false;
        // Device keeps running but callback outputs silence when !mPlaying
    }

    void Seek(int32_t ms) {
        if (!mReaderInited || !mReader) return;
        if (ms < 0) ms = 0;
        if (mDurationMs > 0 && (uint64_t)ms > mDurationMs) ms = (int32_t)mDurationMs;

        {
            std::lock_guard<std::mutex> lock(mDecodeMutex);
            PROPVARIANT varPosition;
            PropVariantInit(&varPosition);
            varPosition.vt = VT_I8;
            varPosition.hVal.QuadPart = static_cast<LONGLONG>(ms) * 10000LL;
            mReader->SetCurrentPosition(GUID_NULL, varPosition);
            PropVariantClear(&varPosition);

            mDecodedCache.clear();
            mDecodedCacheFrameOffset = 0;
            mReaderReachedEos = false;
        }

        mCurrentPositionMs = ms;
        mStreamEnded = false;
        mSeekBaseMs = ms;
        mFramesPlayed = 0;

        // Clear ring buffer so FFT reflects the new seek position.
        {
            std::lock_guard<std::mutex> rLock(mRingMutex);
            std::fill(mRingBuffer.begin(), mRingBuffer.end(), 0.0f);
            mRingPos = 0;
        }
    }

    int64_t GetAccuratePositionMs() {
        return mCurrentPositionMs.load();
    }

    // Push audio to our mono ring buffer for FFT
    void FeedRingBuffer(const float* data, size_t num_samples) {
        std::lock_guard<std::mutex> lock(mRingMutex);
        size_t frames = num_samples / mChannels;
        for (size_t i = 0; i < frames; ++i) {
            float mono = 0;
            for (size_t c = 0; c < mChannels; ++c) {
                mono += data[i * mChannels + c];
            }
            mono /= (float)mChannels;
            mRingBuffer[mRingPos] = mono;
            mRingPos = (mRingPos + 1) % mRingBuffer.size();
        }
    }
};

static std::recursive_mutex g_mav_mutex;
static std::unique_ptr<AudioEngine> g_engine;

#endif // _WIN32

extern "C" {

MAV_EXPORT int32_t mav_create_fft(int32_t fft_size) {
    return 0; // Handled internally
}

MAV_EXPORT void mav_dispose_fft(void) {
    std::lock_guard<std::recursive_mutex> lock(g_mav_mutex);
#ifdef _WIN32
    if (g_engine) {
        g_engine->Shutdown();
        g_engine.reset();
    }
#endif
}

MAV_EXPORT int32_t mav_load_audio_file(const char* file_path) {
    std::lock_guard<std::recursive_mutex> lock(g_mav_mutex);
#ifdef _WIN32
    if (!file_path || file_path[0] == '\0') return -1;
    if (!g_engine) {
        g_engine = std::make_unique<AudioEngine>();
    }
    
    return g_engine->Load(file_path);
#else
    return -999;
#endif
}

MAV_EXPORT int32_t mav_open_audio_for_playback(const char* file_path) {
    // Legacy alias - if engine already loaded for this path, skip re-load.
    std::lock_guard<std::recursive_mutex> lock(g_mav_mutex);
#ifdef _WIN32
    if (g_engine && g_engine->mDeviceInited) {
        return 0; // Already loaded by mav_load_audio_file.
    }
#endif
    // Fallback: actually load.
    return mav_load_audio_file(file_path);
}

MAV_EXPORT int32_t mav_player_play(void) {
    std::lock_guard<std::recursive_mutex> lock(g_mav_mutex);
#ifdef _WIN32
    if (g_engine) {
        g_engine->Play();
        return 0;
    }
    return -1;
#else
    return -1;
#endif
}

MAV_EXPORT int32_t mav_player_pause(void) {
    std::lock_guard<std::recursive_mutex> lock(g_mav_mutex);
#ifdef _WIN32
    if (g_engine) {
        g_engine->Pause();
        return 0;
    }
    return -1;
#else
    return -1;
#endif
}

MAV_EXPORT int32_t mav_player_seek_ms(int32_t position_ms) {
    std::lock_guard<std::recursive_mutex> lock(g_mav_mutex);
#ifdef _WIN32
    if (g_engine) {
        g_engine->Seek(position_ms);
        return 0;
    }
    return -1;
#else
    return -1;
#endif
}

MAV_EXPORT int32_t mav_player_get_position_ms(void) {
    std::lock_guard<std::recursive_mutex> lock(g_mav_mutex);
#ifdef _WIN32
    if (g_engine) {
        return (int32_t)g_engine->GetAccuratePositionMs();
    }
    return 0;
#else
    return 0;
#endif
}

MAV_EXPORT int32_t mav_player_is_playing(void) {
    std::lock_guard<std::recursive_mutex> lock(g_mav_mutex);
#ifdef _WIN32
    if (g_engine) {
        return g_engine->mPlaying.load() ? 1 : 0;
    }
    return 0;
#else
    return 0;
#endif
}

MAV_EXPORT int32_t mav_player_is_stream_ended(void) {
    std::lock_guard<std::recursive_mutex> lock(g_mav_mutex);
#ifdef _WIN32
    if (g_engine) {
        return g_engine->mStreamEnded.load() ? 1 : 0;
    }
    return 0;
#else
    return 0;
#endif
}

MAV_EXPORT int32_t mav_player_set_volume(float volume) {
    std::lock_guard<std::recursive_mutex> lock(g_mav_mutex);
#ifdef _WIN32
    if (g_engine) {
        if (volume < 0.0f) volume = 0.0f;
        if (volume > 2.0f) volume = 2.0f;
        g_engine->mVolume.store(volume);
        return 0;
    }
    return -999;
#else
    return -999;
#endif
}

MAV_EXPORT void mav_unload_audio_file(void) {
    std::lock_guard<std::recursive_mutex> lock(g_mav_mutex);
#ifdef _WIN32
    if (g_engine) {
        g_engine->Shutdown();
        g_engine.reset();
    }
#endif
}

MAV_EXPORT int32_t mav_get_audio_duration_ms(void) {
    std::lock_guard<std::recursive_mutex> lock(g_mav_mutex);
#ifdef _WIN32
    if (g_engine) {
        return (int32_t)g_engine->mDurationMs;
    }
#endif
    return 0;
}

MAV_EXPORT int32_t mav_compute_spectrum_at_ms(int32_t position_ms, float* out_magnitudes, int32_t out_count) {
    std::lock_guard<std::recursive_mutex> lock(g_mav_mutex);
#ifdef _WIN32
    if (!g_engine || !out_magnitudes || out_count <= 0) return -10;
    if (!g_engine->mPffftSetup) return -11;

    float* input = (float*)pffft_aligned_malloc(FFT_SIZE * sizeof(float));
    float* output = (float*)pffft_aligned_malloc(FFT_SIZE * sizeof(float));
    float* work = (float*)pffft_aligned_malloc(FFT_SIZE * sizeof(float));
    if (!input || !output || !work) {
        if (input) pffft_aligned_free(input);
        if (output) pffft_aligned_free(output);
        if (work) pffft_aligned_free(work);
        return -12;
    }

    {
        std::lock_guard<std::mutex> rLock(g_engine->mRingMutex);
        size_t startPos = (g_engine->mRingPos + g_engine->mRingBuffer.size() - FFT_SIZE) % g_engine->mRingBuffer.size();
        for (int i = 0; i < FFT_SIZE; ++i) {
            float w = 0.5f * (1.0f - cosf(2.0f * 3.1415926535f * i / (FFT_SIZE - 1)));
            input[i] = g_engine->mRingBuffer[(startPos + i) % g_engine->mRingBuffer.size()] * w;
        }
    }

    pffft_transform_ordered(g_engine->mPffftSetup, input, output, work, PFFFT_FORWARD);

    int numBins = FFT_SIZE / 2;
    int binsToWrite = (out_count < numBins) ? out_count : numBins;
    for (int i = 0; i < binsToWrite; ++i) {
        float re = output[2 * i];
        float im = output[2 * i + 1];
        // Keep raw magnitudes consistent with fft_utils.cpp. Dart side applies
        // normalization for visualization, so scaling here causes double attenuation.
        out_magnitudes[i] = sqrtf(re * re + im * im);
    }
    for (int i = binsToWrite; i < out_count; ++i) {
        out_magnitudes[i] = 0.0f;
    }

    pffft_aligned_free(input);
    pffft_aligned_free(output);
    pffft_aligned_free(work);
    return binsToWrite;
#else
    return -10;
#endif
}

MAV_EXPORT int32_t mav_compute_compressed_bands_at_ms(int32_t position_ms, float* out_bands, int32_t band_count) {
    std::lock_guard<std::recursive_mutex> lock(g_mav_mutex);
#ifdef _WIN32
    if (!g_engine || !out_bands || band_count <= 0) return -20;
    if (!g_engine->mPffftSetup) return -21;

    size_t vecSize = g_engine->mSmoothedBands.size();
    if (vecSize != static_cast<size_t>(band_count)) {
        g_engine->mSmoothedBands.assign(band_count, 0.0f);
    }
    
    float* input = (float*)pffft_aligned_malloc(FFT_SIZE * sizeof(float));
    float* output = (float*)pffft_aligned_malloc(FFT_SIZE * sizeof(float));
    float* work = (float*)pffft_aligned_malloc(FFT_SIZE * sizeof(float));
    if (!input || !output || !work) {
        if (input) pffft_aligned_free(input);
        if (output) pffft_aligned_free(output);
        if (work) pffft_aligned_free(work);
        return -22;
    }
    
    {
        std::lock_guard<std::mutex> rLock(g_engine->mRingMutex);
        size_t startPos = (g_engine->mRingPos + g_engine->mRingBuffer.size() - FFT_SIZE) % g_engine->mRingBuffer.size();
        for (int i = 0; i < FFT_SIZE; ++i) {
            // Multiply by Hann Window
            float multiplier = 0.5f * (1.0f - cosf(2.0f * 3.1415926535f * i / (FFT_SIZE - 1)));
            input[i] = g_engine->mRingBuffer[(startPos + i) % g_engine->mRingBuffer.size()] * multiplier;
        }
    }
    
    pffft_transform_ordered(g_engine->mPffftSetup, input, output, work, PFFFT_FORWARD);
    
    // Magnitudes (only need first half)
    int numBins = FFT_SIZE / 2;
    std::vector<float> mags(numBins, 0.0f);
    for (int i = 0; i < numBins; ++i) {
        float re = output[2*i];
        float im = output[2*i+1];
        mags[i] = sqrtf(re*re + im*im);
    }
    
    // Compress and smooth into band_count segments
    for (int32_t b = 0; b < band_count; ++b) {
        float t0 = (float)b / (float)band_count;
        float t1 = (float)(b + 1) / (float)band_count;
        int32_t start = (int32_t)(powf((float)numBins, t0));
        int32_t end = (int32_t)(powf((float)numBins, t1));
        
        if (start < 0) start = 0;
        if (end >= numBins) end = numBins - 1;
        if (start > end) start = end;
        
        float max_val = 0.0f;
        for (int32_t i = start; i <= end; ++i) {
            float v = mags[i];
            if (v > max_val) max_val = v;
        }
        
        // Smoothing
        float prev = g_engine->mSmoothedBands[b];
        float cur = max_val * 4.0f; // Amplification
        if (cur < prev) {
            cur = prev * 0.8f + cur * 0.2f;
        } else {
            cur = prev * 0.2f + cur * 0.8f;
        }
        g_engine->mSmoothedBands[b] = cur;
        out_bands[b] = cur;
    }
    
    pffft_aligned_free(input);
    pffft_aligned_free(output);
    pffft_aligned_free(work);

    return band_count;
#else
    return -20;
#endif
}

MAV_EXPORT int32_t mav_get_whole_track_waveform(const char* file_path, float* out_buffer, int32_t out_count, int32_t use_fast_mode) {
    // NOTE: This function creates its own ma_decoder and does not touch
    // g_engine, so we intentionally avoid holding g_mav_mutex for the entire
    // (potentially very long) scan.
#ifdef _WIN32
    if (!file_path || !out_buffer || out_count <= 0) return -1;

    std::wstring wpath = Utf8ToWide(file_path);
    if (wpath.empty()) return -1;

    ma_decoder_config decoderConfig = ma_decoder_config_init(ma_format_f32, 0, 0);
    ma_decoder decoder;
    ma_result result = ma_decoder_init_file_w(wpath.c_str(), &decoderConfig, &decoder);
    if (result != MA_SUCCESS) return -2;

    ma_uint32 num_channels = decoder.outputChannels;
    ma_uint32 sample_rate  = decoder.outputSampleRate;

    ma_uint64 totalFrames = 0;
    if (ma_decoder_get_length_in_pcm_frames(&decoder, &totalFrames) != MA_SUCCESS || totalFrames == 0) {
        ma_decoder_uninit(&decoder);
        return -4;
    }

    memset(out_buffer, 0, out_count * sizeof(float));

    if (use_fast_mode != 0) {
        // Fast mode: seek to evenly-spaced positions and read a small chunk
        ma_uint64 framesPerSlice = totalFrames / out_count;
        if (framesPerSlice == 0) framesPerSlice = 1;
        const int CHUNK_FRAMES = 1024;
        std::vector<float> buf(CHUNK_FRAMES * num_channels);

        for (int32_t i = 0; i < out_count; ++i) {
            ma_uint64 seekFrame = (ma_uint64)i * totalFrames / out_count;
            if (ma_decoder_seek_to_pcm_frame(&decoder, seekFrame) != MA_SUCCESS) continue;

            ma_uint64 framesRead = 0;
            ma_decoder_read_pcm_frames(&decoder, buf.data(), CHUNK_FRAMES, &framesRead);
            if (framesRead == 0) continue;

            float peak = 0.0f;
            for (ma_uint64 k = 0; k < framesRead * num_channels; ++k) {
                float v = fabsf(buf[k]);
                if (v > peak) peak = v;
            }
            out_buffer[i] = peak;
        }
    } else {
        // Full scan mode: read all frames sequentially
        ma_uint64 samples_per_bucket = totalFrames / out_count;
        if (samples_per_bucket == 0) samples_per_bucket = 1;

        const int READ_CHUNK = 4096;
        std::vector<float> buf(READ_CHUNK * num_channels);
        ma_uint64 current_sample = 0;
        int32_t current_bucket = 0;
        float current_peak = 0.0f;

        bool ended = false;
        while (!ended && current_bucket < out_count) {
            ma_uint64 framesRead = 0;
            ma_decoder_read_pcm_frames(&decoder, buf.data(), READ_CHUNK, &framesRead);
            if (framesRead == 0) {
                ended = true;
                break;
            }

            for (ma_uint64 f = 0; f < framesRead; ++f) {
                float max_ch = 0.0f;
                for (ma_uint32 c = 0; c < num_channels; ++c) {
                    float v = fabsf(buf[f * num_channels + c]);
                    if (v > max_ch) max_ch = v;
                }
                if (max_ch > current_peak) current_peak = max_ch;

                current_sample++;
                if (current_sample >= (ma_uint64)(current_bucket + 1) * samples_per_bucket) {
                    if (current_bucket < out_count) {
                        out_buffer[current_bucket] = current_peak;
                        current_bucket++;
                        current_peak = 0.0f;
                    }
                }
            }
        }
        if (current_bucket < out_count && current_peak > 0.0f) {
            out_buffer[current_bucket] = current_peak;
        }
    }

    ma_decoder_uninit(&decoder);

    float max_all = 0.0f;
    for (int32_t i = 0; i < out_count; ++i) {
        if (out_buffer[i] > max_all) max_all = out_buffer[i];
    }
    if (max_all > 0.0f) {
        for (int32_t i = 0; i < out_count; ++i) {
            out_buffer[i] /= max_all;
        }
    }

    return out_count;
#else
    return -999;
#endif
}

MAV_EXPORT int32_t mav_fill_test_signal(float* out_samples, int32_t sample_count, float phase_step) {
    if (!out_samples || sample_count <= 0) return -1;
    float phase = 0.0f;
    for (int32_t i = 0; i < sample_count; ++i) {
        out_samples[i] = sinf(phase);
        phase += phase_step;
    }
    return sample_count;
}

MAV_EXPORT int32_t mav_compute_spectrum(const float* input_samples, int32_t sample_count, float* out_magnitudes, int32_t out_count) {
    if (!input_samples || !out_magnitudes || sample_count <= 0 || out_count <= 0) return -1;

    // Use a temporary pffft setup matching requested size (clamped to FFT_SIZE)
    int fftLen = (sample_count < FFT_SIZE) ? sample_count : FFT_SIZE;
    // pffft requires minimum 32 for PFFFT_REAL
    if (fftLen < 32) fftLen = 32;
    // Round down to power-of-two for pffft
    int po2 = 1;
    while (po2 * 2 <= fftLen) po2 *= 2;
    fftLen = po2;

    PFFFT_Setup* setup = pffft_new_setup(fftLen, PFFFT_REAL);
    if (!setup) return -2;

    float* in = (float*)pffft_aligned_malloc(fftLen * sizeof(float));
    float* out = (float*)pffft_aligned_malloc(fftLen * sizeof(float));
    float* work = (float*)pffft_aligned_malloc(fftLen * sizeof(float));
    if (!in || !out || !work) {
        if (in) pffft_aligned_free(in);
        if (out) pffft_aligned_free(out);
        if (work) pffft_aligned_free(work);
        pffft_destroy_setup(setup);
        return -3;
    }

    for (int i = 0; i < fftLen; ++i) {
        float w = 0.5f * (1.0f - cosf(2.0f * 3.1415926535f * i / (fftLen - 1)));
        in[i] = (i < sample_count) ? input_samples[i] * w : 0.0f;
    }

    pffft_transform_ordered(setup, in, out, work, PFFFT_FORWARD);

    int numBins = fftLen / 2;
    int binsToWrite = (out_count < numBins) ? out_count : numBins;
    for (int i = 0; i < binsToWrite; ++i) {
        float re = out[2 * i];
        float im = out[2 * i + 1];
        out_magnitudes[i] = sqrtf(re * re + im * im);
    }
    for (int i = binsToWrite; i < out_count; ++i) {
        out_magnitudes[i] = 0.0f;
    }

    pffft_aligned_free(in);
    pffft_aligned_free(out);
    pffft_aligned_free(work);
    pffft_destroy_setup(setup);
    return binsToWrite;
}

MAV_EXPORT int32_t mav_simd_width(void) {
    return pffft_simd_size();
}

} // extern "C"
