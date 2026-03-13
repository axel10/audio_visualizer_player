use rodio::{source::Source, Decoder};
use std::io::BufReader;
use std::time::Duration;
use std::{fs::File, num::NonZero};
use rustfft::{num_complex::Complex, FftPlanner};
const FFT_SIZE: usize = 1024;
use std::sync::Arc;

struct FftSource<S>
where
    S: Source<Item = f32>,
{
    inner: S,
    fft: Arc<dyn rustfft::Fft<f32>>,
    buffer: Vec<Complex<f32>>,
    index: usize,
}

impl<S> FftSource<S>
where
    S: Source<Item = f32>,
{
    fn new(inner: S) -> Self {
        let mut planner = FftPlanner::<f32>::new();
        let fft = planner.plan_fft_forward(FFT_SIZE);

        Self {
            inner,
            fft,
            buffer: vec![Complex { re: 0.0, im: 0.0 }; FFT_SIZE],
            index: 0,
        }
    }

    fn compute_fft(&mut self) {
        self.fft.process(&mut self.buffer);

        let spectrum: Vec<f32> = self
            .buffer
            .iter()
            .take(FFT_SIZE / 2)
            .map(|c| (c.re * c.re + c.im * c.im).sqrt())
            .collect();

        println!("FFT bins: {}", spectrum.iter().map(|v| v.to_string()).collect::<Vec<_>>().join(","));
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

    fn channels(&self) -> NonZero<u16> {
        self.inner.channels()
    }

    fn sample_rate(&self) -> NonZero<u32> {
        self.inner.sample_rate()
    }

    fn total_duration(&self) -> Option<Duration> {
        self.inner.total_duration()
    }
}

fn main() {
    // _stream must live as long as the sink
    let handle = rodio::DeviceSinkBuilder::open_default_sink().expect("open default audio stream");
    let player = rodio::Player::connect_new(&handle.mixer());

    let file = File::open("e:/test.m4a").expect("找不到音频文件");

    let source = Decoder::new(BufReader::new(file)).expect("解码失败");
    let fft_source = FftSource::new(source);
    
    player.append(fft_source);
    // The sound plays in a separate thread. This call will block the current thread until the
    // player has finished playing all its queued sounds.
    player.sleep_until_end();
}
