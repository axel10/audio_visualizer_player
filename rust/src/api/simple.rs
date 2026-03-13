use rodio::{Decoder, DeviceSinkBuilder, MixerDeviceSink, Player, Source};
use rustfft::{num_complex::Complex, Fft, FftPlanner};
use std::fs::File;
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Duration;

const FFT_SIZE: usize = 1024;
const FFT_BINS: usize = 96;

static PLAYER_CONTROLLER: OnceLock<Mutex<PlayerController>> = OnceLock::new();

fn controller() -> &'static Mutex<PlayerController> {
    PLAYER_CONTROLLER.get_or_init(|| Mutex::new(PlayerController::new()))
}

struct PlayerController {
    sink: Option<MixerDeviceSink>,
    player: Option<Player>,
    latest_fft: Arc<Mutex<Vec<f32>>>,
    loaded_path: Option<String>,
}

impl PlayerController {
    fn new() -> Self {
        Self {
            sink: None,
            player: None,
            latest_fft: Arc::new(Mutex::new(vec![0.0; FFT_BINS])),
            loaded_path: None,
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
}

struct FftSource<S>
where
    S: Source<Item = f32>,
{
    inner: S,
    fft: Arc<dyn Fft<f32>>,
    buffer: Vec<Complex<f32>>,
    index: usize,
    latest_fft: Arc<Mutex<Vec<f32>>>,
}

impl<S> FftSource<S>
where
    S: Source<Item = f32>,
{
    fn new(inner: S, latest_fft: Arc<Mutex<Vec<f32>>>) -> Self {
        let mut planner = FftPlanner::<f32>::new();
        let fft = planner.plan_fft_forward(FFT_SIZE);

        Self {
            inner,
            fft,
            buffer: vec![Complex { re: 0.0, im: 0.0 }; FFT_SIZE],
            index: 0,
            latest_fft,
        }
    }

    fn compute_fft(&mut self) {
        self.fft.process(&mut self.buffer);

        let magnitudes: Vec<f32> = self
            .buffer
            .iter()
            .take(FFT_SIZE / 2)
            .map(|c| (c.re * c.re + c.im * c.im).sqrt())
            .collect();

        let chunk_size = (magnitudes.len() / FFT_BINS).max(1);
        let mut bins = Vec::with_capacity(FFT_BINS);

        for chunk in magnitudes.chunks(chunk_size).take(FFT_BINS) {
            let max_v = chunk
                .iter()
                .copied()
                .fold(0.0_f32, |acc, x| if x > acc { x } else { acc });
            bins.push((1.0 + max_v).ln());
        }

        if bins.len() < FFT_BINS {
            bins.resize(FFT_BINS, 0.0);
        }

        if let Ok(mut shared) = self.latest_fft.lock() {
            *shared = bins;
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

        self.buffer[self.index].re = sample;
        self.buffer[self.index].im = 0.0;
        self.index += 1;

        if self.index == FFT_SIZE {
            self.compute_fft();
            self.index = 0;
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
    c.ensure_audio_output()?;

    let file = File::open(&path).map_err(|e| format!("open file failed: {e}"))?;
    let source = Decoder::try_from(file).map_err(|e| format!("decode failed: {e}"))?;
    let fft_source = FftSource::new(source, Arc::clone(&c.latest_fft));

    c.with_player(|player| {
        player.clear();
        player.append(fft_source);
        player.play();
    })?;

    c.loaded_path = Some(path);
    Ok(())
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
pub fn get_latest_fft() -> Vec<f32> {
    if let Ok(c) = controller().lock() {
        if let Ok(fft) = c.latest_fft.lock() {
            return fft.clone();
        }
    }
    vec![0.0; FFT_BINS]
}

#[flutter_rust_bridge::frb(sync)]
pub fn get_loaded_audio_path() -> Option<String> {
    if let Ok(c) = controller().lock() {
        return c.loaded_path.clone();
    }
    None
}
