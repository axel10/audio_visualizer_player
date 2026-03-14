use rodio::{Decoder, DeviceSinkBuilder, MixerDeviceSink, Player, Source};
use realfft::{num_complex::Complex, RealFftPlanner, RealToComplex};
use std::fs::File;
use std::path::Path;
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Duration;
use symphonia::core::audio::SampleBuffer;
use symphonia::core::codecs::{DecoderOptions, CODEC_TYPE_NULL};
use symphonia::core::errors::Error as SymphoniaError;
use symphonia::core::formats::FormatOptions;
use symphonia::core::io::MediaSourceStream;
use symphonia::core::meta::MetadataOptions;
use symphonia::core::probe::Hint;

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
        // Invalidate stale waveform cache immediately so extraction cannot
        // return a previous track while the new cache is still warming up.
        self.cached_pcm = None;
        self.cached_channels = 0;
        self.cached_sample_rate = 0;
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

#[derive(Debug, Clone)]
pub struct WaveformChunk {
    pub index: usize,
    pub peak: f32, // absolute max peak
}

fn fold_packet_peaks_to_chunks(
    packet_peaks: &[(u64, f32)],
    expected_chunks: usize,
    total_ts: Option<u64>,
) -> Vec<f32> {
    let mut waveform = vec![0.0f32; expected_chunks];
    if packet_peaks.is_empty() {
        return waveform;
    }

    if let Some(ts_end) = total_ts.filter(|v| *v > 0) {
        for (packet_end_ts, peak) in packet_peaks {
            let ts = packet_end_ts.saturating_sub(1);
            let idx = ((ts as u128 * expected_chunks as u128) / ts_end as u128) as usize;
            let chunk = idx.min(expected_chunks.saturating_sub(1));
            if *peak > waveform[chunk] {
                waveform[chunk] = *peak;
            }
        }
        return waveform;
    }

    let packet_count = packet_peaks.len().max(1);
    for (i, (_, peak)) in packet_peaks.iter().enumerate() {
        let idx = (i * expected_chunks) / packet_count;
        let chunk = idx.min(expected_chunks.saturating_sub(1));
        if *peak > waveform[chunk] {
            waveform[chunk] = *peak;
        }
    }
    waveform
}

pub fn extract_loaded_waveform(
    expected_chunks: usize,
    sample_stride: usize,
) -> Result<Vec<f32>, String> {
    if expected_chunks == 0 {
        return Err("expected_chunks must be > 0".to_string());
    }

    let sample_stride = sample_stride.max(1);

    // Snapshot the currently loaded file path.
    let path = {
        let c = controller()
            .lock()
            .map_err(|_| "player lock poisoned".to_string())?;
        c
            .loaded_path
            .clone()
            .ok_or_else(|| "No loaded audio file to extract waveform from".to_string())?
    };

    // Stream decode with Symphonia and aggregate per-packet peaks.
    let file = File::open(&path).map_err(|e| format!("open file failed: {} - {}", path, e))?;
    let mut hint = Hint::new();
    if let Some(ext) = Path::new(&path).extension().and_then(|e| e.to_str()) {
        hint.with_extension(ext);
    }

    let mss = MediaSourceStream::new(Box::new(file), Default::default());
    let mut format = symphonia::default::get_probe()
        .format(
            &hint,
            mss,
            &FormatOptions::default(),
            &MetadataOptions::default(),
        )
        .map_err(|e| format!("probe format failed: {}", e))?
        .format;

    let track = format
        .tracks()
        .iter()
        .find(|t| t.codec_params.codec != CODEC_TYPE_NULL)
        .or_else(|| format.default_track())
        .ok_or_else(|| "No audio track found in loaded file".to_string())?;

    let track_id = track.id;
    let total_ts = track.codec_params.n_frames.filter(|v| *v > 0);
    let mut decoder = symphonia::default::get_codecs()
        .make(&track.codec_params, &DecoderOptions::default())
        .map_err(|e| format!("create decoder failed: {}", e))?;

    let mut sample_buf: Option<SampleBuffer<f32>> = None;
    let mut packet_peaks: Vec<(u64, f32)> = Vec::new();
    let mut packet_index = 0usize;
    let mut max_packet_end_ts = 0u64;

    loop {
        let packet = match format.next_packet() {
            Ok(packet) => packet,
            Err(SymphoniaError::IoError(_)) => break,
            Err(SymphoniaError::ResetRequired) => {
                return Err("stream reset required during waveform decode".to_string());
            }
            Err(err) => return Err(format!("read packet failed: {}", err)),
        };

        if packet.track_id() != track_id {
            continue;
        }

        let process_this_packet = packet_index % sample_stride == 0;
        packet_index = packet_index.saturating_add(1);
        if !process_this_packet {
            continue;
        }

        let packet_end_ts = packet.ts().saturating_add(packet.dur().max(1));
        if packet_end_ts > max_packet_end_ts {
            max_packet_end_ts = packet_end_ts;
        }

        let decoded = match decoder.decode(&packet) {
            Ok(decoded) => decoded,
            Err(SymphoniaError::DecodeError(_)) => continue,
            Err(SymphoniaError::IoError(_)) => continue,
            Err(err) => return Err(format!("decode packet failed: {}", err)),
        };

        if sample_buf.is_none() {
            sample_buf = Some(SampleBuffer::<f32>::new(
                decoded.capacity() as u64,
                *decoded.spec(),
            ));
        }

        if let Some(buf) = sample_buf.as_mut() {
            buf.copy_interleaved_ref(decoded);
            let mut peak = 0.0f32;
            for sample in buf.samples() {
                let abs_sample = sample.abs();
                if abs_sample > peak {
                    peak = abs_sample;
                }
            }
            packet_peaks.push((packet_end_ts, peak.min(1.0)));
        }
    }

    {
        // Ensure the decoded result still matches the active loaded file.
        let c = controller()
            .lock()
            .map_err(|_| "player lock poisoned".to_string())?;
        if c.loaded_path.as_deref() != Some(path.as_str()) {
            return Err("loaded audio changed during waveform extraction, please retry".to_string());
        }
    }

    let effective_total_ts = total_ts.or(Some(max_packet_end_ts.max(1)));
    Ok(fold_packet_peaks_to_chunks(
        &packet_peaks,
        expected_chunks,
        effective_total_ts,
    ))
}
