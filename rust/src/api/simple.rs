pub mod controller;
pub mod fft;
pub mod waveform;

use crate::frb_generated::StreamSink;
use std::thread;
use std::time::Duration;

pub use controller::{
    crossfade_to_audio_file, dispose_audio, get_audio_duration_ms, get_audio_position_ms,
    get_latest_fft, get_loaded_audio_path, init_app, is_audio_playing, load_audio_file,
    pause_audio, play_audio, seek_audio_ms, set_audio_volume, toggle_audio, PlaybackState,
};
pub use waveform::{extract_loaded_waveform, extract_waveform_for_path, WaveformChunk};

const PLAYBACK_STATE_PUSH_INTERVAL: Duration = Duration::from_millis(500);

#[flutter_rust_bridge::frb(sync)]
pub fn greet(name: String) -> String {
    format!("Hello, {name}!")
}

fn push_state() -> PlaybackState {
    controller::snapshot_playback_state()
}

fn trigger_state_push(
    sink: &StreamSink<PlaybackState, flutter_rust_bridge::for_generated::SseCodec>,
) -> bool {
    sink.add(push_state()).is_ok()
}

#[flutter_rust_bridge::frb(sync)]
pub fn subscribe_playback_state(
    sink: StreamSink<PlaybackState, flutter_rust_bridge::for_generated::SseCodec>,
) {
    thread::spawn(move || {
        if !trigger_state_push(&sink) {
            return;
        }

        loop {
            thread::sleep(PLAYBACK_STATE_PUSH_INTERVAL);
            if !trigger_state_push(&sink) {
                break;
            }
        }
    });
}
