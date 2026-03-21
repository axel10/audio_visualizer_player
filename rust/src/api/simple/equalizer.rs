use rodio::Source;
use std::f32::consts::PI;
use std::sync::{
    atomic::{AtomicU64, Ordering},
    Arc, Mutex,
};
use std::time::Duration;

pub const MAX_EQ_BANDS: usize = 20;
const MIN_EQ_CENTER_HZ: f32 = 32.0;
const MAX_EQ_CENTER_HZ: f32 = 16_000.0;
const DEFAULT_BASS_BOOST_HZ: f32 = 80.0;
const DEFAULT_BASS_BOOST_Q: f32 = 0.75;
const CONFIG_REFRESH_STRIDE: usize = 64;
const EPSILON_GAIN_DB: f32 = 0.001;
const SOFT_LIMIT_THRESHOLD: f32 = 0.95;
const SOFT_LIMIT_KNEE_WIDTH: f32 = 0.05;

#[derive(Debug, Clone)]
pub struct EqualizerConfig {
    pub enabled: bool,
    pub band_count: i32,
    pub preamp_db: f32,
    pub bass_boost_db: f32,
    pub bass_boost_frequency_hz: f32,
    pub bass_boost_q: f32,
    pub band_gains_db: Vec<f32>,
}

impl Default for EqualizerConfig {
    fn default() -> Self {
        Self {
            enabled: false,
            band_count: MAX_EQ_BANDS as i32,
            preamp_db: 0.0,
            bass_boost_db: 0.0,
            bass_boost_frequency_hz: DEFAULT_BASS_BOOST_HZ,
            bass_boost_q: DEFAULT_BASS_BOOST_Q,
            band_gains_db: vec![0.0; MAX_EQ_BANDS],
        }
    }
}

impl EqualizerConfig {
    pub fn sanitized(mut self) -> Self {
        self.band_count = self.band_count.clamp(0, MAX_EQ_BANDS as i32);
        self.bass_boost_frequency_hz = self.bass_boost_frequency_hz.clamp(20.0, 240.0);
        self.bass_boost_q = self.bass_boost_q.clamp(0.1, 2.0);

        if self.band_gains_db.len() < MAX_EQ_BANDS {
            self.band_gains_db.resize(MAX_EQ_BANDS, 0.0);
        } else if self.band_gains_db.len() > MAX_EQ_BANDS {
            self.band_gains_db.truncate(MAX_EQ_BANDS);
        }

        self
    }
}

pub(crate) struct EqualizerShared {
    version: AtomicU64,
    config: Mutex<EqualizerConfig>,
}

impl EqualizerShared {
    pub(crate) fn new(config: EqualizerConfig) -> Arc<Self> {
        Arc::new(Self {
            version: AtomicU64::new(1),
            config: Mutex::new(config.sanitized()),
        })
    }

    pub(crate) fn current_config(&self) -> EqualizerConfig {
        self.config
            .lock()
            .map(|config| config.clone())
            .unwrap_or_else(|_| EqualizerConfig::default())
    }

    pub(crate) fn set_config(&self, config: EqualizerConfig) {
        if let Ok(mut current) = self.config.lock() {
            *current = config.sanitized();
            self.version.fetch_add(1, Ordering::AcqRel);
        }
    }

    pub(crate) fn version(&self) -> u64 {
        self.version.load(Ordering::Acquire)
    }
}

#[derive(Clone)]
struct BiquadCoefficients {
    b0: f32,
    b1: f32,
    b2: f32,
    a1: f32,
    a2: f32,
}

impl BiquadCoefficients {
    fn identity() -> Self {
        Self {
            b0: 1.0,
            b1: 0.0,
            b2: 0.0,
            a1: 0.0,
            a2: 0.0,
        }
    }

    fn peaking(sample_rate: u32, freq_hz: f32, q: f32, gain_db: f32) -> Self {
        if gain_db.abs() <= EPSILON_GAIN_DB || freq_hz <= 0.0 || sample_rate == 0 {
            return Self::identity();
        }

        let q = q.max(0.1);
        let a = 10.0_f32.powf(gain_db / 40.0);
        let w0 = 2.0 * PI * freq_hz / sample_rate as f32;
        let cos_w0 = w0.cos();
        let sin_w0 = w0.sin();
        let alpha = sin_w0 / (2.0 * q);
        let a0 = 1.0 + alpha / a;

        Self {
            b0: (1.0 + alpha * a) / a0,
            b1: (-2.0 * cos_w0) / a0,
            b2: (1.0 - alpha * a) / a0,
            a1: (-2.0 * cos_w0) / a0,
            a2: (1.0 - alpha / a) / a0,
        }
    }

    fn low_shelf(sample_rate: u32, freq_hz: f32, q: f32, gain_db: f32) -> Self {
        if gain_db.abs() <= EPSILON_GAIN_DB || freq_hz <= 0.0 || sample_rate == 0 {
            return Self::identity();
        }

        let slope = q.max(0.1);
        let a = 10.0_f32.powf(gain_db / 40.0);
        let w0 = 2.0 * PI * freq_hz / sample_rate as f32;
        let cos_w0 = w0.cos();
        let sin_w0 = w0.sin();
        let sqrt_a = a.sqrt();
        let alpha = sin_w0 / 2.0 * (((a + 1.0 / a) * (1.0 / slope - 1.0) + 2.0).max(0.0)).sqrt();
        let two_sqrt_a_alpha = 2.0 * sqrt_a * alpha;
        let a0 = (a + 1.0) + (a - 1.0) * cos_w0 + two_sqrt_a_alpha;

        Self {
            b0: (a * ((a + 1.0) - (a - 1.0) * cos_w0 + two_sqrt_a_alpha)) / a0,
            b1: (2.0 * a * ((a - 1.0) - (a + 1.0) * cos_w0)) / a0,
            b2: (a * ((a + 1.0) - (a - 1.0) * cos_w0 - two_sqrt_a_alpha)) / a0,
            a1: (-2.0 * ((a - 1.0) + (a + 1.0) * cos_w0)) / a0,
            a2: ((a + 1.0) + (a - 1.0) * cos_w0 - two_sqrt_a_alpha) / a0,
        }
    }

    fn magnitude_at(&self, freq_hz: f32, sample_rate: u32) -> f32 {
        if freq_hz <= 0.0 || sample_rate == 0 {
            return 1.0;
        }

        let w = 2.0 * PI * freq_hz / sample_rate as f32;
        let cos_w = w.cos();
        let sin_w = w.sin();
        let cos_2w = (2.0 * w).cos();
        let sin_2w = (2.0 * w).sin();

        let num_re = self.b0 + self.b1 * cos_w + self.b2 * cos_2w;
        let num_im = -self.b1 * sin_w - self.b2 * sin_2w;
        let den_re = 1.0 + self.a1 * cos_w + self.a2 * cos_2w;
        let den_im = -self.a1 * sin_w - self.a2 * sin_2w;

        let numerator = num_re.mul_add(num_re, num_im * num_im);
        let denominator = den_re.mul_add(den_re, den_im * den_im);
        if denominator <= f32::EPSILON {
            return 1.0;
        }

        (numerator / denominator).sqrt()
    }
}

#[derive(Clone)]
struct Biquad {
    coeffs: BiquadCoefficients,
    z1: f32,
    z2: f32,
}

impl Biquad {
    fn new(coeffs: BiquadCoefficients) -> Self {
        Self {
            coeffs,
            z1: 0.0,
            z2: 0.0,
        }
    }

    fn reset(&mut self) {
        self.z1 = 0.0;
        self.z2 = 0.0;
    }

    fn update_coeffs(&mut self, coeffs: BiquadCoefficients) {
        self.coeffs = coeffs;
    }

    fn process(&mut self, input: f32) -> f32 {
        let out = self.coeffs.b0 * input + self.z1;
        self.z1 = self.coeffs.b1 * input - self.coeffs.a1 * out + self.z2;
        self.z2 = self.coeffs.b2 * input - self.coeffs.a2 * out;
        out
    }
}

#[derive(Clone)]
struct EqualizerChain {
    enabled: bool,
    preamp_gain: f32,
    bass_boost: Option<Biquad>,
    bands: Vec<Biquad>,
}

impl EqualizerChain {
    fn from_config(config: &EqualizerConfig, sample_rate: u32) -> Self {
        let mut chain = Self::identity();
        chain.update_from_config(config, sample_rate);
        chain
    }

    fn identity() -> Self {
        Self {
            enabled: false,
            preamp_gain: 1.0,
            bass_boost: None,
            bands: Vec::new(),
        }
    }

    fn reset(&mut self) {
        if let Some(bass_boost) = self.bass_boost.as_mut() {
            bass_boost.reset();
        }
        for band in &mut self.bands {
            band.reset();
        }
    }

    fn update_from_config(&mut self, config: &EqualizerConfig, sample_rate: u32) {
        let config = config.clone().sanitized();
        if !config.enabled {
            *self = Self::identity();
            return;
        }

        self.enabled = true;
        self.preamp_gain = db_to_gain(config.preamp_db) / estimate_peak_gain(&config, sample_rate);
        self.bass_boost = if config.bass_boost_db.abs() > EPSILON_GAIN_DB {
            Some(Biquad::new(BiquadCoefficients::low_shelf(
                sample_rate,
                config.bass_boost_frequency_hz,
                config.bass_boost_q,
                config.bass_boost_db,
            )))
        } else {
            None
        };

        let band_count = config.band_count as usize;
        if self.bands.len() != band_count {
            self.bands = Vec::with_capacity(band_count);
            for band_index in 0..band_count {
                let coeffs = band_coefficients(&config, sample_rate, band_index, band_count);
                self.bands.push(Biquad::new(coeffs));
            }
            return;
        }

        for band_index in 0..band_count {
            let coeffs = band_coefficients(&config, sample_rate, band_index, band_count);
            if let Some(band) = self.bands.get_mut(band_index) {
                band.update_coeffs(coeffs);
            }
        }
    }

    fn process_sample(&mut self, mut sample: f32) -> f32 {
        if !self.enabled {
            return sample;
        }

        sample *= self.preamp_gain;
        if let Some(bass_boost) = self.bass_boost.as_mut() {
            sample = bass_boost.process(sample);
        }
        for band in &mut self.bands {
            sample = band.process(sample);
        }
        soft_limit_sample(sample)
    }
}

fn band_coefficients(
    config: &EqualizerConfig,
    sample_rate: u32,
    band_index: usize,
    band_count: usize,
) -> BiquadCoefficients {
    let freq = band_center_frequency(band_index, band_count);
    let gain_db = config.band_gains_db.get(band_index).copied().unwrap_or(0.0);
    if gain_db.abs() <= EPSILON_GAIN_DB {
        BiquadCoefficients::identity()
    } else {
        BiquadCoefficients::peaking(sample_rate, freq, 1.0, gain_db)
    }
}

fn estimate_peak_gain(config: &EqualizerConfig, sample_rate: u32) -> f32 {
    if sample_rate == 0 {
        return 1.0;
    }

    let band_count = config.band_count.clamp(0, MAX_EQ_BANDS as i32) as usize;
    let mut filters = Vec::with_capacity(band_count + 1);

    if config.bass_boost_db.abs() > EPSILON_GAIN_DB {
        filters.push(BiquadCoefficients::low_shelf(
            sample_rate,
            config.bass_boost_frequency_hz,
            config.bass_boost_q,
            config.bass_boost_db,
        ));
    }

    for band_index in 0..band_count {
        filters.push(band_coefficients(
            config,
            sample_rate,
            band_index,
            band_count,
        ));
    }

    if filters.is_empty() {
        return 1.0;
    }

    let min_hz = 20.0_f32;
    let nyquist_hz = (sample_rate as f32 / 2.0).max(min_hz);
    let max_hz = (nyquist_hz * 0.98).max(min_hz);
    let sweep_ratio = max_hz / min_hz;
    let mut peak_gain = 1.0_f32;

    for step in 0..256 {
        let t = step as f32 / 255.0;
        let freq_hz = min_hz * sweep_ratio.powf(t);
        let response_gain = filters.iter().fold(1.0_f32, |acc, coeffs| {
            acc * coeffs.magnitude_at(freq_hz, sample_rate)
        });
        peak_gain = peak_gain.max(response_gain);
    }

    if peak_gain > 1.000_1 {
        peak_gain * 1.05
    } else {
        1.0
    }
}

fn soft_limit_sample(sample: f32) -> f32 {
    let abs = sample.abs();
    if abs <= SOFT_LIMIT_THRESHOLD {
        return sample;
    }

    let sign = sample.signum();
    let normalized = ((abs - SOFT_LIMIT_THRESHOLD) / SOFT_LIMIT_KNEE_WIDTH).clamp(0.0, 1.0);
    let eased = normalized * normalized * (3.0 - 2.0 * normalized);
    let limited = SOFT_LIMIT_THRESHOLD + SOFT_LIMIT_KNEE_WIDTH * eased;
    sign * limited.min(1.0)
}

pub struct EqSource<S>
where
    S: Source<Item = f32>,
{
    inner: S,
    shared: Arc<EqualizerShared>,
    current_version: u64,
    chains: Vec<EqualizerChain>,
    channels: usize,
    sample_rate: u32,
    channel_index: usize,
    sample_counter: usize,
}

impl<S> EqSource<S>
where
    S: Source<Item = f32>,
{
    pub(crate) fn new(inner: S, shared: Arc<EqualizerShared>) -> Self {
        let channels = usize::from(inner.channels().get().max(1));
        let sample_rate = inner.sample_rate().get();
        let config = shared.current_config();
        let chains = (0..channels)
            .map(|_| EqualizerChain::from_config(&config, sample_rate))
            .collect::<Vec<_>>();

        Self {
            inner,
            shared,
            current_version: 0,
            chains,
            channels,
            sample_rate,
            channel_index: 0,
            sample_counter: 0,
        }
    }

    fn refresh_if_needed(&mut self) {
        let version = self.shared.version();
        if version == self.current_version {
            return;
        }

        let config = self.shared.current_config();
        for chain in &mut self.chains {
            chain.update_from_config(&config, self.sample_rate);
        }
        self.current_version = version;
    }

    fn process_current_sample(&mut self, sample: f32) -> f32 {
        if self.channels == 0 {
            return sample;
        }

        if self.sample_counter % CONFIG_REFRESH_STRIDE == 0 {
            self.refresh_if_needed();
        }
        self.sample_counter = self.sample_counter.wrapping_add(1);

        let channel = self.channel_index.min(self.chains.len().saturating_sub(1));
        let output = self
            .chains
            .get_mut(channel)
            .map(|chain| chain.process_sample(sample))
            .unwrap_or(sample);
        self.channel_index += 1;
        if self.channel_index >= self.channels {
            self.channel_index = 0;
        }
        output
    }
}

impl<S> Iterator for EqSource<S>
where
    S: Source<Item = f32>,
{
    type Item = f32;

    fn next(&mut self) -> Option<Self::Item> {
        let sample = self.inner.next()?;
        Some(self.process_current_sample(sample))
    }
}

impl<S> Source for EqSource<S>
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
        self.channel_index = 0;
        self.sample_counter = 0;
        for chain in &mut self.chains {
            chain.reset();
        }
        self.inner.try_seek(pos)
    }
}

fn band_center_frequency(index: usize, band_count: usize) -> f32 {
    if band_count <= 1 {
        return 1_000.0;
    }

    let min_hz = MIN_EQ_CENTER_HZ;
    let max_hz = MAX_EQ_CENTER_HZ;
    let ratio = max_hz / min_hz;
    let t = index as f32 / (band_count.saturating_sub(1) as f32);
    min_hz * ratio.powf(t)
}

fn db_to_gain(db: f32) -> f32 {
    10.0_f32.powf(db / 20.0)
}
