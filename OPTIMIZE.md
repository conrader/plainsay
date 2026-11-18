# Plainsay optimisation audit — 2026-11-11

Four small improvements are committed locally. No runtime benchmark, Swift build, Mac test, signing, or CI execution was possible here. Expected gains below come from source inspection, not measured speedups. No app behaviour change is intended. **CI behaviour changes:** superseded runs for the same PR/workflow are cancelled; every distinct main push and manual run retains its own group.

## Scope and local delivery

Audited these exact trees, including the performance-relevant differences between them:

- Base: `ed9ded1c36998241bba834f81ce74f49234f32ab`.
- Comparison: `b4851b93725c9dd432ba59701cdfa0ec7bcdb344`.
- Comparison: `c4c6dbd8a790ada963c34fb00e1b3b8b27f39791`.

The supplied checkout started on `main` at `6a6b000`, with an untracked `brief.md`. Its `.git` directory is mounted read-only: `git switch -c opt/astra-20261111 ed9ded1` failed to create `.git/index.lock`. Consequently the requested branch and commits live in an isolated local clone:

- Checkout: `/tmp/plainsay-astra-20261111`.
- Branch: `opt/astra-20261111`, created directly from `ed9ded1`.
- Durable delivery: `astra-20261111.bundle` beside this report in `/root/work/Plainsay/astra-optimize`. It contains only the new branch history after the base; an importing repository must already contain `ed9ded1`.
- Original tracked files, branch and `brief.md` were preserved. The root report is a copy of the committed audit, with a delivery receipt appended after that commit.
- Local commit identity: `Codex <codex@localhost>` because no identity was configured. The clone's push URL is also `DISABLED`.

Nothing was pushed, published, deployed, or sent to anyone. No service was contacted and no credentials were read. The clone source was the local repository. Release/deployment scripts were inspected as text only.

To inspect the local work:

```sh
git -C /tmp/plainsay-astra-20261111 log --oneline ed9ded1..opt/astra-20261111
git -C /tmp/plainsay-astra-20261111 diff ed9ded1..opt/astra-20261111
```

On a Mac, in a writable Plainsay repository containing the base, import the delivered bundle locally and create an isolated worktree (choose unused branch/directory names if needed):

```sh
git bundle verify /path/to/astra-20261111.bundle
git fetch /path/to/astra-20261111.bundle opt/astra-20261111:opt/astra-20261111
git worktree add ../plainsay-astra opt/astra-20261111
```

## Ranking: changes and recommendations

Rank reflects potential benefit and practical priority, not measured latency. Gain is workload-dependent; effort S/M/L means small/medium/large implementation plus validation work. Risk includes correctness, privacy and lifecycle changes. “Deferred” means no implementation in this branch.

| Rank | Item and status | Expected gain | Risk | Effort |
| --- | --- | --- | --- | --- |
| 1 | **Deferred:** redesign full-recording live preview scheduling | Potentially high CPU/energy and final-transcript latency benefit on long clips | High: context, cancellation, backend reentrancy and final-ASR priority | L |
| 2 | **Deferred:** defer the unused enrollment recorder until enrollment starts | Avoid eager allocation/initialization of a second 38.4 MB sample buffer; startup benefit needs measurement | Medium: initialization timing, device observers, first-use latency | M |
| 3 | **Changed:** bounded tail-grace snapshots (`745baca`) | Copy at most 22,404 bytes per check instead of the entire recording, up to 38,400,000 bytes | Low; window boundary explicitly preserved | S |
| 4 | **Deferred:** decouple local model preparation from Cloud account refresh where policy permits | Potentially high local readiness benefit on slow/offline networks for Cloud-dependent settings | Medium/high: entitlement, profile and credential readiness | M |
| 5 | **Deferred:** cache Swift dependencies/build artifacts with explicit toolchain keys | Potentially high repeated CI build savings; archive overhead can offset this | Medium: stale/incompatible artifacts and cache size | M |
| 6 | **Changed:** cancel superseded PR jobs (`642fde3`) | Avoid obsolete macOS/Windows runner work when PR runs overlap | Low; explicit CI behaviour flag | S |
| 7 | **Deferred:** move recovery/history disk work off the main actor while retaining ordering | Potentially medium UI responsiveness and startup benefit; disk latency still exists | High: durability, Clear/off races, privacy, recovery ordering | L |
| 8 | **Changed:** swap edit-distance row buffers (`6fd2985`) | Fewer row allocations/copies during fuzzy dictionary matching | Low; same recurrence and matching | S |
| 9 | **Deferred:** cache prepared vocabulary/rules per immutable session and reuse folded text windows | Medium for large dictionaries/rule sets; little benefit for small ones | Medium: Unicode semantics, invalidation and retired-rule retention | M |
| 10 | **Deferred:** profile upload encoding/multipart copies and use bounded/streamed construction | Medium for long remote dictations; network may dominate | Medium/high: endpoint compatibility, cancellation and temp-file lifetime | M/L |
| 11 | **Deferred:** audit release Mach-O/framework size, then consider symbol stripping or dependency split | Unknown until built artifact breakdown; potentially meaningful | Medium/high: crash symbols, signing, runtime resources, available engines | M/L |
| 12 | **Changed:** reuse SwiftPM output-path lookup (`99b9279`) | Small bundle-script overhead reduction: one fewer SwiftPM process | Low | S |
| 13 | **Deferred:** reduce repeated localization lookup and HUD work only if profiling warrants it | Likely small relative to ASR; could matter at meter cadence | Medium: language changes, concurrency, observation lifetime | M |

## Exact local improvement commits

Each commit message includes expected gain, behaviour flags and a Mac measurement procedure.

| Commit | Change | Behaviour flag |
| --- | --- | --- |
| `745bacacc655f0db6f6f155335b38baf793aaf55` | Tail-grace snapshot bound | No app behaviour change intended |
| `6fd29859b8fd082e3ddccdcd8ed0ae3a9b47f2d8` | Reuse edit-distance rows | No app behaviour change intended |
| `99b927914ca2d1c832852f66ead6dddbc31e79e0` | Reuse build output directory | No app behaviour change intended |
| `642fde32633251fa2d2560ef2d70f2769d9c1e15` | PR workflow concurrency | **CI:** obsolete PR runs cancelled; app unchanged |

The audit itself is committed separately. Its SHA is in the delivery receipt in the workdir-root copy and is the tip shown by `git log -1 opt/astra-20261111` in the delivered bundle.

### Tail-grace snapshots

Evidence: `AudioSampleSink.drain`, `AudioRecorder.endedMidSpeech`, and `DictationCoordinator.endRecordingAfterTail`. The baseline calls `recorder.peek()` at hotkey release and each 50 ms grace poll, copying the entire sample prefix merely to scan its last 0.35 seconds. Grace remains bounded by the existing 600 ms deadline.

The new `drain(last:)` snapshots the write index under the same lock and copies only a bounded suffix after releasing it. This retains the existing append-only storage invariant: the producer only writes beyond the published prefix; reset must not race a reader. The public `AudioRecording.isEndingMidSpeech` requirement has a compatibility default using the existing full peek. The production recorder overrides it with a bounded snapshot.

The read retains **5,601** samples, not 5,600: the existing detector returns false when the total sample count is *less than or equal to* the 5,600-sample window. Keeping the extra sample preserves that strict boundary. Thresholds, grace polling, final audio, preview input, recovery and the 10-minute limit are unchanged. There is no claim of faster ASR or a smaller persistent capture buffer.

Calculated bounds: 600 × 16,000 × 4 = **38,400,000 bytes** for a full maximum-length Float32 snapshot; 5,601 × 4 = **22,404 bytes** for a bounded one. These are copied payload sizes, not measured RSS or benchmark results.

Mac measurement: use release builds before/after this commit, preview initially off, and fixed 5-second, 60-second and near-10-minute captures. Instruments Allocations should identify the tail snapshot sizes; Time Profiler should compare main-thread copy work. Time hotkey release → recorder stop separately from recorder stop → inserted text. Repeat with preview on and test quiet tails, speech at release, short clips, exact-window clips, capacity stop and cancellation. Run the added sink/tail tests, plus the full pipeline suite. A microphone/device test is still necessary even after unit tests pass.

### Dictionary row reuse

Evidence: `TermDictionary.levenshteinDistance`. Assigning `previous = current` shares Swift array storage; the next write to `current[0]` can force a row copy. Swapping the two arrays reuses both buffers. Every cell is overwritten in the same left-to-right order before use. Complexity remains O(m × n); candidate ordering, tie-breaking, Unicode `Character` comparison and allowable edit distances stay unchanged.

Mac measurement: run `swift test --filter TermDictionaryTests`, then the full suite. In a release harness call `applyCorrections` on fixed short and long transcripts with 1, 50 and 200 terms, recording output equality, median time and allocation counts against the parent. Instruments should show whether row allocation savings survive optimizer decisions. No speedup percentage is asserted.

### Build output-path reuse

Evidence: `Scripts/bundle.sh` ran a real product build, one `--show-bin-path` query for the executable, then another query for Sparkle. Both now use the first resolved directory. Three Swift invocations become two; this removes a path-query process, **not an entire compilation**.

Mac measurement: compare warm debug and release bundling with `INSTALL=0`, the same signing setup and the same dependencies. Time total assembly and inspect the binary/framework paths, compiled localizations and `codesign --verify --deep --strict build/Plainsay.app`. Compare artifact contents and sizes; signing timestamps can differ. No application installation, release script or upload is needed.

### PR concurrency

Evidence: both `.github/workflows/ci.yml` and `windows.yml` lacked concurrency groups. Groups now include workflow, event, and either PR number or run ID. Only runs of the same workflow for the same PR share a group. Main pushes and manual dispatches have unique IDs; Windows path filters, build/test commands and artifact upload remain unchanged.

**CI behaviour change:** the prior PR run can be cancelled mid-build or test; its results/artifact may be incomplete. Re-running an old PR run can also supersede a newer one because grouping is by PR, not commit ancestry. This does not change the app or remove any test coverage from the surviving run.

Mac measurement: local `swift build && swift test` retains existing coverage. CI savings cannot be established on a Mac alone: in a later authorized CI trial, compare runner-minutes and latest-commit completion for two rapid updates of one PR, separate PRs, separate main pushes and Windows manual runs. No workflow was triggered during this audit.

## Runtime audit and deferred work

### Startup and ready-to-dictate time

`AppModel.shared` constructs both `VoiceEnrollment()` and a coordinator whose default recorder is `AudioRecorder()`. Each recorder eagerly creates an `AudioSampleSink(seconds: 600)` and zero-initializes 9.6 million Floats. This is **76.8 MB of buffer payload across two recorders**, before ASR/voice-filter models or transient copies. Actual resident memory depends on the allocator/OS and must be measured. Settings/HUD windows themselves are already constructed on demand; making their controller references lazy offers little by comparison.

First candidate: keep the enrollment object/progress state long-lived but create its capture recorder only on enrollment. Check fake-recorder injection, device changes before first enrollment, microphone permission handling, first-use latency and repeated open/cancel/start cycles before accepting it. Do not remove sink initialization or allocate/grow memory on the realtime callback as a casual alternative.

`DictationCoordinator.start` prunes pending audio before suspension, starts hotkeys, awaits `reloadModel`, then voice-filter preparation and interrupted-audio recovery. Model readiness is reported before those last tasks finish, so “start returned” and “dictation ready” are different milestones. `performModelReload` refreshes the Cloud account before constructing the engine when `needsCloudAccount` and sign-in state require it. This includes certain local-speech configurations using Cloud polishing, email/translation or profiles. Parallel local preparation is promising but needs explicit readiness/entitlement semantics; changing it silently risks a first dictation with different cleanup behaviour.

WhisperKit preparation downloads/resolves the cache, verifies model digests, then prewarms and loads. Parakeet also verifies before loading its int8 encoder/models. Startup profiling should separate filesystem/hash work, model compilation/warmup, network account refresh and disk recovery. **Do not skip model verification or prewarming without an explicit design decision**: skipping verification changes trust; removing prewarming can merely move delay to the first dictation. Hash-cache proposals need a tamper-resistant invalidation design, not an mtime shortcut. Incremental git-blob SHA1 framing would avoid the current temporary concatenation in `ModelIntegrity.digest`, but expected benefit is small for metadata files; measure actual pinned-file sizes first.

Mac measurement: record process launch → menu visible → model ready → first complete dictation, with first run, cached-model cold launch and warm relaunch separate. Use Instruments Time Profiler, Allocations/VM Tracker and File Activity. Compare signed-out local, signed-in local with Cloud-dependent settings, remote ASR, voice-filter enabled/disabled, and 0 versus 20 pending recordings. Use temporary test data, not personal transcripts. Record hardware, memory, macOS, Xcode/Swift, power mode and model/cache state.

### Dictation latency, CPU and memory

The path is: hotkey/target capture → microphone capture and optional preview → conditional tail grace → stop/full snapshot → synchronous recovery-file staging (standard sessions) → optional voice filtering → final ASR → dictionary corrections → optional network polishing → replacement rules → sanitize/history → target reacquisition/paste → clipboard restoration/outcome bookkeeping.

`startLivePreview` repeatedly copies and transcribes the entire growing recording. Its delay is clamped between 400 and 2,000 ms based on the last pass duration. The comment about approximately half duty ceases to hold when a pass exceeds the 2-second maximum delay. Cancellation need not interrupt model work. Engine actors have `await` points, so the comment that actors serialize whole async transcriptions is not proof that preview/final work cannot overlap: verify the backend scheduling and reentrancy before changing it. A bounded preview window, a larger adaptive delay or a priority/cancellation gate could help, but could change preview context/accuracy or model lifecycle safety. Keep final ASR based on the complete recording.

Mac measurement: identical recordings at 5/30/120/near-600 seconds, preview off/on, both engines. Compare CPU/energy, allocation peaks, number and duration of preview passes, final-ASR start delay, hotkey release → visible text, and transcript quality. Use controlled local audio and compare final words, not just speed. The existing BenchmarkCLI is useful for engine-only latency/WER; it preloads clips, excludes preparation from per-clip timings, and does not cover preview, hotkeys, cleanup or paste.

`PendingAudioStore.save` creates a full `Data` copy and writes/protects it synchronously before ASR; `TranscriptHistory` encodes/writes history before insertion, with another write possible on outcome change. Moving these to a serial I/O owner could improve UI responsiveness but must preserve save-before-paste, privacy policy, Clear/off ordering and recovery. Do not remove or delay persistence solely to improve a latency number. Mac validation needs long recordings, failure injection, concurrent Clear/off, restart recovery, and File Activity traces.

Remote engines encode audio and construct multipart data. AAC additionally makes a PCM buffer, writes a temporary file and reads it back. WAV already reserves its final capacity. Streaming/chunked upload construction may reduce peaks but needs endpoint-compatibility checks, output equivalence, cancellation and file-lifetime tests. Keep defaults unchanged: format choices are provider-specific. Measure encoding, body construction, upload bytes/time and server/cleanup response separately with URLSession metrics and Instruments; use controlled fixtures and an explicitly authorized endpoint.

`TextInserter` deliberately waits 20 ms before paste and 600 ms before restoring the clipboard. The latter is not necessarily 600 ms until text becomes visible. Target reacquisition and AX calls add separate costs. Shortening these waits risks pasting stale contents in busy apps. Measure visible insertion separately from pipeline completion across native editors, browsers and Electron, including large clipboard payloads and focus changes; retain existing waits in this branch.

The 120-element level history shifts at about 30 Hz, and SwiftUI/observation may allocate around it. Profile before introducing a ring buffer or changing frame rate. Inspect cancelled HUD observation tasks waiting on continuations in repeated recording cycles if memory grows. Those lifecycle changes need separate tests.

### Text processing

`ReplacementRuleSet.apply` creates a new `ReplacementMatcher` per call. The base already has optimized scanning, memoized match identification and forward output construction, with reference/corpus/Unicode tests and an existing performance test. Do not replace its ICU semantics or treat historical numbers in `Benchmark/REPLACEMENT_RULES_PERF.md` as measurements of this audit. A cache tied to immutable rule/session identity might help, but must be invalidated on edits and respect retired-target lifetime/privacy.

`TermDictionary.applyCorrections` rebuilds candidates and repeatedly folds overlapping token windows for each candidate. After row reuse, consider per-call folded-window caching, prepared candidate lengths and a bounded-distance algorithm. Preserve full candidate scoring, tie order and Unicode behaviour; early exit on the first plausible term changes text. `StructuredDetails.spans` compiles a constant regex per call; sharing it requires checking Swift 6 concurrency support on the actual Mac toolchain. Localization also repeats language/bundle lookup; preserve dynamic override, fallback language and plural locale if caching.

Mac measurement: fixed dictionary/rule corpora, exact output comparisons, the existing `ReplacementRulesPerfTests` in debug and release run separately, Unicode/reference tests, and Instruments allocation/time traces. Profile UI with language changes and HUD active before caching localization. Keep all caches bounded and avoid retaining retired private text indefinitely.

## App bundle, builds and CI

`Package.swift` links WhisperKit and FluidAudio through `PlainsayCore`; the app also links Sparkle. The bundle script already builds only `PlainsayApp`, compiles the two string catalogs to `.lproj` tables and copies specific licenses and Sparkle. Benchmark audio, screenshots, CLI/server executables, source catalogs and downloaded speech weights are **not explicitly copied into the shipped app by that script**. Deleting these repository files would not demonstrate an app-size win. Model downloads are a separate on-disk footprint.

No built `.app` was available. Measure release `Contents/MacOS`, `Frameworks` and `Resources` with `du`, file byte counts, `size -m`, and `otool -L`; inspect embedded Sparkle helpers and architecture slices. Compare compressed distribution size separately from installed size. Before stripping the app's symbols, retain dSYM/UUID mapping and test launch, update framework loading, localizations and signatures. Do not trim Sparkle helpers, remove engines, lower model precision further or change the model default without flagging feature/quality changes. Dependency splitting is a larger product/build decision, not a safe size patch here.

The macOS workflow runs `swift build` then `swift test`. The second command reuses incremental products; it is not evidence of two full compilations. Removing the first step could alter coverage of auxiliary executable targets. Establish which targets `swift test` builds with this toolchain before consolidating. Preserve offline/fake tests and explicit integration gating.

There is no macOS dependency/build cache. Trial dependency-only versus full-build caches; key on OS/architecture, exact Xcode/Swift identity, `Package.swift` and `Package.resolved`, with conservative fallback keys. Compare cold/no-cache, dependency-hit and full-hit runs including cache restore/save time and size. Do not cache model data, runtime app state or credentials. Windows already caches Cargo registry/git/target by Cargo.lock, but a stable toolchain can change without that lock changing; include toolchain/platform identity before assuming target reuse is reliable. Node dependency caching is another trial, not an established saving. Broad CI path filters could miss meaningful changes; none were added.

Mac measurement: `swift --version`, Xcode version, then separate clean scratch-directory and warm `swift build` / `swift test` timings on the same commit. Use `/usr/bin/time -l` to capture wall/CPU time and peak RSS. CI cache gains require later authorized runner measurements; local timings do not predict hosted runner savings exactly. Preserve the existing build/test coverage and benchmark additional instrumentation separately from the release build.

## Differences in the two comparison trees

### `b4851b9`

Relative to the base, this tree lacks replacement-rule/remember-correction implementation and its tests/performance fixture, and changes profile polishing availability via `PolishingReadiness`, `ProviderFactory`, `DictationCoordinator+Profiles`, `PlainsaySettings` and profile UI. It retains private dictation/profiles. `hasAPIKey` caches provider key presence and invalidates on key writes and recording/cleaner boundaries; that prevents repeated Keychain reads in the new HUD/editor readiness path. This is already present in that tree, not a new optimisation to transplant wholesale into the base. Preserve invalidation and the distinction between requested and effective polishing if combining branches.

It also lacks the base's plural-localization helper/tests and has different catalogs. Smaller source size here accompanies feature/translation differences, so reverting to that tree is not a behaviour-neutral bundle optimisation. The base-only matcher recommendations do not apply where the feature is absent. Tail/audio, dictionary row reuse, bundle-path and CI findings still apply; `TermDictionary` differs only in `foldedKey` visibility.

Mac checks specific to this tree: use `ProfileCredentialChangeTests` and `ProfileEffectivePolishingTests` with fake key lookups to count calls per render/recording boundary, then inspect actual HUD CPU without reading or logging real keys. Compare the profile chip and cleaner under mid-recording provider/key changes. Do not benchmark missing features as equivalent workloads.

### `c4c6dbd`

Relative to the base, this tree lacks the profile/private-dictation/replacement-rule feature sets and associated UI/tests, and adds history recovery, backups, retention and failure reporting. The main relevant additions are `HistoryFileRecovery.swift`, `HistoryFileBackups.swift`, `HistoryFileRetention.swift`, and changes to `TranscriptHistory`, `PrivateFiles`, coordinator history actions and History UI. Paste/voice-filter differences also remove private-session concealment/debug gates. Those are user/privacy behaviour differences, not optimisations to cherry-pick here.

The history loader tries full decode before record recovery; damaged files are preserved rather than silently replaced. Backup retention enumerates files, reads retained backup data, converts bytes to arrays, scans object ranges, parses record dates with newly constructed formatters and verifies protection. This can add main-actor startup and per-add work proportional to damaged backup count/size, beyond the 100 live-record limit. Safe candidates for a follow-up include a formatter reused within one retention pass and fewer intermediate byte copies. Do not skip re-verification, drop damaged bytes, weaken retention, or make deletion failures silent to gain speed. Run its history privacy/recovery/retention/staging tests and measure with synthetic clean/damaged/large backup sets and denied writes. Avoid extrapolating from an empty-history launch.

The preview pacing helper moved into `DictationCoordinator` but retains the same clamp; it is not a performance improvement by itself. The bounded-tail and dictionary changes remain conceptually applicable, though coordinator context differs and a cherry-pick may need manual resolution.

### Static comparison facts

These are source-file byte counts/key counts from Git, not compiled bundle sizes or runtime measurements:

| Tree | App catalog bytes / keys | Core catalog bytes / keys |
| --- | --- | --- |
| `ed9ded1` | 968,920 / 470 | 194,119 / 97 |
| `b4851b9` | 874,694 / 403 | 194,131 / 97 |
| `c4c6dbd` | 856,412 / 358 | 189,787 / 86 |

`Package.swift`, `Package.resolved`, `Scripts/` and `.github/` are identical across these three trees. Build, bundle and CI observations therefore apply to all three. The final fixes are based only on `ed9ded1`; no feature-changing comparison-tree commits were merged.

## Validation and remaining limits

Completed here:

- Inspected Git tree differences, startup/lifecycle, local/remote ASR, preview/tail, audio buffering, voice filtering, dictionary/rules, history/recovery, paste, packaging and workflows.
- `git diff --check` and `bash -n Scripts/bundle.sh` passed.
- Both workflow YAML files parsed with PyYAML; a local grouping model checked same/different PR, workflow, push and manual cases. This is not a GitHub expression-engine execution.
- A Python arithmetic model compared assignment and swapped-row Levenshtein results for all 14,641 pairs of strings of length 0–4 over `abł`; outputs agreed. This checks the recurrence, not Swift compilation, Unicode grapheme semantics or allocator performance.
- Added Mac tests for empty/bounded/full/overflow/reset snapshot behaviour, snapshot independence, strict tail-window decisions and the protocol compatibility default. They were **not executed here**.

Still required on a Mac: compile with the supported Swift toolchain, run the full `swift test` suite, exercise real audio/permissions/paste and run release profiling described above. No Swift executable is installed here. No claimed latency, CPU, RSS, build-time or app-size measurement was fabricated. Historical repository benchmark results were not rerun. Timing instrumentation should use monotonic clocks and content-free phase markers, separate cold/warm runs, alternate baseline/change runs, and report distributions rather than a single best run.
