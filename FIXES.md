# Must-fix review of 7207c89

Base: `7207c89b732e422fd7c17f0bb03471549071e1e0`.
Branch: `fix/mustfix-7207c89`.

Read `REVIEW.md` and `MERGE-PLAN.md`. Five requested fixes already survived the
five-head merge; they were verified by source inspection and retained. Three
remaining defects have separate commits, each with regression coverage.

## Local repository and bundle

The supplied `.git` is mounted read-only: the initial branch command failed
with `index.lock: Read-only file system`. Git metadata was copied to
`.mustfix-git` inside this workdir, and the requested branch was created there
directly from the base. All source edits remain in this workdir. Inspect it with:

```sh
git --git-dir=.mustfix-git --work-tree=. status --short
git --git-dir=.mustfix-git --work-tree=. log --oneline 7207c89..fix/mustfix-7207c89
git --git-dir=.mustfix-git --work-tree=. diff 7207c89..fix/mustfix-7207c89
```

Plain `git` still uses the original read-only metadata and reports
`local/merge-dryrun` at the base. Original refs and remote configuration were
not changed; `origin` pushurl remains `DISABLED` in both metadata directories.
No push, fetch, PR, deployment, merge to main, parking or contact was performed.
No credentials were accessed. New commits use `Codex <codex@localhost>` through
per-command options because this environment has no Git author configured.

Bundle output: `astra-mustfix-7207c89.bundle` **inside this workdir**. The
requested sibling location is outside the sandbox's writable roots; approval
is unavailable. The bundle contains `refs/heads/fix/mustfix-7207c89` with its
complete ancestry, including this report and the static checker. It excludes
untracked review/brief files and the copied metadata directory. On a host with
permission, it can be moved to `../astra-mustfix-7207c89.bundle` unchanged.

## Fixes and Mac verification

### 1. P1: hosted Preview in an already-open window — already fixed

Original fixes: `2c4c066e546f1394ae2249d2a0389eebf20ffa78` (live gate),
`a039803ae7dc84133a4ae684f19f01ac0437c3c3` (request settlement), and
`80ba1351524ed5f55ef9045f25fdc8bad0e9f356` (both-window regression tests).
All are ancestors of `7207c89`; no new implementation commit was needed.

Both windows check the live gate before constructing an editor, send through
`HostedEditSlot`, and cancel stale previews. Gate/slot sources, Voice Edit and
the private-state helper match `80ba135` exactly. The correction window also
retains Remember initialization, local replacement tracking and the verified
apply requirement. No direct hosted `editor.edit` path was reintroduced.

Mac: run `swift test --filter 'PrivateArmLiveTests|PrivateDictationSourceGuards|HostedEditSlotTests|RememberCorrectionFlowTests'`.
In each window, open before arming, arm private mode, and request hosted Preview:
expect a refusal and no provider call. Also start Preview, arm then disarm
before its delayed reply: expect the reply discarded and busy state cleared.
Then verify a new Preview after disarming works. Check a local replacement can
still offer Remember only after successful apply. The automated window tests
use Core slot/gate models plus App source guards, not real SwiftUI windows.

### 2. P2: retention for a backup created during retry — fixed here

Commit: `80ca9b7716e12bae63bcfa09a4768c6d98e18ed5`.

`mayReplaceFile()` now runs retention immediately after recovering records and
creating the damage backup. The live-file save can clear its own expired-data
flag without clearing backup retention/protection failures. Only dated,
expired backup records are removed; recent damaged and undated bytes survive.
The switchable-backup save test now includes expired data and checks the backup
before reopening. A new retry test covers successful protection and protection
failure followed by repair.

Mac: run `swift test --filter 'HistoryRecoveryTests|HistoryRetentionSafetyTests|HistoryStageProtectionTests'`.
The new `retrySweepsNewBackup` fixture starts with expired decodable data plus
recent/undated damage, initially refuses backup creation, enables it, and
immediately checks retry status and backup bytes. Existing retention tests
cover failed trim writes. For UI checks, use disposable History data: after
repairing storage access and choosing Try again, expired backup text must be
gone immediately; failures must keep the warning visible.

### 3. P2: five History strings in English and Polish — fixed here

Commit: `f7a154dd47e8c7653ca4471b78bed019a213fef4`.

Added `history.deletionFailed`, `history.disabledDescriptionNotDeleted`,
`history.retryDeletion`, `history.saveFailed`, and `history.saveUnprotected`.
Translations preserve the distinction between failed deletion, unsaved
in-memory records and saved records whose protection could not be verified.
Catalog coverage checks both languages, placeholders and each English fallback.

Mac: run `swift test --filter LocalizationCatalogTests`, compile both catalogs
as described below, and inspect these warnings in English and Polish using
disposable data with injected/storage failures. The off-state description must
not claim deletion succeeded when the deletion warning is still present.

### 4. P2: private notice after disarming — already fixed

Commit: `2c4c066e546f1394ae2249d2a0389eebf20ffa78`, already in the base.

`showsStillArmed` requires both the frozen private session policy and the live
`privateDictation.isArmed`. Silence, transcription error, cancellation and
too-short paths use that helper. The session remains private after disarming,
but the notice makes no promise about the next session.

Mac: run `swift test --filter PrivateArmLiveTests`. Start a private recording,
disarm while it is in flight, then end with silence, cancel, or induce an
engine error. Expect no “Still armed” notice. Re-arm before completion and
confirm the notice returns. Confirm the interrupted session leaves no History.

### 5. P2: truthful profile Polishing/translation chip — already fixed

Commits: `7854d77950e26f1aa5b0a4d05cb9b1b7d2058ed4`,
`1c4f600717cf5eb9eb5c4611e28332a759cdbe77`, and
`b4851b93725c9dd432ba59701cdfa0ec7bcdb344`, already in the base.

The chip requires `policy.allowsCleanup && effectivePolishingReadiness().runs`;
translation also requires entitlement. The editor and cleaner factory share
the readiness rule. Cached credential presence is refreshed on key writes
and recording/cleaner-build boundaries.

Mac: run `swift test --filter 'ProfileEffectivePolishingTests|ProfileCredentialChangeTests'`.
Use on-device speech, an active test Cloud account and a profile requesting
Polish translation. With the BYOK cleaner key absent, expect “Local only” and
“no translation”, raw output, and no offered style controls. Repeat with global
Polishing switched off during recording and with key presence changed between
recording start and cleaner construction. Use test credentials/fakes, not
production secrets, for automated checks.

### 6. P2: profile rename must not persist empty — already fixed

Commit: `3343a33265162fb4e32d9b9c9f99b7dad00e2b80`, already in the base.

The editor has a name draft, validates through `appProfiles.rename`, and
discards an invalid draft on submit, loss of focus or disappearance. The
shared name rule trims whitespace and accepts only 1–40 characters.

Mac: run `swift test --filter DictationProfileTests`. Clear a profile name,
enter only whitespace, or enter 41 characters; leave the field and close/reopen
Settings. The last valid name must remain. A valid padded name must persist
trimmed, including after changing another profile field.

### 7. P2: EN/PL overflow plurals and Polish Off agreement — already fixed

Commit: `8ed63f2d3a6326b64465aba44dd94ebf10426efa`, with fallback-locale fix
`c03b653a0ff4834bb9d84fe7295d536a1aea5080`, both already in the base.

Overflow uses `Localization.appPlural`: English one/other and Polish
one/few/many/other forms. Email layout uses `profiles.email.off` → “Wyłączony”;
translation uses `profiles.translation.off` → “Wyłączone”.

Mac: run `swift test --filter LocalizationPluralTests`. In a bundled app,
check overflow counts 1, 2, 5, 12, 22 and 112 with each interface language.
Expect English term/terms and Polish termin/terminy/terminów with the matching
verb; check both Off pickers. Tests also cover zero and English fallback under
other interface languages.

### 8. P2: History recovery must not resurrect a Vocabulary-pruned target — fixed here

Commit: `454fde32a847c568cbcaa352513f7aa70d044417`.

History exposes `hasUnresolvedDiskContents` for a non-owned file or a failed
save/deletion. A live-store pruning overload refuses to discard retired
targets or settle overflow while that flag is true. Vocabulary uses this
overload and observes the flag so a successful retry with unchanged record IDs
can resume pruning. The existing in-flight guard and cached record index stay
in use. The conservative tradeoff is retaining exclusions longer while disk
contents remain unresolved, rather than offering a rule-generated word.

Mac: run `swift test --filter 'HistoryRuleRetirementTests|ReplacementRuleRetirementTests'`
as a normal user. `lateRecovery` simulates an unreadable live path, opens the
Vocabulary pruning path, restores readable records containing a retired rule
target, and triggers recovery through a new save. It covers both known targets
and overflow, proves the target would otherwise be proposed, and checks that
successful Clear eventually permits pruning. `failedClearThenRelaunch` removes
directory write permission, attempts Clear, persists the pruning result, then
reopens History and verifies the resurrected records still cannot propose the
target. That permission test explicitly skips root. A source guard checks the
App passes the live store and observes disk-state changes.

## Validation performed here

- Swift is absent from PATH. No Swift build, Swift test, Mac UI run or
  `xcstringstool` execution is claimed.
- `python3 Scripts/check-mustfix.py` passed: both catalog JSON files reject
  duplicate keys; 1,160 EN/PL values have consistent placeholders; all five
  new History keys match their fallbacks; plural categories and Off labels
  are present; retained privacy/profile source wiring is intact.
- R1 size gates passed unchanged: coordinator 1,303/1,304 lines, SettingsView
  743/784, and all 11 guarded helpers at or below 500. No size limits were raised.
- `git diff --check` passed for the implementation commits and working changes.
- New regression tests are written, **not executed**. Static checks do not
  substitute for Swift type checking or the combined runtime suite.

## Mac qualification

After transferring the bundle, a fresh local checkout requires no remote:

```sh
mkdir mustfix-mac
cd mustfix-mac
git init
git fetch /absolute/path/astra-mustfix-7207c89.bundle refs/heads/fix/mustfix-7207c89:refs/heads/fix/mustfix-7207c89
git switch fix/mustfix-7207c89
python3 Scripts/check-mustfix.py
swift build
swift test
```

Run tests as a normal user so file-permission cases execute. Read the actual
test output for skipped integration cases. Compile the catalogs independently:

```sh
catalog_check_dir=$(mktemp -d)
xcrun xcstringstool compile Sources/PlainsayApp/Resources/Localizable.xcstrings --output-directory "$catalog_check_dir/app"
xcrun xcstringstool compile Sources/PlainsayCore/Resources/CoreLocalizable.xcstrings --output-directory "$catalog_check_dir/core"
```

For manual UI checks, use a local application bundle containing these compiled
catalogs. A bare `swift run` uses English fallbacks and cannot verify Polish UI
or the normal macOS permission flow. Complete the eight checks above before
treating this merged tree as runtime-qualified.
