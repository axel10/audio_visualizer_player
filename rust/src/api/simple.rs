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

    let stride = sample_stride.max(1);

    std::thread::spawn(move || {
        let decode_core = || -> Result<(), String> {
            let file = File::open(&path).map_err(|e| format!("open file failed: {} - {}", path, e))?;
            let source = Decoder::try_from(file).map_err(|e| format!("decode failed: {}", e))?;

            let total_samples = match source.total_duration() {
                Some(dur) => {
                    let sample_rate: u32 = source.sample_rate().into();
                    let channels: u16 = source.channels().into();
                    (dur.as_millis() as u64 * sample_rate as u64 / 1000 * channels as u64) as usize
                }
                None => {
                    // Fallback: guess 3 minutes worth of samples
                    let sample_rate: u32 = source.sample_rate().into();
                    let channels: u16 = source.channels().into();
                    3 * 60 * sample_rate as usize * channels as usize
                }
            };

            let samples_per_chunk = (total_samples / expected_chunks).max(1);

            let mut current_chunk_max = 0.0f32;
            let mut samples_in_chunk = 0usize;
            let mut chunk_index = 0usize;
            let mut stride_counter = 0usize;

            for sample in source {
                if stride_counter == 0 {
                    // sample is f32 in rodio > 0.18
                    let abs_sample = sample.abs();
                    if abs_sample > current_chunk_max {
                        current_chunk_max = abs_sample;
                    }
                }
                stride_counter += 1;
                if stride_counter >= stride {
                    stride_counter = 0;
                }
                samples_in_chunk += 1;

                if samples_in_chunk >= samples_per_chunk {
                    let _ = sink.add(WaveformChunk {
                        index: chunk_index,
                        peak: current_chunk_max.min(1.0),
                    });

                    chunk_index += 1;
                    samples_in_chunk = 0;
                    current_chunk_max = 0.0;
                }
            }

            // Remainder 
            if samples_in_chunk > 0 {
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

    let path = {
        if let Ok(c) = controller().lock() {
            c.loaded_path.clone()
        } else {
            None
        }
    }.ok_or_else(|| "No loaded audio file to extract waveform from".to_string())?;

    let file = File::open(&path).map_err(|e| format!("open file failed: {} - {}", path, e))?;
    let source = Decoder::try_from(file).map_err(|e| format!("decode failed: {}", e))?;

    let total_samples = match source.total_duration() {
        Some(dur) => {
            let sample_rate: u32 = source.sample_rate().into();
            let channels: u16 = source.channels().into();
            (dur.as_millis() as u64 * sample_rate as u64 / 1000 * channels as u64) as usize
        }
        None => {
            let sample_rate: u32 = source.sample_rate().into();
            let channels: u16 = source.channels().into();
            3 * 60 * sample_rate as usize * channels as usize
        }
    };

    let samples_per_chunk = (total_samples / expected_chunks).max(1);
    let stride = sample_stride.max(1);

    let mut result = Vec::with_capacity(expected_chunks);
    let mut current_chunk_max = 0.0f32;
    let mut samples_in_chunk = 0usize;
    let mut stride_counter = 0usize;

    for sample in source {
        if stride_counter == 0 {
            let abs_sample = sample.abs();
            if abs_sample > current_chunk_max {
                current_chunk_max = abs_sample;
            }
        }
        stride_counter += 1;
        if stride_counter >= stride {
            stride_counter = 0;
        }
        samples_in_chunk += 1;

        if samples_in_chunk >= samples_per_chunk {
            result.push(current_chunk_max.min(1.0));
            samples_in_chunk = 0;
            current_chunk_max = 0.0;
        }
    }

    if samples_in_chunk > 0 {
        result.push(current_chunk_max.min(1.0));
    }

    Ok(result)
}
