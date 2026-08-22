# Benchmark

A self-benchmark of Plainsay's own two on-device transcription engines —
WhisperKit (Whisper large-v3-turbo) and FluidAudio (NVIDIA Parakeet TDT
0.6B v3) — measured for word error rate and latency on a public dataset with
published reference transcripts.

This is deliberately **not** a head-to-head against other dictation apps.
Running a competitor's proprietary software as part of an automated,
unattended benchmark isn't something we're set up to do fairly or
consistently, and republishing a competitor's own self-reported numbers
without independently reproducing them isn't something we're willing to
present as a fact. What follows is a measurement of what Plainsay itself
does, with enough method disclosed that anyone can check it or run it
themselves.

## Results (2026-08-22)

| Engine | WER | Avg latency | Real-time factor | Utterances |
|---|---|---|---|---|
| Parakeet TDT 0.6B v3 | **2.50%** | 0.10s | 0.014 | 50/50 |
| Whisper large-v3-turbo | **2.89%** | 0.68s | 0.095 | 50/50 |

- **WER** (word error rate): substitutions + deletions + insertions, divided
  by the reference word count, after lowercasing and stripping punctuation
  from both sides (standard ASR-benchmark normalization — see Methodology).
- **Real-time factor**: transcription time ÷ audio duration. Below 1.0 means
  faster than real time; Parakeet here is about 73x faster than the audio
  itself, Whisper about 10.5x.
- Zero failed transcriptions on either engine across all 50 clips.

Full per-utterance results, including every reference and hypothesis
transcript: [`Benchmark/data/results-2026-08-22.json`](Benchmark/data/results-2026-08-22.json)
(SHA-256 `3ad04a01a28ce1b87c52af0782be0c8eb4609a3333d1997515dd48e13af9ca9a`).
The [2026-08-17 result](Benchmark/data/results-2026-08-17.json) remains
available as a historical run rather than being silently replaced.

## Dataset

[LibriSpeech](https://www.openslr.org/12/) `test-clean`, from OpenSLR,
licensed CC BY 4.0 (Panayotov et al., 2015). Downloaded fresh from
`openslr.org/resources/12/test-clean.tar.gz` and verified against the
published MD5 checksum (`32fa31d27d2e1cad72775fee3f4849a9`) before use.

`test-clean` contains 2,620 utterances across 40 speakers. This run uses a
**50-utterance stratified sample**: 10 speakers spread evenly across the
sorted speaker list (every 4th), 5 utterances spread evenly across each
speaker's first chapter. This is disclosed as a sample, not the full set —
1,002 reference words total, small enough to review by hand (every
reference and hypothesis is in the results JSON), large enough to span 10
different voices and reading styles.

The 50 FLAC clips and their reference transcripts are committed in
[`Benchmark/data/`](Benchmark/data/) so the benchmark runs standalone,
without re-downloading the full 346 MB archive.

## Methodology

- **Audio**: loaded via `AVAudioFile` + `AVAudioConverter`, resampled to
  16 kHz mono Float32 — the same sample format `AudioRecorder` produces. The
  benchmark does not exercise the live microphone, room acoustics, or capture
  path.
- **Engines**: `WhisperKitEngine` and `ParakeetEngine` from `PlainsayCore`
  directly — the identical code the shipping app runs, not a reimplementation.
  No decoder prompt (empty vocabulary) for either. Dependencies were pinned to
  WhisperKit 1.1.0 (`1e2a163736dfa5a198e637ae44c114e1c6d5cc2d`)
  and FluidAudio 0.15.6
  (`4dbf4f9f9a5ff3a53ade848d7ba4e3df13db859b`).
- **Text normalization**: lowercase, strip all punctuation except
  apostrophes (so "don't" stays one word), collapse whitespace — applied to
  both the reference and the hypothesis before scoring. LibriSpeech
  references are bare uppercase words with no punctuation; Whisper's raw
  output includes capitalization and punctuation, so comparing without
  normalizing would count formatting as errors it isn't.
- **WER**: Levenshtein (edit-distance) alignment over word sequences —
  `(substitutions + deletions + insertions) / reference word count`.
- **Latency**: wall-clock time for `transcribe(samples:prompt:)` only after
  engine preparation. Audio decode, file I/O, model download, and model
  preparation are outside the timed region. There is deliberately no hidden,
  unmeasured transcription warm-up: the first timed clip is the first inference
  after `prepare()`, then the same model instance is reused for all 50 clips.
- **Hardware**: MacBook Air (`Mac16,12`), Apple M4 with a 10-core CPU, 16 GB
  memory, macOS 26.5.1 (build `25F80`).
- **Source state**: benchmark behavior and engine code at commit
  [`2bc1552b19a5ae4094bd81714461baf4ebaa7202`](https://github.com/conrader/plainsay/commit/2bc1552b19a5ae4094bd81714461baf4ebaa7202).

## Reproduce it

```sh
git checkout 2bc1552b19a5ae4094bd81714461baf4ebaa7202
swift build --product BenchmarkCLI
.build/debug/BenchmarkCLI Benchmark/data/librispeech-test-clean-manifest.json
```

Prints per-clip progress, then WER/latency/RTF per engine, and writes a full
`results.json` next to the manifest with every reference, hypothesis, and
per-clip timing.

The harness itself is [`Sources/BenchmarkCLI/main.swift`](Sources/BenchmarkCLI/main.swift) —
short enough to read end to end in a few minutes.

## What this doesn't claim

- Not a claim about accuracy on Polish, or any language other than English —
  `test-clean` is English-only. Parakeet's multilingual coverage and
  Whisper's language breadth are separate, unmeasured claims.
- Not a claim about accuracy on real dictation audio (a person talking into
  a laptop mic, mid-sentence corrections, background noise) — LibriSpeech is
  clean, professionally-read audiobook narration. Real dictation WER will be
  higher for both engines.
- Not a comparison against any other app. See the honest, sourced comparison
  pages instead: [plainsay.app/vs/](https://plainsay.app/vs/wispr-flow/).
