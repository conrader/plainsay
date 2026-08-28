# Plainsay for Windows — plan

Decisions below are settled; this file is the durable record so they don't
have to be re-derived or re-asked. Update it as reality changes instead of
letting it drift out of sync with the code.

## Scope and sequencing

1. **Cloud-first shell.** Reuses `api.plainsay.app` as-is (already
   platform-neutral). No on-device model, no download, no CoreML/ANE
   equivalent to build — just hotkey → record → upload → paste. This is the
   fastest path to a real, usable Windows build.
2. **On-device as a second mode on the same shell**, added after the
   cloud-first path works end to end. Mirrors the Mac split: Cloud is the
   convenience/default door, on-device is the privacy wedge.
3. **Guardrail: this must never delay the Mac.** Mac is still the actual
   demand-validation and star-count unlock. Windows work stops immediately if
   it starts eating into that.

Same repo as the Mac client — a `windows/` directory, not a separate repo.
The project is a few days old with 1 star; splitting into two repos now
fragments a community that doesn't exist yet.

## Shell: Tauri

Rust core (audio, hotkey, tray, upload) + a WebView2 window for the HUD.
[cjpais/Handy](https://github.com/cjpais/Handy) (29.8k stars, MIT, Tauri,
Mac+Windows dictation) is a direct working template — steal its shape before
inventing one.

The alternative considered and rejected for now: pure Rust native (windows-rs
+ winit/tao, no webview at all) — lighter idle footprint and no WebView2
Evergreen update-treadmill risk on a days-resident process, but no reference
implementation exists for the hand-rolled overlay this would need. Revisit
this only if WebView2 actually causes a real stability problem in practice —
don't pre-optimize for it.

## Concrete build shape

- **Hotkey / push-to-talk**: native `WH_KEYBOARD_LL` hook for Right Ctrl.
  `RegisterHotKey` cannot register a modifier-only key, and the original
  `global-hotkey` scaffold therefore never started. The hook callback only
  posts deduplicated press/release events to a bounded channel and returns
  immediately — Windows silently unhooks callbacks that block past its
  watchdog. If a configurable multi-key shortcut is added later, Tauri's
  global-shortcut plugin can handle that separate path.
- **Audio capture (WASAPI)**: `cpal` — the de facto Rust choice, used by
  every precedent found (Handy, opentypeless, SpeakoFlow, ContextFlow).
- **Tray icon**: `tauri-apps/tray-icon`.
- **Text insertion**: clipboard write + simulated `Ctrl+V` via `SendInput`.
  Windows has no clean "insert text" API — UI Automation's `TextPattern`
  can't insert. Known nasty edges, budget real time for them (this is a
  Windows re-run of the same edge-case catalogue the Mac build already hit):
  - UAC-elevated target windows block synthetic input from a non-elevated
    process by design (UIPI) — there is no clean workaround, only detection
    and a clear failure message.
  - Some apps swallow paste outright. The Windows client deliberately leaves
    every transcript on the clipboard, so a manual `Ctrl+V` remains available
    even when `SendInput` cannot prove the target consumed its events.
  - Terminal-aware newline handling — an inserted raw newline can trigger
    command execution in a shell. Flatten/escape before paste there.
- **Cloud upload**: Media Foundation AAC in an M4A container, sent by plain
  HTTPS POST to `api.plainsay.app/v1/transcribe`, followed by `/v1/cleanup`
  from the Rust process. Private metadata lives in the redacted
  `X-Plainsay-Metadata` header, matching the current Mac contract.
- **On-device (phase 2)**: `sherpa-onnx`'s official Rust binding for
  Parakeet (first choice — smaller model footprint), `whisper-rs`
  (whisper.cpp) as the alternate/fallback engine. CPU-only is viable for
  short (3–8s) clips with base/small-class Whisper models plus a short-clip
  optimization (trim `audio_ctx` to the real clip length instead of the
  default 30s window — whisper.cpp #1855, ~3× measured speedup; this is a
  DIY optimization, not a runtime default). Medium/large Whisper is NOT
  CPU-viable for an instant feel. NPU acceleration only exists on newer
  Copilot+ PCs — still a minority of the install base, so on-device
  quality/latency will genuinely vary machine-to-machine in a way it never
  does on Mac. That's an accepted support cost, not a blocker, and is
  exactly why cloud stays the Windows default.

## ASR model (applies to the on-device phase, matches Mac)

Default **parakeet-tdt-0.6b-v3**, fallback **whisper-large-v3-turbo** — same
choice the Mac client already ships and recommends. Decided on:

- **Speed** (measured on Konrad's own Mac, the decisive factor for
  hold-to-talk perceived latency): Parakeet is much faster — it's a
  transducer (one forward pass) vs. Whisper's autoregressive decoding.
- **Hallucination-resistance**: Whisper is documented to hallucinate during
  silence on exactly this UX (short clips, silence-padded edges). A
  hallucinated sentence gets smoothed into something plausible-but-wrong by
  the LLM cleanup pass afterward — worse than an ordinary WER error, which
  the cleanup pass visibly fixes. Parakeet structurally resists this.
- **Not** a clean accuracy win — worth knowing, not overclaiming: on
  FLEURS-Polish, Whisper-large-v3 actually wins (4.74% WER vs Parakeet-v3's
  ~6–7%). Parakeet wins on MLS-Polish (7.28% vs 8.88%). Polish accuracy is
  genuinely mixed and benchmark-dependent; the case for Parakeet rests on
  speed + hallucination-resistance, not a demonstrated Polish-accuracy edge.

## Distribution

- **Auto-update**: Velopack.
- **Code signing / SmartScreen**: a brand-new signed binary still has zero
  reputation at launch — expect an "unknown publisher" warning regardless of
  signing tier (EV certs stopped bypassing SmartScreen in 2024). Azure
  Trusted Signing (~$9.99/mo) is the cheap option; budget for the cold-start
  warning existing anyway and message around it rather than expecting a
  signing purchase to remove it.

## Positioning

Per-platform honesty, not a unified pitch:
- **Mac**: on-device by default — the flagship privacy experience.
- **Windows Cloud**: convenience + zero-retention (the Cloud tier already
  stores neither audio nor transcripts, only elapsed seconds for metering —
  same true claim as the Mac Cloud plan).
- **Windows on-device**: the full privacy wedge, opt-in.

One honest story, three doors, framed by platform rather than overclaiming
uniform on-device support everywhere.

## Sources

Full research behind these decisions lives on the Second Brain wiki:
`plainsay-windows-stack-2026-08`, `plainsay-windows-roadmap-2026-08`,
`plainsay-best-asr-model-2026-08`. This file is the distilled, actionable
version — check the wiki pages for the full evidence trail and confidence
caveats behind any specific number above.
