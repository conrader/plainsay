//! Microphone capture via WASAPI (through `cpal`), downmixed and resampled
//! to 48kHz mono `f32`. Windows Media Foundation's AAC encoder supports this
//! rate natively, and the Cloud API derives duration from the same samples.

use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use cpal::{FromSample, SizedSample};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

pub const TARGET_SAMPLE_RATE: u32 = 48_000;
const MAX_RECORDING_SECONDS: u32 = 10 * 60;

/// A microphone capture in progress. Dropping it stops the stream.
pub struct Recording {
    stream: cpal::Stream,
    // Samples are downmixed in the realtime callback, so a long stereo
    // recording does not retain twice as much memory as the encoder needs.
    samples: Arc<Mutex<Vec<f32>>>,
    source_rate: u32,
    reached_limit: Arc<AtomicBool>,
    stream_error: Arc<Mutex<Option<String>>>,
}

pub enum CaptureStatus {
    Capturing,
    LimitReached,
    Failed(String),
}

impl Recording {
    /// Starts capturing from the system default input device immediately.
    pub fn start() -> Result<Self, String> {
        let host = cpal::default_host();
        let device = host.default_input_device().ok_or("No microphone found")?;
        let config = device
            .default_input_config()
            .map_err(|e| format!("Could not read microphone config: {e}"))?;

        let source_rate = config.sample_rate().0;
        let source_channels = config.channels();
        let max_frames = source_rate as usize * MAX_RECORDING_SECONDS as usize;
        let samples = Arc::new(Mutex::new(Vec::new()));
        let reached_limit = Arc::new(AtomicBool::new(false));
        let stream_error = Arc::new(Mutex::new(None));
        let stream_config: cpal::StreamConfig = config.clone().into();
        let stream = match config.sample_format() {
            cpal::SampleFormat::I8 => build_capture_stream::<i8>(
                &device,
                &stream_config,
                Arc::clone(&samples),
                source_channels,
                max_frames,
                Arc::clone(&reached_limit),
                Arc::clone(&stream_error),
            ),
            cpal::SampleFormat::I16 => build_capture_stream::<i16>(
                &device,
                &stream_config,
                Arc::clone(&samples),
                source_channels,
                max_frames,
                Arc::clone(&reached_limit),
                Arc::clone(&stream_error),
            ),
            cpal::SampleFormat::I32 => build_capture_stream::<i32>(
                &device,
                &stream_config,
                Arc::clone(&samples),
                source_channels,
                max_frames,
                Arc::clone(&reached_limit),
                Arc::clone(&stream_error),
            ),
            cpal::SampleFormat::I64 => build_capture_stream::<i64>(
                &device,
                &stream_config,
                Arc::clone(&samples),
                source_channels,
                max_frames,
                Arc::clone(&reached_limit),
                Arc::clone(&stream_error),
            ),
            cpal::SampleFormat::U8 => build_capture_stream::<u8>(
                &device,
                &stream_config,
                Arc::clone(&samples),
                source_channels,
                max_frames,
                Arc::clone(&reached_limit),
                Arc::clone(&stream_error),
            ),
            cpal::SampleFormat::U16 => build_capture_stream::<u16>(
                &device,
                &stream_config,
                Arc::clone(&samples),
                source_channels,
                max_frames,
                Arc::clone(&reached_limit),
                Arc::clone(&stream_error),
            ),
            cpal::SampleFormat::U32 => build_capture_stream::<u32>(
                &device,
                &stream_config,
                Arc::clone(&samples),
                source_channels,
                max_frames,
                Arc::clone(&reached_limit),
                Arc::clone(&stream_error),
            ),
            cpal::SampleFormat::U64 => build_capture_stream::<u64>(
                &device,
                &stream_config,
                Arc::clone(&samples),
                source_channels,
                max_frames,
                Arc::clone(&reached_limit),
                Arc::clone(&stream_error),
            ),
            cpal::SampleFormat::F32 => build_capture_stream::<f32>(
                &device,
                &stream_config,
                Arc::clone(&samples),
                source_channels,
                max_frames,
                Arc::clone(&reached_limit),
                Arc::clone(&stream_error),
            ),
            cpal::SampleFormat::F64 => build_capture_stream::<f64>(
                &device,
                &stream_config,
                Arc::clone(&samples),
                source_channels,
                max_frames,
                Arc::clone(&reached_limit),
                Arc::clone(&stream_error),
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
            reached_limit,
            stream_error,
        })
    }

    pub fn status(&self) -> CaptureStatus {
        if let Ok(error) = self.stream_error.lock() {
            if let Some(error) = error.as_ref() {
                return CaptureStatus::Failed(error.clone());
            }
        }
        if self.reached_limit.load(Ordering::Acquire) {
            CaptureStatus::LimitReached
        } else {
            CaptureStatus::Capturing
        }
    }

    /// Stops the stream and returns everything captured, downmixed to mono
    /// and resampled to [`TARGET_SAMPLE_RATE`].
    pub fn finish(self) -> Vec<f32> {
        let Self {
            stream,
            samples,
            source_rate,
            ..
        } = self;
        drop(stream);
        let raw = match Arc::try_unwrap(samples) {
            Ok(samples) => samples
                .into_inner()
                .unwrap_or_else(|poisoned| poisoned.into_inner()),
            Err(samples) => {
                let mut samples = samples
                    .lock()
                    .unwrap_or_else(|poisoned| poisoned.into_inner());
                std::mem::take(&mut *samples)
            }
        };
        if source_rate == TARGET_SAMPLE_RATE {
            raw
        } else {
            resample_linear(&raw, source_rate, TARGET_SAMPLE_RATE)
        }
    }
}

fn build_capture_stream<T>(
    device: &cpal::Device,
    config: &cpal::StreamConfig,
    samples: Arc<Mutex<Vec<f32>>>,
    channels: u16,
    max_frames: usize,
    reached_limit: Arc<AtomicBool>,
    stream_error: Arc<Mutex<Option<String>>>,
) -> Result<cpal::Stream, cpal::BuildStreamError>
where
    T: SizedSample,
    f32: FromSample<T>,
{
    device.build_input_stream(
        config,
        move |data: &[T], _| {
            let mut buffer = samples.lock().unwrap();
            let channels = channels.max(1) as usize;
            for frame in data.chunks(channels) {
                if frame.len() != channels || buffer.len() >= max_frames {
                    break;
                }
                let mono = frame
                    .iter()
                    .map(|sample| <f32 as FromSample<T>>::from_sample_(*sample))
                    .sum::<f32>()
                    / channels as f32;
                buffer.push(mono);
            }
            if buffer.len() >= max_frames {
                reached_limit.store(true, Ordering::Release);
            }
        },
        move |error| {
            if let Ok(mut current) = stream_error.lock() {
                *current = Some(error.to_string());
            }
        },
        None,
    )
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

#[cfg(target_os = "windows")]
pub fn encode_m4a(samples: &[f32], sample_rate: u32) -> Result<Vec<u8>, String> {
    media_foundation::encode_m4a(samples, sample_rate)
}

#[cfg(not(target_os = "windows"))]
pub fn encode_m4a(_samples: &[f32], _sample_rate: u32) -> Result<Vec<u8>, String> {
    Err("M4A encoding is only available on Windows".to_string())
}

#[cfg(target_os = "windows")]
mod media_foundation {
    use std::sync::OnceLock;
    use windows::core::HSTRING;
    use windows::Win32::Foundation::RPC_E_CHANGED_MODE;
    use windows::Win32::Media::MediaFoundation::{
        IMFSinkWriter, MFAudioFormat_AAC, MFAudioFormat_PCM, MFCreateAttributes, MFCreateMediaType,
        MFCreateMemoryBuffer, MFCreateSample, MFCreateSinkWriterFromURL, MFMediaType_Audio,
        MFStartup, MFTranscodeContainerType_MPEG4, MFSTARTUP_FULL, MF_MT_ALL_SAMPLES_INDEPENDENT,
        MF_MT_AUDIO_AVG_BYTES_PER_SECOND, MF_MT_AUDIO_BITS_PER_SAMPLE, MF_MT_AUDIO_BLOCK_ALIGNMENT,
        MF_MT_AUDIO_NUM_CHANNELS, MF_MT_AUDIO_SAMPLES_PER_SECOND, MF_MT_MAJOR_TYPE, MF_MT_SUBTYPE,
        MF_TRANSCODE_CONTAINERTYPE, MF_VERSION,
    };
    use windows::Win32::System::Com::{CoInitializeEx, CoUninitialize, COINIT_MULTITHREADED};

    const CHANNELS: u32 = 1;
    const BITS_PER_SAMPLE: u32 = 16;
    const AAC_BYTES_PER_SECOND: u32 = 12_000; // 96 kbps, ample for mono speech.
    const PCM_CHUNK_FRAMES: usize = 48_000;

    static MEDIA_FOUNDATION: OnceLock<Result<(), String>> = OnceLock::new();

    struct ComApartment(bool);

    impl ComApartment {
        fn join() -> Result<Self, String> {
            let result = unsafe { CoInitializeEx(None, COINIT_MULTITHREADED) };
            if result.is_err() && result != RPC_E_CHANGED_MODE {
                return Err(format!(
                    "Could not initialize Windows media services: {result}"
                ));
            }
            Ok(Self(result.is_ok()))
        }
    }

    impl Drop for ComApartment {
        fn drop(&mut self) {
            if self.0 {
                unsafe { CoUninitialize() };
            }
        }
    }

    fn start_media_foundation() -> Result<(), String> {
        MEDIA_FOUNDATION
            .get_or_init(|| unsafe {
                MFStartup(MF_VERSION, MFSTARTUP_FULL)
                    .map_err(|e| format!("Windows Media Foundation is unavailable: {e}"))
            })
            .clone()
    }

    pub fn encode_m4a(samples: &[f32], sample_rate: u32) -> Result<Vec<u8>, String> {
        if samples.is_empty() {
            return Err("No audio was recorded".to_string());
        }
        if sample_rate != 48_000 {
            return Err(format!(
                "AAC encoding requires 48000 Hz audio, got {sample_rate}"
            ));
        }

        let _apartment = ComApartment::join()?;
        start_media_foundation()?;

        let temporary = tempfile::Builder::new()
            .prefix("plainsay-")
            .suffix(".m4a")
            .tempfile()
            .map_err(|e| format!("Could not create a temporary audio file: {e}"))?
            .into_temp_path();
        // Reserve a collision-free name, then let Media Foundation create the
        // container itself. `TempPath` still removes the output on drop.
        std::fs::remove_file(&temporary)
            .map_err(|e| format!("Could not prepare the temporary audio file: {e}"))?;

        let (writer, stream_index) = create_writer(&temporary, sample_rate)?;
        let pcm: Vec<i16> = samples
            .iter()
            .map(|sample| (sample.clamp(-1.0, 1.0) * i16::MAX as f32) as i16)
            .collect();

        let mut frame_offset = 0u64;
        for chunk in pcm.chunks(PCM_CHUNK_FRAMES) {
            write_pcm(&writer, stream_index, chunk, frame_offset, sample_rate)?;
            frame_offset += chunk.len() as u64;
        }
        unsafe {
            writer
                .Finalize()
                .map_err(|e| format!("Could not finish AAC encoding: {e}"))?;
        }
        drop(writer);

        let encoded =
            std::fs::read(&temporary).map_err(|e| format!("Could not read encoded audio: {e}"))?;
        if encoded.len() < 12 || &encoded[4..8] != b"ftyp" {
            return Err("Windows produced an invalid M4A file".to_string());
        }
        Ok(encoded)
    }

    fn create_writer(
        path: &std::path::Path,
        sample_rate: u32,
    ) -> Result<(IMFSinkWriter, u32), String> {
        unsafe {
            let target = HSTRING::from(path.as_os_str());
            let mut attributes = None;
            MFCreateAttributes(&mut attributes, 1)
                .map_err(|e| format!("Could not create M4A attributes: {e}"))?;
            let attributes = attributes.ok_or("Could not create M4A attributes")?;
            attributes
                .SetGUID(&MF_TRANSCODE_CONTAINERTYPE, &MFTranscodeContainerType_MPEG4)
                .map_err(|e| format!("Could not select the M4A container: {e}"))?;
            let writer: IMFSinkWriter = MFCreateSinkWriterFromURL(&target, None, &attributes)
                .map_err(|e| format!("Could not create the M4A encoder: {e}"))?;

            let output = MFCreateMediaType()
                .map_err(|e| format!("Could not create the AAC output format: {e}"))?;
            output
                .SetGUID(&MF_MT_MAJOR_TYPE, &MFMediaType_Audio)
                .map_err(|e| format!("Could not configure AAC output: {e}"))?;
            output
                .SetGUID(&MF_MT_SUBTYPE, &MFAudioFormat_AAC)
                .map_err(|e| format!("Could not configure AAC output: {e}"))?;
            output
                .SetUINT32(&MF_MT_AUDIO_BITS_PER_SAMPLE, BITS_PER_SAMPLE)
                .map_err(|e| format!("Could not configure AAC output: {e}"))?;
            output
                .SetUINT32(&MF_MT_AUDIO_SAMPLES_PER_SECOND, sample_rate)
                .map_err(|e| format!("Could not configure AAC output: {e}"))?;
            output
                .SetUINT32(&MF_MT_AUDIO_NUM_CHANNELS, CHANNELS)
                .map_err(|e| format!("Could not configure AAC output: {e}"))?;
            output
                .SetUINT32(&MF_MT_AUDIO_AVG_BYTES_PER_SECOND, AAC_BYTES_PER_SECOND)
                .map_err(|e| format!("Could not configure AAC output: {e}"))?;
            let stream = writer
                .AddStream(&output)
                .map_err(|e| format!("Windows rejected the AAC output format: {e}"))?;

            let input = MFCreateMediaType()
                .map_err(|e| format!("Could not create the PCM input format: {e}"))?;
            input
                .SetGUID(&MF_MT_MAJOR_TYPE, &MFMediaType_Audio)
                .map_err(|e| format!("Could not configure PCM input: {e}"))?;
            input
                .SetGUID(&MF_MT_SUBTYPE, &MFAudioFormat_PCM)
                .map_err(|e| format!("Could not configure PCM input: {e}"))?;
            input
                .SetUINT32(&MF_MT_AUDIO_BITS_PER_SAMPLE, BITS_PER_SAMPLE)
                .map_err(|e| format!("Could not configure PCM input: {e}"))?;
            input
                .SetUINT32(&MF_MT_AUDIO_SAMPLES_PER_SECOND, sample_rate)
                .map_err(|e| format!("Could not configure PCM input: {e}"))?;
            input
                .SetUINT32(&MF_MT_AUDIO_NUM_CHANNELS, CHANNELS)
                .map_err(|e| format!("Could not configure PCM input: {e}"))?;
            let block_alignment = CHANNELS * BITS_PER_SAMPLE / 8;
            input
                .SetUINT32(&MF_MT_AUDIO_BLOCK_ALIGNMENT, block_alignment)
                .map_err(|e| format!("Could not configure PCM input: {e}"))?;
            input
                .SetUINT32(
                    &MF_MT_AUDIO_AVG_BYTES_PER_SECOND,
                    sample_rate * block_alignment,
                )
                .map_err(|e| format!("Could not configure PCM input: {e}"))?;
            input
                .SetUINT32(&MF_MT_ALL_SAMPLES_INDEPENDENT, 1)
                .map_err(|e| format!("Could not configure PCM input: {e}"))?;
            writer
                .SetInputMediaType(stream, &input, None)
                .map_err(|e| format!("Windows rejected the PCM input format: {e}"))?;
            writer
                .BeginWriting()
                .map_err(|e| format!("Could not start AAC encoding: {e}"))?;
            Ok((writer, stream))
        }
    }

    fn write_pcm(
        writer: &IMFSinkWriter,
        stream_index: u32,
        samples: &[i16],
        frame_offset: u64,
        sample_rate: u32,
    ) -> Result<(), String> {
        let byte_len = std::mem::size_of_val(samples) as u32;
        let start = (frame_offset * 10_000_000 / sample_rate as u64) as i64;
        let duration = (samples.len() as u64 * 10_000_000 / sample_rate as u64) as i64;

        unsafe {
            let buffer = MFCreateMemoryBuffer(byte_len)
                .map_err(|e| format!("Could not allocate an audio buffer: {e}"))?;
            let mut destination = std::ptr::null_mut();
            buffer
                .Lock(&mut destination, None, None)
                .map_err(|e| format!("Could not lock an audio buffer: {e}"))?;
            std::ptr::copy_nonoverlapping(
                samples.as_ptr() as *const u8,
                destination,
                byte_len as usize,
            );
            buffer
                .Unlock()
                .map_err(|e| format!("Could not unlock an audio buffer: {e}"))?;
            buffer
                .SetCurrentLength(byte_len)
                .map_err(|e| format!("Could not size an audio buffer: {e}"))?;

            let sample =
                MFCreateSample().map_err(|e| format!("Could not create an audio sample: {e}"))?;
            sample
                .AddBuffer(&buffer)
                .map_err(|e| format!("Could not fill an audio sample: {e}"))?;
            sample
                .SetSampleTime(start)
                .map_err(|e| format!("Could not timestamp audio: {e}"))?;
            sample
                .SetSampleDuration(duration)
                .map_err(|e| format!("Could not set audio duration: {e}"))?;
            writer
                .WriteSample(stream_index, &sample)
                .map_err(|e| format!("Could not encode audio: {e}"))?;
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn resampling_preserves_duration() {
        let input = vec![0.25; 16_000];
        let output = resample_linear(&input, 16_000, 48_000);
        assert_eq!(output.len(), 48_000);
    }

    #[cfg(target_os = "windows")]
    #[test]
    fn media_foundation_produces_m4a() {
        let samples: Vec<f32> = (0..TARGET_SAMPLE_RATE)
            .map(|i| {
                ((i as f32 / TARGET_SAMPLE_RATE as f32) * 440.0 * std::f32::consts::TAU).sin() * 0.2
            })
            .collect();
        let encoded = encode_m4a(&samples, TARGET_SAMPLE_RATE).expect("AAC encoding failed");
        assert!(encoded.len() > 1_000);
        assert_eq!(&encoded[4..8], b"ftyp");
    }
}
