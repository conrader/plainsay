# Plainsay — On-Device Voice Dictation for macOS

**Date:** 2026-08-15
**Status:** Approved, in implementation

## Purpose

A Wispr Flow-style dictation tool: hold a hotkey, speak, release, and cleaned-up
written text appears in whatever app is focused. Transcription runs on-device.
A cloud LLM pass turns spoken language into written language.

## Non-goals (v1)

- App-aware cleanup profiles (varying tone by frontmost app)
- Transcript history window
- iOS, Windows, or Linux support
- Streaming/partial transcription during recording

## Stack

- Swift 6.3, SwiftUI + AppKit, macOS 26+
- **ASR:** WhisperKit (on-device Whisper, CoreML, ANE+GPU), behind a
  `TranscriptionEngine` protocol so whisper.cpp can be swapped in later
- **Cleanup:** Gemini `gemini-3.1-flash-lite` over REST
  ($0.25/$1.50 per M tokens ≈ $0.0004 per dictation)

### Why WhisperKit over raw whisper.cpp

whisper.cpp's SwiftPM package (`whisper.spm`) has unresolved Metal support and
requires a `master`-branch dependency with unsafe build flags. WhisperKit runs
the same Whisper models with pre-converted CoreML weights, ANE acceleration, and
a native async Swift API. The `TranscriptionEngine` protocol keeps the decision
reversible.

## Architecture

Menu-bar-only app (`LSUIElement`). Two modules:

- **`PlainsayCore`** — SwiftPM library. Logic, no UI. Unit-testable via `swift test`.
- **`PlainsayApp`** — executable. Menu bar, HUD panel, settings, permissions.

### Components

| Component | Responsibility | Requires |
|---|---|---|
| `HotkeyMonitor` | `CGEventTap` → `.pressStart` / `.pressEnd` / `.tap` | Input Monitoring |
| `HotkeyStateMachine` | hold-vs-tap disambiguation (pure, testable) | — |
| `AudioRecorder` | `AVAudioEngine` → 16kHz mono Float32 + RMS level | Microphone |
| `TranscriptionEngine` | protocol; `WhisperKitEngine` is impl #1 | — |
| `CleanupService` | Gemini REST call, 3s timeout | Keychain API key |
| `TermDictionary` | user terms → ASR prompt + cleanup prompt | — |
| `TextInserter` | pasteboard save → set → ⌘V → restore | Accessibility |
| `HUDController` | non-activating `NSPanel` | — |
| `DictationCoordinator` | owns the state machine, wires everything | all |

### Two load-bearing decisions

**Hold and toggle from one binding.** One hotkey, 250ms threshold. Released
under 250ms → latched toggle (tap again to stop). Held past it → push-to-talk,
ends on release. Settings can force either mode.

**The HUD must never take focus.** If the panel activates, the target app
resigns first responder and the paste lands nowhere. Hence
`.nonactivatingPanel`, `ignoresMouseEvents = true`, `canJoinAllSpaces`. The
frontmost app is captured at *press* time, not insertion time.

## Data flow

```
key down ──► HotkeyMonitor.pressStart
             ├─► capture frontmost app (NSWorkspace)
             ├─► HUDController.show(.recording)
             └─► AudioRecorder.start()
                    │  tap (realtime thread, no alloc, no locks)
                    │  hardware fmt ──AVAudioConverter──► 16kHz mono f32
                    │  ├─► append to preallocated ring buffer
                    │  └─► RMS ──► HUD level meter (throttled 30fps)
key up ────► HotkeyMonitor.pressEnd
             ├─► AudioRecorder.stop() ──► [Float]
             ├─► guard duration > 300ms ─── else discard silently
             ├─► HUD → .transcribing
             ├─► await engine.transcribe(samples, prompt: dictionary.asrPrompt)
             ├─► guard non-empty, not "[BLANK_AUDIO]" ─── else discard silently
             ├─► HUD → .cleaning
             ├─► await CleanupService.clean(raw, terms:)  // 3s timeout → raw
             ├─► TextInserter.insert(text, into: capturedApp)
             └─► HUD.dismiss()
```

Swift 6 strict concurrency: `@MainActor` for UI, `actor` for the engine,
`Sendable` payloads across boundaries.

### Text insertion: pasteboard, not Accessibility API

`AXUIElement` text insertion fails silently in Electron apps, web views, and
terminals. Instead: snapshot every pasteboard type → write cleaned text →
synthetic ⌘V via `CGEvent` → restore snapshot after 150ms.

### The cleanup pass

`POST generativelanguage.googleapis.com/v1beta/models/gemini-3.1-flash-lite:generateContent`,
key from Keychain, `temperature: 0`, minimal thinking budget.

System instruction does four things: strip fillers/stutters/false starts, fix
punctuation and casing, correct mangled dictionary terms, change nothing else.

**Prompt injection is the expected failure mode here** — the model starts
*answering* the transcript instead of *rewriting* it. The transcript is passed
as clearly delimited data with an explicit instruction that it is never a
request, and the output is only rewritten text.

The dictionary is used twice: as WhisperKit's `initial_prompt` to bias decoding,
and in the cleanup prompt to repair what slips through.

## Error handling

| Condition | Behavior |
|---|---|
| Missing mic/accessibility/input-monitoring permission | HUD error, open onboarding |
| Model not downloaded | Prompt download, block dictation until ready |
| Recording < 300ms | Discard silently (accidental tap) |
| Empty or `[BLANK_AUDIO]` transcript | Discard silently, no paste |
| Cleanup fails: no key, timeout, HTTP error | **Insert raw transcript**, badge HUD |
| Frontmost app changed during dictation | Paste anyway, log it |

Cleanup never loses a dictation. That fallback is the difference between a tool
you trust and one you don't.

## Latency budget

~10s of speech on Apple Silicon: WhisperKit 0.5–1s, Gemini 0.3–0.6s, paste
instant → **~1–2s after release**. Model loads once at launch and stays
resident; a cold load per dictation would add a second and ruin the feel.

## Testing

Unit-testable in `PlainsayCore`:
- `HotkeyStateMachine` — hold vs tap, threshold edges, toggle latch
- `TermDictionary` — prompt construction
- `CleanupService` — against mocked `URLProtocol`; timeout and fallback paths
- `TextInserter` — pasteboard save/restore round-trip
- `DictationCoordinator` — full pipeline with fake engine + fake cleanup

Not unit-testable (manual checklist): `CGEventTap`, real keystroke injection,
TCC permission prompts.

## Build

SwiftPM package; `Scripts/bundle.sh` assembles `Plainsay.app` with `Info.plist` and
ad-hoc codesigns it. TCC requires a bundled, signed app — running the bare
executable will not get microphone or accessibility permission.
