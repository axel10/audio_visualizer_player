use super::controller;
use std::fs::File;
use std::path::Path;
use symphonia::core::audio::SampleBuffer;
use symphonia::core::codecs::{DecoderOptions, CODEC_TYPE_NULL};
use symphonia::core::errors::Error as SymphoniaError;
use symphonia::core::formats::FormatOptions;
use symphonia::core::io::MediaSourceStream;
use symphonia::core::meta::MetadataOptions;
use symphonia::core::probe::Hint;

#[derive(Debug, Clone)]
pub struct WaveformChunk {
    pub index: usize,
    pub peak: f32,
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

fn extract_waveform_from_path(
    path: &str,
    expected_chunks: usize,
    sample_stride: usize,
) -> Result<Vec<f32>, String> {
    if expected_chunks == 0 {
        return Err("expected_chunks must be > 0".to_string());
    }

    let sample_stride = sample_stride.max(1);

    let file = File::open(path).map_err(|e| format!("open file failed: {} - {}", path, e))?;
    let mut hint = Hint::new();
    if let Some(ext) = Path::new(path).extension().and_then(|e| e.to_str()) {
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

        let packet_dur = packet.dur();
        let packet_ts = packet.ts();

        let process_this_packet = packet_index % sample_stride == 0;
        packet_index = packet_index.saturating_add(1);

        if !process_this_packet {
            let packet_end_ts = packet_ts.saturating_add(packet_dur.max(1));
            if packet_end_ts > max_packet_end_ts {
                max_packet_end_ts = packet_end_ts;
            }
            continue;
        }

        let packet_end_ts = packet_ts.saturating_add(packet_dur.max(1));
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

    let effective_total_ts = total_ts.or(Some(max_packet_end_ts.max(1)));
    Ok(fold_packet_peaks_to_chunks(
        &packet_peaks,
        expected_chunks,
        effective_total_ts,
    ))
}

pub fn extract_loaded_waveform(
    expected_chunks: usize,
    sample_stride: usize,
) -> Result<Vec<f32>, String> {
    let path = controller::snapshot_loaded_path()
        .ok_or_else(|| "No loaded audio file to extract waveform from".to_string())?;

    let waveform = extract_waveform_from_path(&path, expected_chunks, sample_stride)?;

    if controller::snapshot_loaded_path().as_deref() != Some(path.as_str()) {
        return Err("loaded audio changed during waveform extraction, please retry".to_string());
    }

    Ok(waveform)
}

pub fn extract_waveform_for_path(
    path: String,
    expected_chunks: usize,
    sample_stride: usize,
) -> Result<Vec<f32>, String> {
    if path.trim().is_empty() {
        return Err("path is empty".to_string());
    }
    extract_waveform_from_path(&path, expected_chunks, sample_stride)
}
