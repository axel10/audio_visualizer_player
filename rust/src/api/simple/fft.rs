use realfft::{num_complex::Complex, RealFftPlanner, RealToComplex};
use rodio::Source;
use std::sync::{Arc, Mutex};
use std::time::Duration;

pub const FFT_SIZE: usize = 1024;
pub const RAW_FFT_BINS: usize = FFT_SIZE / 2;

pub(super) fn clear_fft_buffer(latest_fft: &Arc<Mutex<Vec<f32>>>) {
    if let Ok(mut shared) = latest_fft.lock() {
        shared.fill(0.0);
    }
}

pub struct FftSource<S>
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
    pub fn new(inner: S, latest_fft: Arc<Mutex<Vec<f32>>>) -> Self {
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
        self.output_buffer.fill(Complex { re: 0.0, im: 0.0 });
        self.inner.try_seek(pos)
    }
}
