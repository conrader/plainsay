# Plainsay launch pack

Internal working material. Nothing in this directory should be published
without a final product check and a human review from the person posting it.

## The launch position

> Hold a key, speak, and release. Plainsay is a 12 MB native Mac dictation
> client with free on-device Whisper and Parakeet, an auditable benchmark, and
> an optional hosted mode.

The order matters. Lead with the job and the proof, then explain the choices:

1. Text lands at the cursor after one press-and-hold interaction.
2. Local mode is the free default and needs no account.
3. The notarized native client DMG is about 12 MB.
4. Users can choose Whisper or Parakeet, and inspect the benchmark.
5. Plainsay Cloud is optional, sends recorded audio, and costs about $3/month.

Always qualify the size: local models are separate one-time downloads of
approximately 475–632 MB. Always qualify open source: the Mac client,
benchmark, and release tooling are MIT-licensed; the Plainsay Cloud backend is
not open source.

## What to borrow — and improve

The relevant open-source dictation projects make several repeatable choices:

| Observed pattern | What works | How Plainsay should improve it |
|---|---|---|
| FreeFlow puts a direct DMG near the top and follows it almost immediately with a GIF. | A visitor can understand and try the product before reading architecture. | Put the notarized download, Homebrew command, and one authentic 20–30 second demo above the detailed feature list. Pair the demo with exact requirements. |
| Handy, VoiceInk, OpenWhispr, FluidVoice, and similar projects lead with the visible user outcome. | “Press, speak, get text” is easier to grasp than a model or privacy taxonomy. | Show the cursor-level workflow first, then use engine choice, insertion reliability, and safe raw-text fallback as the technical proof. |
| “Free, local, open source” appears across the category. | It clears an important trust threshold. | Treat it as a requirement, not the headline. Differentiate with the 12 MB native client, two local engines, clear cloud boundary, and reproducible measurements. |
| Whispering's Show HN discussion exposed the risk of an unqualified “everything stays local” claim when cloud paths also exist. | The community actively checks privacy wording. | Name the mode in every privacy statement. Say what leaves the Mac in the same screen or paragraph in which Cloud is offered. |
| Many projects publish impressive speed or accuracy claims with little context. | Numbers attract technical users. | Lead with inspectable evidence and its limitations: 50 English LibriSpeech `test-clean` clips, warm models, clean read speech, and no claim about Polish or noisy real-world dictation. |

The better version is not louder copy. It is a shorter path from claim to
evidence: real recording, direct download, mode-specific privacy table,
reproducible benchmark, and source.

## Claims that are safe to use

- The notarized Mac client DMG is about 12 MB.
- Plainsay supports macOS 14 or newer on Apple silicon.
- Local mode is the default, free, and requires no account or subscription.
- Local transcription uses Whisper or NVIDIA Parakeet on the Mac.
- The published benchmark covers 50 English LibriSpeech `test-clean` clips.
- Plainsay Cloud is optional, sends recorded audio for hosted processing, and
  costs about $3/month.
- The Mac client is MIT-licensed. The Plainsay Cloud backend is separate and
  is not open source.

## Claims not to use

- “The entire product is open source.”
- “Audio never leaves your Mac,” without explicitly saying “in Local mode.”
- “12 MB total install,” because local model downloads are much larger.
- “The benchmark proves real-world, multilingual, or Polish accuracy.”
- “Fastest,” “most accurate,” or “better than Apple Dictation” without a fair,
  reproducible comparison.
- GitHub clones, server requests, or DMG requests described as confirmed
  installations. Bots and automated clients make those only rough proxies.

## Launch order

### 1. Truth and install gate

Do not begin public promotion until all of these are true:

- A new install presents Local mode as the default.
- Cloud is labeled as the fastest setup, not the recommended choice.
- Every public page uses mode-specific privacy language.
- Removed features, including live typing, are absent from launch copy.
- The direct DMG and Homebrew cask point to the current notarized release.
- The site and repository state macOS 14+ and Apple silicon before download.
- The public privacy policy and terms accurately name the operator and Cloud
  processors. Do not publish placeholder legal identity details.
- The authentic demo in `demo-storyboard.md` has been recorded and reviewed.

### 2. Ten-person dry run

Use `testers.md`. Fix any install blocker, data-loss issue, misleading privacy
interpretation, or repeated permissions confusion before promotion. Record the
build number tested; do not silently change it between the dry run and launch.

### 3. Make the repository convert

- Put the outcome, demo, direct DMG, Homebrew command, requirements, and Local
  privacy promise before the long explanation.
- Set the custom social image and verify the card in a real link preview.
- Publish release notes and checksums for the exact build used in the demo.
- Keep Issues and Discussions ready, with a short reproducible bug template.
- Make the star request contextual: ask only after the visitor has seen enough
  to decide whether the project is useful.

### 4. Launch one learning channel at a time

1. Post to r/macapps with `reddit.md`, from an account that satisfies the
   community's current participation rules. Treat it as product feedback.
2. Spend 24–48 hours fixing repeated friction and updating the FAQ.
3. Submit the technical story to Show HN with `show-hn.md` only when a maker
   can stay present and answer questions. Never coordinate votes or comments.
4. Use `product-hunt.md` after the demo and first-run flow have survived the
   earlier feedback. Product Hunt is the broader product story, not the place
   to introduce an untested onboarding path.

Re-check each community's current rules immediately before posting.

## What to measure

Take a baseline immediately before each post, then the same snapshot after 24
and 72 hours:

- GitHub stars and unique repository visitors;
- direct-download and release-asset requests, clearly labeled as download
  proxies rather than installations;
- completed tester installs and first dictations;
- issue/discussion volume, grouped by install, permissions, transcription,
  insertion, and trust;
- comments that repeat the same objection or confusion;
- paid Cloud trials and subscriptions, reported separately from Local use.

Do not blend the channels into one launch-day total. The useful question is
which message produced qualified repository visits, successful first
dictations, and retained users — not which page produced the largest raw
traffic spike.
