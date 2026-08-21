# Product Hunt launch package

Internal draft. Use only after the authentic demo and ten-person dry run are
complete. Do not add fake testimonials, user counts, installation counts, or
coordinated votes.

## Listing fields

**Product name**

> Plainsay

**Tagline**

> Local Mac dictation with Whisper and Parakeet

**Short description**

> Hold a key, speak, and release. Plainsay inserts the transcript at your
> cursor in any Mac app. Local mode is free, needs no account, and runs Whisper
> or Parakeet on-device. The native client is about 12 MB and MIT-licensed.

**Primary link**

> https://plainsay.app/

**Repository link**

> https://github.com/conrader/plainsay

**Topics**

> Productivity · Open Source · Mac · Accessibility · Artificial Intelligence

## Gallery order

1. The authentic 20–30 second PL+EN cursor-insertion demo from
   `demo-storyboard.md`.
2. A single frame showing **On this Mac** as the default and Whisper/Parakeet
   choices.
3. The hold-to-talk HUD beside a real text cursor and untouched output.
4. A compact benchmark card labeled “50 English LibriSpeech test-clean clips”
   and linked to the method and raw results.
5. A source/privacy card: “MIT Mac client; optional Cloud backend is separate
   and not open source.”

Every size claim in a gallery asset should say “12 MB client” or “12 MB DMG.”
At least one asset should state that local models are separate 475–632 MB
downloads. Do not hide Cloud's audio transfer in an FAQ-only image.

## Maker comment

Hello Product Hunt — Plainsay is a native dictation app for Apple-silicon Macs
running macOS 14 or newer. The interaction is intentionally small: hold Right
Command, speak, release, and the text lands at the cursor.

Local mode is the free default and needs no account. It offers Whisper and
NVIDIA Parakeet on-device. The notarized client DMG is about 12 MB; a selected
local model is downloaded separately and is approximately 475–632 MB.

For people who prefer not to download a model, optional Plainsay Cloud is about
$3/month. That route sends recorded audio for hosted transcription and
Polishing. The Mac client and benchmark are MIT-licensed, while the Cloud
backend is separate and not open source.

The repository includes the benchmark harness, raw results, and limitations.
The current run is only 50 clean English LibriSpeech clips with warm models —
useful evidence, but not a claim about noisy rooms, spontaneous speech, Polish,
or every Mac.

Feedback on first-run permissions, insertion reliability across different Mac
apps, and the clarity of the Local/Cloud choice would be especially useful.

## Compact FAQ

**Is it free?**

Local mode is free and needs no account. Optional Plainsay Cloud costs about
$3/month.

**Does audio leave the Mac?**

Not with Local transcription and Polishing off or local. Cloud transcription
sends recorded audio, and hosted Polishing sends transcript text to the chosen
provider.

**Why is the client only about 12 MB?**

The DMG contains the native app. Local models are downloaded separately and
are approximately 475–632 MB.

**What is open source?**

The Mac client, benchmark, and release tooling are MIT-licensed. The optional
Cloud backend is not open source.

**What Macs are supported?**

Apple-silicon Macs running macOS 14 or newer.

## Launch-day checks

- The primary link opens quickly and the download is one obvious action away.
- The version shown in the demo equals the public download.
- Pricing, requirements, model-download size, and Cloud audio transfer are
  visible without opening the FAQ.
- Privacy policy and terms have final operator details and working links.
- A maker is available to answer comments and convert reproducible defects into
  GitHub issues.
- Baseline stars, repository visitors, download proxies, and paid trials are
  recorded immediately before launch.
- No team member, friend, or tester has been asked to coordinate a vote.
