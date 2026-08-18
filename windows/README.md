# Plainsay for Windows

Cloud-first push-to-talk dictation for Windows, speaking the same
`api.plainsay.app` API the Mac client uses. See [`PLAN.md`](PLAN.md)
for the stack decisions and why.

Status: early scaffold — cloud-first pipeline (hotkey → record → transcribe →
Polish → paste) and sign-in are wired up; on-device transcription, vocabulary,
and a real hotkey picker are not yet built. Icons are still the Tauri
template defaults, not Plainsay's.

## Develop

```bash
npm install
npm run tauri dev
```

## Build

```bash
npm run tauri build
```

Requires the Rust toolchain and, on Windows, the Visual Studio Build Tools
(C++ workload) for `link.exe`. CI builds this on `windows-latest` on every
push that touches this directory — see
`../.github/workflows/windows.yml`.

## Layout

- `src-tauri/src/audio.rs` — WASAPI capture (via `cpal`), resampling, WAV
  encoding.
- `src-tauri/src/cloud.rs` — the Plainsay Cloud API client (auth, billing,
  transcribe, cleanup), mirroring `PlainsayCloud.swift` /
  `CloudTranscriptionEngine.swift` / `CloudCleanupService.swift` on the Mac
  side.
- `src-tauri/src/hotkey.rs` — push-to-talk registration.
- `src-tauri/src/insertion.rs` — clipboard + `SendInput` paste.
- `src-tauri/src/lib.rs` — wires it all together: tray icon, the settings
  window, the HUD window, and the record→transcribe→clean→paste pipeline.
- `index.html` / `src/main.ts` — the settings/sign-in window.
- `hud.html` — the small always-on-top recording indicator.
