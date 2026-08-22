<p align="center">
  <img src="docs/assets/logo.svg" alt="Plainsay" width="96" height="96">
</p>

<h1 align="center">Plainsay</h1>

<p align="center"><strong>Hold a key. Speak. Release. Get text at your cursor—or safely on the clipboard.</strong></p>

<p align="center">
  A native Mac dictation app in a 12 MB download, with Whisper and Parakeet running locally.
</p>

<p align="center">
  <a href="https://github.com/conrader/plainsay"><strong>Star Plainsay on GitHub ★</strong></a>
  · <a href="https://api.plainsay.app/releases/Plainsay-latest.dmg"><strong>Download Plainsay.dmg</strong></a>
  · <a href="#install">Homebrew</a>
  · <a href="https://plainsay.app/">Website</a>
  · <a href="BENCHMARK.md">Benchmark</a>
</p>

<p align="center">
  <a href="https://github.com/conrader/plainsay/releases/latest"><img alt="Latest release" src="https://img.shields.io/github/v/release/conrader/plainsay?style=flat-square"></a>
  <a href="LICENSE"><img alt="MIT license" src="https://img.shields.io/github/license/conrader/plainsay?style=flat-square"></a>
  <img alt="macOS 14 or newer" src="https://img.shields.io/badge/macOS-14%2B-14161A?style=flat-square&logo=apple">
  <img alt="Apple silicon" src="https://img.shields.io/badge/Apple%20silicon-required-14161A?style=flat-square&logo=apple">
</p>

<p align="center">
  <a href="https://api.plainsay.app/releases/Plainsay-latest.dmg"><img src="docs/assets/social-preview.png" alt="Hold a key, speak, and release to put locally transcribed text at your cursor with Plainsay" width="820"></a>
</p>

<p align="center">
  <strong>12 MB native app · free Local mode · no account · no telemetry</strong>
</p>

Plainsay is free and MIT-licensed. With **Local transcription** and Polishing
off or running on your Mac, dictation audio is not uploaded, no account or
subscription is needed, and recognition works offline after the model download.
Automatic checks for signed updates are enabled by default and can be disabled
in Settings. Optional
Plainsay Cloud provides hosted transcription and Polishing for 12 PLN gross/month
(VAT included; about US$3); that mode sends recorded audio to the service and includes up to
900 transcription minutes in any rolling 30-day window.

> **Requirements:** macOS 14 or newer and an Apple-silicon Mac. The app is
> signed and notarized. Recommended multilingual models are separate one-time
> downloads of approximately 475–632 MB; smaller English-only options start at
> about 150 MB.

## Install

### Direct download

**[Download the latest notarized DMG](https://api.plainsay.app/releases/Plainsay-latest.dmg)**
and drag Plainsay to Applications. The stable link always points to the latest
release; the [release page](https://github.com/conrader/plainsay/releases/latest)
has checksums and release notes.

### Homebrew

```sh
brew install --cask conrader/plainsay/plainsay
```

Plainsay checks for signed updates automatically. You can also use **Check for
Updates…** from its menu-bar menu.

If Plainsay earns a place in your menu bar, **[star the repository](https://github.com/conrader/plainsay)**.
It is the simplest way to help more Mac users find the project.

## Why Plainsay?

- **Small, native Mac app.** The current notarized DMG is about 12 MB. Plainsay
  is written in Swift and stays out of the way in the menu bar.
- **Two genuinely local engines.** Choose Whisper through
  [WhisperKit](https://github.com/argmaxinc/WhisperKit) or multilingual NVIDIA
  Parakeet through [FluidAudio](https://github.com/FluidInference/FluidAudio).
- **Measured, not hand-waved.** The committed benchmark records every
  reference, hypothesis, and timing. On the benchmark machine and its disclosed
  50-clip English sample, prepared-model average latency was 0.10 s for Parakeet
  and 0.68 s for Whisper, with the first inference included.
- **Broad insertion support.** Plainsay uses the standard paste flow across
  many native apps, Electron apps, web views, and terminals, then attempts to
  restore the previous clipboard contents.
- **Safe fallback.** Polishing is optional and time-bounded. If it is disabled,
  offline, or fails, Plainsay continues with the raw transcript. If no safe
  paste target is found, the text stays on the clipboard.
- **Clear open-source boundary.** The Mac client code, benchmark harness, and
  release scripts are MIT-licensed and auditable; the committed LibriSpeech
  clips are CC BY 4.0. Plainsay Cloud is a separate optional hosted service.

## What leaves your Mac?

| Configuration | Recorded audio | Transcript text | Account | Cost |
|---|---|---|---|---|
| Local transcription, Polishing off or running on your Mac | Stays on your Mac | Stays on your Mac | No | Free |
| Local transcription + hosted Polishing | Stays on your Mac | Sent to the provider you select | Depends on provider | Depends on provider |
| Plainsay Cloud | Sent to Plainsay Cloud | Returned by Cloud; sent onward if Cloud Polishing is enabled | Yes | 12 PLN gross/month, VAT included (about US$3); 900 transcription minutes per rolling 30 days |
| Your own speech API | Sent directly to the provider you configure | Returned to Plainsay | Provider key | Provider pricing |

The hosted routes are explicit:

- **Your own provider:** audio, a language hint, and optional vocabulary prompt
  go directly to the speech endpoint you configure (Groq, deAPI, OpenAI, or a
  compatible custom service). Hosted Polishing sends transcript text and
  vocabulary terms directly to Google Gemini, Anthropic, OpenRouter, OpenAI,
  or the compatible endpoint you configure.
- **Plainsay Cloud:** encoded audio, clip duration, language, and an optional
  vocabulary prompt go to `api.plainsay.app`. Speech may be processed on a
  Plainsay-operated transcription node or forwarded to deAPI. If Cloud
  Polishing is enabled, transcript text and vocabulary terms are sent from
  Plainsay Cloud to OpenRouter, using its configured Gemini model.
- **Optional Voice Filter:** filtering runs on the Mac, but it is best-effort.
  If the filter is unavailable or fails, a hosted speech mode receives the
  unfiltered recording.

Plainsay Cloud's application database stores account, authentication,
subscription, and usage records: an email address and/or Apple account
identifier, session records, Stripe customer/subscription identifiers and
status, plus each operation's timestamp, type, audio duration, estimated cost,
and Polishing token counts. It deliberately stores neither recorded audio nor
transcript text. Stripe receives the account email and handles checkout and
payment details; Apple handles Apple sign-in, and the configured email-delivery
service receives the address and sign-in message.

API proxy access logging is disabled. Minimal application event logs contain
only the method, matched route template, status, and elapsed time; they exclude
network addresses, headers, query strings, and request bodies. Website and
signed-update delivery can still produce ordinary web-server access records.

Local mode does not mean the app never uses the network: the selected model
must be downloaded once, and the default update check contacts
`api.plainsay.app` (it can be switched off). The Mac client sends no analytics
or telemetry. On disk, Plainsay keeps up to 100 raw and final transcript records
for recovery and History until they are cleared or age out. Audio is staged in
an owner-only local folder while a dictation is processed and removed after a
successful or completed attempt; an interrupted recording can remain there for
recovery on the next launch. These files are excluded from backups.

API keys and the Plainsay Cloud session token are stored in macOS Keychain.
Local mode is the default choice on a new installation; cloud use requires an
explicit choice.

## First dictation

1. Choose **On this Mac** for Local mode, then pick the recommended model for
   your languages.
2. Grant Microphone, Accessibility, and Input Monitoring permissions. macOS
   may ask you to reopen the app after a new permission is granted.
3. Hold **Right Command**, speak, and release. Tap it once instead if you prefer
   toggle mode; tap again to stop.

Each dictation can run for up to 10 minutes. At the boundary, Plainsay stops
recording automatically, shows a notice, and processes the captured audio.

The shortcut, languages, vocabulary, model, and hold/toggle behavior can all be
changed later in Settings.

## How it works

```text
key down ──► remember frontmost app → show HUD → record 16 kHz mono audio
key up ────► transcribe locally, in Plainsay Cloud, or through your API
             optional Polishing (bounded timeout → raw-transcript fallback)
             snapshot clipboard → paste text → attempt clipboard restore
```

The local engines run as Core ML models accelerated on Apple silicon.
Polishing asks the selected model to turn spoken language into written language
while preserving wording, meaning, tone, and language; review important text.
It can use Plainsay Cloud, your provider, a compatible local endpoint, or
remain off.

Read [How it works](https://plainsay.app/how-it-works/) for the pipeline and
[Why on-device](https://plainsay.app/why-on-device/) for the privacy trade-offs.

## Reproducible benchmark

| Local engine | Word error rate | Average latency | Real-time factor |
|---|---:|---:|---:|
| Parakeet TDT 0.6B v3 | **2.50%** | **0.10 s** | 0.014 |
| Whisper large-v3-turbo | **2.89%** | **0.68 s** | 0.095 |

These are prepared-model results on a disclosed 50-utterance sample from
LibriSpeech `test-clean`; the first inference is included and no hidden
transcription warm-up is subtracted. They are not a claim about every language
or noisy real-world dictation. The exact Mac, source commit, dependency pins,
methodology, limitations, raw results, and one-command harness are in
[BENCHMARK.md](BENCHMARK.md).

## Screenshots

<table>
<tr>
<td width="50%"><a href="Screenshots/settings-speech.png"><img src="Screenshots/settings-speech.png" alt="Speech settings with local Parakeet ready"></a><br><sub>Local speech, languages, and Polishing</sub></td>
<td width="50%"><a href="Screenshots/settings-general.png"><img src="Screenshots/settings-general.png" alt="General settings with shortcut options"></a><br><sub>Interface language and shortcut behavior</sub></td>
</tr>
</table>

## Build and contribute

Bug reports, small fixes, tests, documentation improvements, and focused
feature proposals are welcome. Start with [CONTRIBUTING.md](CONTRIBUTING.md),
which covers the development build, tests, and how to propose a change.

```sh
swift build
swift test
```

For security issues, please follow [SECURITY.md](SECURITY.md) instead of
opening a public issue.

## Contact

- Bugs: [open an issue](https://github.com/conrader/plainsay/issues/new/choose)
- Ideas and questions: [GitHub Discussions](https://github.com/conrader/plainsay/discussions)
- Everything else: [hi@plainsay.app](mailto:hi@plainsay.app)
