use rodio::{Decoder, DeviceSinkBuilder, MixerDeviceSink, Player, Source};
use realfft::{num_complex::Complex, RealFftPlanner, RealToComplex};
use std::fs::File;
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Duration;

const FFT_SIZE: usize = 1024;
const RAW_FFT_BINS: usize = FFT_SIZE / 2;

static PLAYER_CONTROLLER: OnceLock<Mutex<PlayerController>> = OnceLock::new();

fn controller() -> &'static Mutex<PlayerController> {
    PLAYER_CONTROLLER.get_or_init(|| Mutex::new(PlayerController::new()))
}

struct PlayerController {
    sink: Option<MixerDeviceSink>,
    player: Option<Player>,
    latest_fft: Arc<Mutex<Vec<f32>>>,
    loaded_path: Option<String>,
    loaded_duration: Duration,
    source_start_offset: Duration,
    volume: f32,
    cached_pcm: Option<Arc<Vec<f32>>>,
    cached_channels: usize,
    cached_sample_rate: u32,
}

impl PlayerController {
    fn new() -> Self {
        Self {
            sink: None,
            player: None,
            latest_fft: Arc::new(Mutex::new(vec![0.0; RAW_FFT_BINS])),
            loaded_path: None,
            loaded_duration: Duration::ZERO,
            source_start_offset: Duration::ZERO,
            volume: 1.0,
            cached_pcm: None,
            cached_channels: 0,
            cached_sample_rate: 0,
        }
    }

    fn ensure_audio_output(&mut self) -> Result<(), String> {
        if self.sink.is_some() && self.player.is_some() {
            return Ok(());
        }

        let sink = DeviceSinkBuilder::open_default_sink()
            .map_err(|e| format!("open default audio device failed: {e}"))?;
        let player = Player::connect_new(&sink.mixer());

        self.sink = Some(sink);
        self.player = Some(player);
        Ok(())
    }

    fn with_player<F, T>(&self, f: F) -> Result<T, String>
    where
        F: FnOnce(&Player) -> T,
    {
        self.player
            .as_ref()
            .map(f)
            .ok_or_else(|| "player is not initialized".to_string())
    }

    fn clear_fft(&self) {
        if let Ok(mut shared) = self.latest_fft.lock() {
            shared.fill(0.0);
        }
    }

    fn append_from_path(
        &mut self,
        path: &str,
        start_offset: Duration,
        auto_play: bool,
    ) -> Result<(), String> {
        self.ensure_audio_output()?;

        let file = File::open(path).map_err(|e| format!("open file failed: {e}"))?;
        let source = Decoder::try_from(file).map_err(|e| format!("decode failed: {e}"))?;

        let total = source.total_duration().unwrap_or(Duration::ZERO);
        let clamped_offset = if total.is_zero() {
            start_offset
        } else {
            start_offset.min(total)
        };

        self.with_player(|player| {
            player.clear();
            player.set_volume(self.volume);
            if clamped_offset > Duration::ZERO {
                player.append(FftSource::new(
                    source.skip_duration(clamped_offset),
                    Arc::clone(&self.latest_fft),
                ));
            } else {
                player.append(FftSource::new(source, Arc::clone(&self.latest_fft)));
            }
            if auto_play {
                player.play();
            } else {
                player.pause();
            }
        })?;

        self.loaded_path = Some(path.to_string());
        self.loaded_duration = total;
        self.source_start_offset = clamped_offset;
        self.clear_fft();

        // Start pre-caching PCM data in a background thread
        let path_clone = path.to_string();
        std::thread::spawn(move || {
            if let Ok(file) = File::open(&path_clone) {
                if let Ok(source) = Decoder::try_from(file) {
                    let channels = source.channels().get() as usize;
                    let sample_rate = source.sample_rate().get();
                    let pcm: Vec<f32> = source.collect();
                    if let Ok(mut c) = controller().lock() {
                        if c.loaded_path.as_deref() == Some(&path_clone) {
                            c.cached_pcm = Some(Arc::new(pcm));
                            c.cached_channels = channels;
                            c.cached_sample_rate = sample_rate;
                        }
                    }
                }
            }
        });

        Ok(())
    }

    fn playback_position(&self) -> Duration {
        let Some(player) = self.player.as_ref() else {
            return Duration::ZERO;
        };

        let mut pos = self.source_start_offset.saturating_add(player.get_pos());
        if !self.loaded_duration.is_zero() {
            pos = pos.min(self.loaded_duration);
        }
        if player.empty() && !self.loaded_duration.is_zero() {
            return self.loaded_duration;
        }
        pos
    }
}

struct FftSource<S>
where
    S: Source<Item = f32>,
{
    inner: S,
    channels: usize,
    frame_accum: f32,
    frame_pos: usize,
    fft: Arc<dyn RealToComplex<f32>>,
    hann_window: Vec<f32>,
    window_sum: f32,
    input_buffer: Vec<f32>,
    output_buffer: Vec<Complex<f32>>,
    index: usize,
    latest_fft: Arc<Mutex<Vec<f32>>>,
}

impl<S> FftSource<S>
where
    S: Source<Item = f32>,
{
    fn new(inner: S, latest_fft: Arc<Mutex<Vec<f32>>>) -> Self {
        let mut planner = RealFftPlanner::<f32>::new();
        let fft = planner.plan_fft_forward(FFT_SIZE);
        let channels = usize::from(inner.channels().get().max(1));

        let mut hann_window = Vec::with_capacity(FFT_SIZE);
        for i in 0..FFT_SIZE {
            let phase = (2.0_f32 * std::f32::consts::PI * i as f32) / (FFT_SIZE as f32 - 1.0);
            hann_window.push(0.5 - 0.5 * phase.cos());
        }
        let window_sum = hann_window.iter().sum::<f32>().max(1e-9);

        Self {
            inner,
            channels,
            frame_accum: 0.0,
            frame_pos: 0,
            input_buffer: fft.make_input_vec(),
            output_buffer: fft.make_output_vec(),
            fft,
            hann_window,
            window_sum,
            index: 0,
            latest_fft,
        }
    }

    fn push_mono_sample(&mut self, sample: f32) {
        self.input_buffer[self.index] = sample;
        self.index += 1;

        if self.index == FFT_SIZE {
            self.compute_fft();
            self.index = 0;
        }
    }

    fn compute_fft(&mut self) {
        for (s, w) in self.input_buffer.iter_mut().zip(self.hann_window.iter()) {
            *s *= *w;
        }

        if self
            .fft
            .process(&mut self.input_buffer, &mut self.output_buffer)
            .is_err()
        {
            return;
        }

        let magnitudes: Vec<f32> = self
            .output_buffer
            .iter()
            .take(RAW_FFT_BINS)
            .enumerate()
            .map(|(i, c)| {
                let mag = (c.re * c.re + c.im * c.im).sqrt();
                let one_sided_scale = if i == 0 { 1.0 } else { 2.0 };
                (mag * one_sided_scale) / self.window_sum
            })
            .collect();

        if let Ok(mut shared) = self.latest_fft.lock() {
            *shared = magnitudes;
        }
    }
}

impl<S> Iterator for FftSource<S>
where
    S: Source<Item = f32>,
{
    type Item = f32;

    fn next(&mut self) -> Option<Self::Item> {
        let sample = self.inner.next()?;

        if self.channels <= 1 {
            self.push_mono_sample(sample);
        } else {
            self.frame_accum += sample;
            self.frame_pos += 1;
            if self.frame_pos == self.channels {
                let mono = self.frame_accum / self.channels as f32;
                self.frame_accum = 0.0;
                self.frame_pos = 0;
                self.push_mono_sample(mono);
            }
        }

        Some(sample)
    }
}

impl<S> Source for FftSource<S>
where
    S: Source<Item = f32>,
{
    fn current_span_len(&self) -> Option<usize> {
        self.inner.current_span_len()
    }

    fn channels(&self) -> rodio::ChannelCount {
        self.inner.channels()
    }

    fn sample_rate(&self) -> rodio::SampleRate {
        self.inner.sample_rate()
    }

    fn total_duration(&self) -> Option<Duration> {
        self.inner.total_duration()
    }

    fn try_seek(&mut self, pos: Duration) -> Result<(), rodio::source::SeekError> {
        self.index = 0;
        self.frame_accum = 0.0;
        self.frame_pos = 0;
        self.input_buffer.fill(0.0);
        self.output_buffer
            .fill(Complex { re: 0.0, im: 0.0 });
        self.inner.try_seek(pos)
    }
}

#[flutter_rust_bridge::frb(sync)] // Synchronous mode for simplicity of the demo
pub fn greet(name: String) -> String {
    format!("Hello, {name}!")
}

#[flutter_rust_bridge::frb(init)]
pub fn init_app() {
    flutter_rust_bridge::setup_default_user_utils();

    if let Ok(mut c) = controller().lock() {
        let _ = c.ensure_audio_output();
    }
}

pub fn load_audio_file(path: String) -> Result<(), String> {
    let mut c = controller()
        .lock()
        .map_err(|_| "player lock poisoned".to_string())?;
    c.append_from_path(&path, Duration::ZERO, false)
}

pub fn play_audio() -> Result<(), String> {
    let c = controller()
        .lock()
        .map_err(|_| "player lock poisoned".to_string())?;
    c.with_player(|player| {
        player.play();
    })?;
    Ok(())
}

pub fn pause_audio() -> Result<(), String> {
    let c = controller()
        .lock()
        .map_err(|_| "player lock poisoned".to_string())?;
    c.with_player(|player| {
        player.pause();
    })?;
    Ok(())
}

pub fn toggle_audio() -> Result<bool, String> {
    let c = controller()
        .lock()
        .map_err(|_| "player lock poisoned".to_string())?;
    c.with_player(|player| {
        if player.is_paused() {
            player.play();
            true
        } else {
            player.pause();
            false
        }
    })
}

pub fn seek_audio_ms(position_ms: i64) -> Result<(), String> {
    let mut c = controller()
        .lock()
        .map_err(|_| "player lock poisoned".to_string())?;

    let target_ms = position_ms.max(0) as u64;
    let mut target = Duration::from_millis(target_ms);
    if !c.loaded_duration.is_zero() {
        target = target.min(c.loaded_duration);
    }

    if c.loaded_path.is_none() {
        return Err("audio is not loaded".to_string());
    }

    // Fast path: seek the currently loaded source in-place.
    let seek_result = c.with_player(|player| player.try_seek(target))?;
    if seek_result.is_ok() {
        c.source_start_offset = Duration::ZERO;
        c.clear_fft();
        return Ok(());
    }

    // Fallback for non-seekable decoders/sources: rebuild source at target offset.
    let path = c
        .loaded_path
        .clone()
        .ok_or_else(|| "audio is not loaded".to_string())?;

    let was_playing = c.with_player(|player| !player.is_paused() && !player.empty())?;
    c.append_from_path(&path, target, was_playing)
}

pub fn set_audio_volume(volume: f32) -> Result<(), String> {
    let mut c = controller()
        .lock()
        .map_err(|_| "player lock poisoned".to_string())?;

    let clamped = volume.clamp(0.0, 1.0);
    c.volume = clamped;
    c.with_player(|player| {
        player.set_volume(clamped);
    })?;
    Ok(())
}

pub fn dispose_audio() -> Result<(), String> {
    let mut c = controller()
        .lock()
        .map_err(|_| "player lock poisoned".to_string())?;

    if let Some(player) = c.player.as_ref() {
        player.clear();
        player.pause();
    }
    c.loaded_path = None;
    c.loaded_duration = Duration::ZERO;
    c.source_start_offset = Duration::ZERO;
    c.cached_pcm = None;
    c.cached_channels = 0;
    c.cached_sample_rate = 0;
    c.clear_fft();
    Ok(())
}

#[flutter_rust_bridge::frb(sync)]
pub fn is_audio_playing() -> bool {
    if let Ok(c) = controller().lock() {
        if let Some(player) = c.player.as_ref() {
            return !player.is_paused() && !player.empty();
        }
    }
    false
}

#[flutter_rust_bridge::frb(sync)]
pub fn get_audio_duration_ms() -> i64 {
    if let Ok(c) = controller().lock() {
        return c.loaded_duration.as_millis().min(i64::MAX as u128) as i64;
    }
    0
}

#[flutter_rust_bridge::frb(sync)]
pub fn get_audio_position_ms() -> i64 {
    if let Ok(c) = controller().lock() {
        return c.playback_position().as_millis().min(i64::MAX as u128) as i64;
    }
    0
}

#[flutter_rust_bridge::frb(sync)]
pub fn get_latest_fft() -> Vec<f32> {
    if let Ok(c) = controller().lock() {
        if let Ok(fft) = c.latest_fft.lock() {
            return fft.clone();
        }
    }
    vec![0.0; RAW_FFT_BINS]
}

#[flutter_rust_bridge::frb(sync)]
pub fn get_loaded_audio_path() -> Option<String> {
    if let Ok(c) = controller().lock() {
        return c.loaded_path.clone();
    }
    None
}

use crate::frb_generated::StreamSink;

#[derive(Debug, Clone)]
pub struct WaveformChunk {
    pub index: usize,
    pub peak: f32, // absolute max peak
}

fn read_frame_abs_max<I>(source: &mut I, channels: usize) -> Option<f32>
where
    I: Iterator<Item = f32>,
{
    let mut found_any = false;
    let mut frame_max = 0.0f32;

    for _ in 0..channels {
        if let Some(sample) = source.next() {
            let abs_sample = sample.abs();
            if abs_sample > frame_max {
                frame_max = abs_sample;
            }
            found_any = true;
        }
    }

    if found_any {
        Some(frame_max)
    } else {
        None
    }
}

#[flutter_rust_bridge::frb(sync)]
pub fn extract_waveform_streaming(
    expected_chunks: usize,
    sample_stride: usize,
    sink: StreamSink<WaveformChunk>,
) -> Result<(), String> {
    if expected_chunks == 0 {
        return Err("expected_chunks must be > 0".to_string());
    }

    let path = {
        if let Ok(c) = controller().lock() {
            c.loaded_path.clone()
        } else {
            None
        }
    }
    .ok_or_else(|| "No loaded audio file to extract waveform from".to_string())?;

    let sample_stride = sample_stride.max(1);

    std::thread::spawn(move || {
        let decode_core = || -> Result<(), String> {
            let file = File::open(&path).map_err(|e| format!("open file failed: {} - {}", path, e))?;
            let mut source = Decoder::try_from(file).map_err(|e| format!("decode failed: {}", e))?;

            let total_duration = source
                .total_duration()
                .ok_or_else(|| "Unknown duration".to_string())?;
            let channels = source.channels().get() as usize;
            let sample_rate = source.sample_rate().get() as f64;

            let total_samples = (total_duration.as_secs_f64() * sample_rate) as usize;
            if total_samples == 0 {
                for i in 0..expected_chunks {
                    let _ = sink.add(WaveformChunk {
                        index: i,
                        peak: 0.0,
                    });
                }
                return Ok(());
            }

            let samples_per_chunk = total_samples / expected_chunks;
            let skip_duration_per_stride = if sample_stride > 1 {
                Some(Duration::from_secs_f64(
                    (sample_stride - 1) as f64 / sample_rate,
                ))
            } else {
                None
            };

            for chunk_index in 0..expected_chunks {
                let mut current_chunk_max = 0.0f32;
                let mut samples_read = 0;

                while samples_read < samples_per_chunk {
                    let Some(frame_peak) = read_frame_abs_max(&mut source, channels) else {
                        break;
                    };
                    if frame_peak > current_chunk_max {
                        current_chunk_max = frame_peak;
                    }
                    samples_read += 1;

                    if let Some(skip_dur) = skip_duration_per_stride {
                        if samples_read < samples_per_chunk {
                            let available_in_chunk = samples_per_chunk - samples_read;
                            let to_skip_in_stride = sample_stride - 1;

                            if available_in_chunk < to_skip_in_stride {
                                let remaining_skip = Duration::from_secs_f64(
                                    available_in_chunk as f64 / sample_rate,
                                );
                                source = source.skip_duration(remaining_skip).into_inner();
                                samples_read += available_in_chunk;
                            } else {
                                source = source.skip_duration(skip_dur).into_inner();
                                samples_read += to_skip_in_stride;
                            }
                        }
                    }
                }

                let _ = sink.add(WaveformChunk {
                    index: chunk_index,
                    peak: current_chunk_max.min(1.0),
                });
            }

            Ok(())
        };

        if let Err(e) = decode_core() {
            println!("extract_waveform_streaming error: {:?}", e);
        }
    });

    Ok(())
}


pub fn extract_loaded_waveform(
    expected_chunks: usize,
    sample_stride: usize,
) -> Result<Vec<f32>, String> {
    if expected_chunks == 0 {
        return Err("expected_chunks must be > 0".to_string());
    }

    let sample_stride = sample_stride.max(1);

    // Try to use cached PCM data if available
    let (pcm, channels, _sample_rate, path) = {
        let c = controller()
            .lock()
            .map_err(|_| "player lock poisoned".to_string())?;
        (
            c.cached_pcm.clone(),
            c.cached_channels,
            c.cached_sample_rate,
            c.loaded_path.clone(),
        )
    };

    if let Some(pcm) = pcm {
        let total_frames = pcm.len() / channels;
        if total_frames == 0 {
            return Ok(vec![0.0; expected_chunks]);
        }

        let frames_per_chunk = total_frames / expected_chunks;
        let mut result = Vec::with_capacity(expected_chunks);

        for chunk_index in 0..expected_chunks {
            let start_frame = chunk_index * frames_per_chunk;
            let end_frame = if chunk_index == expected_chunks - 1 {
                total_frames
            } else {
                (chunk_index + 1) * frames_per_chunk
            };

            let mut current_chunk_max = 0.0f32;
            let mut frame_idx = start_frame;
            while frame_idx < end_frame {
                let sample_idx = frame_idx * channels;
                if sample_idx < pcm.len() {
                    for ch in 0..channels {
                        let s_idx = sample_idx + ch;
                        if s_idx < pcm.len() {
                            let abs_sample = pcm[s_idx].abs();
                            if abs_sample > current_chunk_max {
                                current_chunk_max = abs_sample;
                            }
                        }
                    }
                }
                frame_idx += sample_stride;
            }
            result.push(current_chunk_max.min(1.0));
        }
        return Ok(result);
    }

    // Fallback if not cached
    let path = path.ok_or_else(|| "No loaded audio file to extract waveform from".to_string())?;
    let file = File::open(&path).map_err(|e| format!("open file failed: {} - {}", path, e))?;
    let mut source = Decoder::try_from(file).map_err(|e| format!("decode failed: {}", e))?;

    let total_duration = source
        .total_duration()
        .ok_or_else(|| "Unknown duration".to_string())?;
    let channels = source.channels().get() as usize;
    let sample_rate = source.sample_rate().get() as f64;

    // Calculate total number of samples (per channel)
    let total_samples = (total_duration.as_secs_f64() * sample_rate) as usize;
    if total_samples == 0 {
        return Ok(vec![0.0; expected_chunks]);
    }

    // Each chunk will cover this many samples (per channel)
    let samples_per_chunk = total_samples / expected_chunks;
    let skip_duration_per_stride = if sample_stride > 1 {
        Some(Duration::from_secs_f64(
            (sample_stride - 1) as f64 / (sample_rate as f64),
        ))
    } else {
        None
    };

    let mut result = Vec::with_capacity(expected_chunks);

    // Iterate linearly and evaluate one frame every `sample_stride` frames.
    for _ in 0..expected_chunks {
        let mut current_chunk_max = 0.0f32;
        let mut samples_read = 0;

        // Read frames belonging to this chunk.
        while samples_read < samples_per_chunk {
            let Some(frame_peak) = read_frame_abs_max(&mut source, channels) else {
                break;
            };
            if frame_peak > current_chunk_max {
                current_chunk_max = frame_peak;
            }
            samples_read += 1;

            if let Some(skip_dur) = skip_duration_per_stride {
                if samples_read < samples_per_chunk {
                    let available_in_chunk = samples_per_chunk - samples_read;
                    let to_skip_in_stride = sample_stride - 1;

                    if available_in_chunk < to_skip_in_stride {
                        let remaining_skip =
                            Duration::from_secs_f64(available_in_chunk as f64 / (sample_rate as f64));
                        source = source.skip_duration(remaining_skip).into_inner();
                        samples_read += available_in_chunk;
                    } else {
                        source = source.skip_duration(skip_dur).into_inner();
                        samples_read += to_skip_in_stride;
                    }
                }
            }
        }

        result.push(current_chunk_max.min(1.0));
    }

    Ok(result)
}
