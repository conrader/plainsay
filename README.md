# Plainsay

[plainsay.app](https://plainsay.app) · On-device voice dictation for macOS. Hold a key, speak, release — cleaned-up
written text lands in whatever app you're using.

Transcription runs entirely on your Mac (Whisper via
[WhisperKit](https://github.com/argmaxinc/WhisperKit), CoreML + Neural Engine).
A Gemini Flash Lite pass then turns spoken language into written language:
filler words out, punctuation in, your wording intact.

## Build and run

```bash
INSTALL=1 ./Scripts/bundle.sh
open /Applications/Plainsay.app
```

Leave off `INSTALL=1` to build into `build/` without touching `/Applications`.

The bundle is not optional. macOS refuses microphone, accessibility, and input
monitoring access to a bare executable, so `swift run` produces an app that
cannot do anything.

`bundle.sh` signs with a Developer ID by default. Override it:

```bash
SIGN_IDENTITY="-" ./Scripts/bundle.sh   # ad-hoc
```

Ad-hoc signing works, but macOS keys permission grants to the signature, so
every rebuild asks for all three permissions again.

## First launch

1. **Grant three permissions** — Plainsay opens Settings › Permissions if any are
   missing. Microphone to hear you, Accessibility to paste, Input Monitoring to
   notice the hotkey while another app is focused. macOS only applies a new
   grant after a restart, so quit and reopen afterwards.
2. **Wait for the model** — 632 MB on first run, then cached. The menu bar says
   when it's ready.
3. **Add a Gemini key** in Settings › Cleanup. Get one at
   [aistudio.google.com](https://aistudio.google.com). It's stored in your
   Keychain. Without a key Plainsay still works — it inserts the raw transcript.

## Using it

Default hotkey is **Right ⌘**, in hybrid mode:

- **Hold** it and speak — recording ends when you let go.
- **Tap** it once — recording latches on; tap again to stop.

Settings › General switches to hold-only or toggle-only if the hybrid behavior
gets in your way.

Add names and jargon under Settings › Speech › Vocabulary. Terms go to the
speech model as decoder conditioning *and* to the cleanup prompt, so mangled
spellings get two chances to come out right.

## How it works

```
key down ──► capture frontmost app, show HUD, start recording
             AVAudioEngine → 16kHz mono float, lock-free ring buffer
key up ────► stop, discard anything under 300ms
             WhisperKit transcribe (vocabulary as decoder prompt)
             Gemini cleanup (3s timeout → falls back to raw transcript)
             pasteboard snapshot → set text → ⌘V → restore snapshot
```

Cleanup is best-effort by design. No key, no network, a timeout, an HTTP error
— you still get the raw transcript, and the HUD says it fell back. A dictation
is never lost to a failed API call.

Text is inserted by pasting rather than through the Accessibility API, which
fails silently in Electron apps, web views, and terminals. Your clipboard is
snapshotted and restored around the paste.

### Layout

- `Sources/PlainsayCore` — the pipeline. No UI, unit-testable.
- `Sources/PlainsayApp` — menu bar, HUD panel, settings.
- `docs/superpowers/specs/` — design document.

`TranscriptionEngine` and `TextCleaning` are protocols, so swapping WhisperKit
for whisper.cpp, or Gemini for a local model, doesn't touch the pipeline.

## Tests

```bash
swift test                              # 40 unit tests, no network, no model
PLAINSAY_INTEGRATION=1 swift test           # adds real-model transcription
```

The integration suite synthesizes speech with `say` and runs it through the
real 632 MB model, so it needs the model on disk and takes a few seconds.

Not covered by tests, because they need TCC grants and real hardware: the
`CGEventTap` hotkey, keystroke injection, and the permission prompts.
