# Contributing

Thanks for helping make Plainsay better. Bug fixes, focused features, tests,
documentation, translations, and reproducible performance work are welcome.

## Before you start

- Search existing [issues](https://github.com/conrader/plainsay/issues) and
  [discussions](https://github.com/conrader/plainsay/discussions) first.
- Use an issue for a reproducible bug. Use a discussion for an idea, question,
  or change whose shape is not clear yet.
- For a large feature or architectural change, agree on the problem and scope
  before investing in a pull request. Small, reviewable changes are much easier
  to merge.
- Never include API keys, account tokens, private dictation text, or recordings
  in an issue, log, fixture, or screenshot.

## Building from source

You need an Apple-silicon Mac running macOS 14 or newer, plus Xcode 16 / Swift
6 command-line tools or newer. Contributor builds should use ad-hoc signing:

```bash
SIGN_IDENTITY="-" INSTALL=1 ./Scripts/bundle.sh
open /Applications/Plainsay.app
```

Leave off `INSTALL=1` to build into `build/` without touching `/Applications`.

The bundle is not optional. macOS refuses microphone, accessibility, and input
monitoring access to a bare executable, so `swift run` produces an app that
cannot do anything.

`bundle.sh` signs with the maintainer's Developer ID by default for release
builds. If you only want the bundle without installing it:

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

## Pull requests

Keep each pull request focused on one outcome. In its description, include:

1. The user-visible problem and the chosen behavior.
2. The tests you ran, including any manual macOS checks.
3. Screenshots or a short recording for visible UI changes.
4. Any effect on audio, transcript, account, network, or Keychain data flow.

Before opening the pull request:

```bash
swift build
swift test
git diff --check
```

GitHub Actions runs the build and unit suite on macOS 15. Review may ask for a
clean-install check when a change touches onboarding, permissions, signing,
updates, or model downloads.

## UI copy and localization

User-facing app strings belong in the string catalogs rather than being
duplicated per view. English is the source language. A copy change that affects
privacy or pricing should say exactly which mode it describes — Local,
Plainsay Cloud, or a provider configured by the user.

Website copy follows the same rule. If an English homepage claim changes,
check every localized homepage for the equivalent claim.

## Reporting security issues

Please do not open a public issue for a vulnerability. Follow
[SECURITY.md](SECURITY.md) instead.
