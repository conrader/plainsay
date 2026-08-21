# r/macapps launch draft

Internal draft. Re-check the subreddit's current self-promotion, account-age,
karma, title-tag, price-disclosure, privacy-policy, and terms requirements on
the day of posting. Do not use a new promotional-only account and do not ask
for votes.

## Title

> [OS] Plainsay — free local dictation with Whisper + Parakeet on Mac

## Post

Developer/self-promo disclosure: Plainsay is a native dictation app for
Apple-silicon Macs. Hold Right Command, speak, and release; the resulting text
is inserted at the current cursor.

Local mode is the default. It runs Whisper or NVIDIA Parakeet on the Mac, needs
no account or subscription, and is free. The notarized client DMG is about 12
MB, with a separate one-time model download of approximately 475–632 MB.

**Price:** Local mode is $0. Optional Plainsay Cloud is about $3/month, avoids
the model download, and sends recorded audio for hosted transcription and
Polishing.

**Privacy and source:** With Local transcription and Polishing off or local,
recorded audio and transcript stay on the Mac. The Mac client is MIT-licensed;
the Cloud backend is separate and is not open source. The repository has a
plain-language data-flow table.

**Requirements:** macOS 14 or newer, Apple silicon.

There is also a reproducible benchmark for both local engines. It is intentionally
narrow: 50 English LibriSpeech `test-clean` clips with warm models, so it is not
a claim about Polish, background noise, or everyday laptop-mic dictation.

- GitHub, source, and install: <https://github.com/conrader/plainsay>
- Direct notarized DMG: <https://api.plainsay.app/releases/Plainsay-latest.dmg>
- Benchmark: <https://github.com/conrader/plainsay/blob/main/BENCHMARK.md>

If you try one real dictation, where does the first-run flow still feel
confusing or untrustworthy?

## Reply policy

- Answer bugs and privacy questions with the exact mode and build involved.
- Acknowledge limitations without turning every reply into a sales pitch.
- Ask for reproducible details only when necessary; never request private audio
  or text in a public thread.
- Collect recurring issues in GitHub, but do not pressure commenters to move
  platforms merely to report a problem.
- Do not argue with comparisons to macOS Dictation or paid alternatives. State
  the concrete Plainsay trade-offs and invite a reproducible example.
