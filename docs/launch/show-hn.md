# Show HN package

Internal draft. Submit only after the install gate and ten-person dry run in
this directory. A maker should be available to answer technical questions for
the first several hours. Do not ask anyone to upvote or seed comments.

## Submission

**Title — 74 characters:**

> Show HN: Plainsay – a 12 MB native Mac dictation app with local benchmarks

**URL:** <https://github.com/conrader/plainsay>

## Text body

Plainsay is a native dictation app for Apple-silicon Macs running macOS 14 or
newer. Hold Right Command, speak, and release; the transcript is inserted at
the current cursor.

The Mac client is MIT-licensed. Local mode is the free default, needs no
account, and runs either Whisper or NVIDIA Parakeet on the Mac. The notarized
client DMG is about 12 MB; the selected local model is a separate one-time
download of about 475–632 MB.

There is also an optional Plainsay Cloud mode for people who want hosted
transcription and Polishing without a model download. It costs about $3/month
and sends recorded audio to the service. The Cloud backend is separate and is
not open source.

The repository includes a benchmark harness and every result from a 50-clip
sample of English LibriSpeech `test-clean`. With warm models, that run measured
2.30% WER and 0.10 s average latency for Parakeet, and 2.89% WER and 0.72 s for
Whisper. These are clean audiobook clips, not real-world dictation, and they do
not establish Polish or broader multilingual accuracy.

The most useful feedback would be on first-run permissions, insertion across
native apps/Electron/browser text fields/terminals, and whether the Local versus
Cloud boundary is clear enough before anyone presses Record.

- Repository and download: <https://github.com/conrader/plainsay>
- Benchmark and limitations: <https://github.com/conrader/plainsay/blob/main/BENCHMARK.md>
- How it works: <https://plainsay.app/how-it-works/>

## First comment for a URL submission

Some context for the technical choices:

- macOS already has Dictation. Plainsay is aimed at users who want selectable
  local engines, a hold-to-talk workflow across apps, inspectable insertion
  behavior, and a local path they can audit and benchmark.
- The shipping app runs the same WhisperKit and FluidAudio engine wrappers used
  by the committed benchmark harness. The published numbers are deliberately
  narrow: 50 clean English LibriSpeech clips with already-loaded models. They
  are not a competitor comparison or a claim about laptop-mic dictation.
- The 12 MB figure describes the notarized client DMG, not the local models.
  Those are downloaded separately and are approximately 475–632 MB.
- Local is the new-install default and is free without an account. The optional
  Cloud route is about $3/month and sends recorded audio. The Mac client is
  MIT-licensed; the Cloud backend is not open source.
- Text insertion snapshots the clipboard, pastes, and restores the previous
  clipboard content. Polishing is optional and time-bounded; a failure falls
  back to the raw transcript instead of dropping the dictation.

Critical feedback is welcome, especially a reproducible app/field where paste
or clipboard restoration fails, a permission step that is unclear, or a claim
whose qualification is too easy to miss.

## Likely questions to answer directly

**Why not built-in macOS Dictation?**

The case is control and inspectability: explicit local engine choice,
hold-to-talk behavior, visible source, a published benchmark, configurable
insertion, and an optional raw-transcript fallback. Do not claim that Plainsay
is universally more accurate unless a fair comparison is added later.

**Is it really private?**

In Local mode with Polishing off or local, recorded audio and transcript stay
on the Mac. Plainsay Cloud sends recorded audio. Hosted Polishing or a user
configured speech provider sends data to the selected provider. State the mode
every time.

**How can the app be 12 MB if it runs these models?**

The native client DMG is about 12 MB. A local model is downloaded once after
installation and is about 475–632 MB.

**Is everything open source?**

No. The Mac client, benchmark, and release tooling are MIT-licensed. The
optional paid Cloud backend is separate and not open source.
