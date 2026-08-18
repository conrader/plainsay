//! Microphone capture via WASAPI (through `cpal`), downmixed and resampled
//! to 16kHz mono `f32` — the format the Cloud API's `durationSeconds` and the
//! WAV encoder below both assume.

use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use std::sync::{Arc, Mutex};

pub const TARGET_SAMPLE_RATE: u32 = 16_000;

/// A microphone capture in progress. Dropping it stops the stream.
pub struct Recording {
    stream: cpal::Stream,
    samples: Arc<Mutex<Vec<f32>>>,
    source_rate: u32,
    source_channels: u16,
}

impl Recording {
    /// Starts capturing from the system default input device immediately.
    pub fn start() -> Result<Self, String> {
        let host = cpal::default_host();
        let device = host
            .default_input_device()
            .ok_or("No microphone found")?;
        let config = device
            .default_input_config()
            .map_err(|e| format!("Could not read microphone config: {e}"))?;

        let source_rate = config.sample_rate().0;
        let source_channels = config.channels();
        let samples = Arc::new(Mutex::new(Vec::new()));
        let samples_for_stream = Arc::clone(&samples);

        let err_fn = |err| eprintln!("audio stream error: {err}");

        let stream = match config.sample_format() {
            cpal::SampleFormat::F32 => device.build_input_stream(
                &config.into(),
                move |data: &[f32], _| {
                    samples_for_stream.lock().unwrap().extend_from_slice(data);
                },
                err_fn,
                None,
            ),
            cpal::SampleFormat::I16 => device.build_input_stream(
                &config.into(),
                move |data: &[i16], _| {
                    let mut buf = samples_for_stream.lock().unwrap();
                    buf.extend(data.iter().map(|s| *s as f32 / i16::MAX as f32));
                },
                err_fn,
                None,
            ),
            cpal::SampleFormat::U16 => device.build_input_stream(
                &config.into(),
                move |data: &[u16], _| {
                    let mut buf = samples_for_stream.lock().unwrap();
                    buf.extend(
                        data.iter()
                            .map(|s| (*s as f32 - u16::MAX as f32 / 2.0) / (u16::MAX as f32 / 2.0)),
                    );
                },
                err_fn,
                None,
            ),
            other => return Err(format!("Unsupported sample format: {other:?}")),
        }
        .map_err(|e| format!("Could not start recording: {e}"))?;

        stream
            .play()
            .map_err(|e| format!("Could not start recording: {e}"))?;

        Ok(Self {
            stream,
            samples,
            source_rate,
            source_channels,
        })
    }

    /// Stops the stream and returns everything captured, downmixed to mono
    /// and resampled to [`TARGET_SAMPLE_RATE`].
    pub fn finish(self) -> Vec<f32> {
        drop(self.stream);
        let raw = self.samples.lock().unwrap().clone();
        let mono = downmix(&raw, self.source_channels);
        resample_linear(&mono, self.source_rate, TARGET_SAMPLE_RATE)
    }
}

fn downmix(interleaved: &[f32], channels: u16) -> Vec<f32> {
    let channels = channels.max(1) as usize;
    if channels == 1 {
        return interleaved.to_vec();
    }
    interleaved
        .chunks(channels)
        .map(|frame| frame.iter().sum::<f32>() / frame.len() as f32)
        .collect()
}

/// Simple linear-interpolation resampler. Speech-adequate, not
/// broadcast-grade — good enough for a dictation clip a couple of seconds to
/// a couple of minutes long.
fn resample_linear(samples: &[f32], from_rate: u32, to_rate: u32) -> Vec<f32> {
    if from_rate == to_rate || samples.is_empty() {
        return samples.to_vec();
    }
    let ratio = from_rate as f64 / to_rate as f64;
    let out_len = ((samples.len() as f64) / ratio).round() as usize;
    let mut out = Vec::with_capacity(out_len);
    for i in 0..out_len {
        let src_pos = i as f64 * ratio;
        let idx = src_pos.floor() as usize;
        let frac = (src_pos - idx as f64) as f32;
        let a = samples.get(idx).copied().unwrap_or(0.0);
        let b = samples.get(idx + 1).copied().unwrap_or(a);
        out.push(a + (b - a) * frac);
    }
    out
}

/// Standard 16-bit PCM mono RIFF/WAVE, matching the Mac client's
/// `WAVEncoder` byte-for-byte (see `Sources/PlainsayCore/RemoteWhisperEngine.swift`)
/// so the server-side format assumptions hold for either client.
pub fn encode_wav(samples: &[f32], sample_rate: u32) -> Vec<u8> {
    let channels: u32 = 1;
    let bits_per_sample: u32 = 16;
    let byte_rate = sample_rate * channels * bits_per_sample / 8;
    let block_align = (channels * bits_per_sample / 8) as u16;
    let data_size = (samples.len() * (bits_per_sample as usize) / 8) as u32;

    let mut out = Vec::with_capacity(44 + data_size as usize);
    out.extend_from_slice(b"RIFF");
    out.extend_from_slice(&(36 + data_size).to_le_bytes());
    out.extend_from_slice(b"WAVE");
    out.extend_from_slice(b"fmt ");
    out.extend_from_slice(&16u32.to_le_bytes()); // fmt chunk size
    out.extend_from_slice(&1u16.to_le_bytes()); // PCM
    out.extend_from_slice(&(channels as u16).to_le_bytes());
    out.extend_from_slice(&sample_rate.to_le_bytes());
    out.extend_from_slice(&byte_rate.to_le_bytes());
    out.extend_from_slice(&block_align.to_le_bytes());
    out.extend_from_slice(&(bits_per_sample as u16).to_le_bytes());
    out.extend_from_slice(b"data");
    out.extend_from_slice(&data_size.to_le_bytes());

    for sample in samples {
        let clamped = sample.clamp(-1.0, 1.0);
        let value = (clamped * i16::MAX as f32) as i16;
        out.extend_from_slice(&value.to_le_bytes());
    }
    out
}
