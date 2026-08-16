# Contributing

Most people want [the download](README.md#download), not this — this page is
for building Plainsay from source.

## Building from source

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

## Tests

```bash
swift test                                  # unit tests, no network, no model
PLAINSAY_INTEGRATION=1 swift test            # adds real Whisper transcription
PLAINSAY_PARAKEET_INTEGRATION=1 swift test   # adds real Polish + English Parakeet
```

The integration suites synthesize speech with `say`. The Whisper suite uses
the real 632 MB model; the Parakeet suite uses the roughly 475 MB model and
checks both a Polish and an English phrase.

NVIDIA Parakeet is licensed under CC BY 4.0. See
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for attribution and dependency
licenses.

Not covered by tests, because they need TCC grants and real hardware: the
`CGEventTap` hotkey, keystroke injection, and the permission prompts.
