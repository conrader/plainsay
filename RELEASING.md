# Releasing Plainsay for macOS

Sparkle checks `https://api.plainsay.app/appcast.xml` at launch and on its
24-hour schedule. The appcast advertises a signed ZIP, and the app compares
the integer `CFBundleVersion`. Installation timing depends on Sparkle settings.
The app supports Apple silicon on macOS 14 and later.

## What the manual release did at 2145b01

| Requirement | Source and behavior |
| --- | --- |
| Build host | Apple silicon Mac with Xcode 16 or later, Swift 6+, and selected Xcode tools. The CI reference is `macos-15`. Run `swift build` to resolve SwiftPM dependencies and obtain Sparkle's `sign_update`. `bundle.sh` uses `xcstringstool`, `rsync`, `install_name_tool`, and `codesign`. The release also uses `security`, `PlistBuddy`, `ditto`, `hdiutil`, `osascript`/Finder, `spctl`, `xcrun`, Git, `gh`, `curl`, SSH/SCP, and checksum utilities. |
| Apple signing and notarization | The Developer ID Application identity in `Scripts/release.sh` needs its private key and certificate in the signing user's Keychain. The app and Sparkle helpers are signed inside out with hardened runtime and secure timestamps. The app and DMG are submitted separately, stapled, and assessed. `plainsay-notary` is the Keychain profile created from an App Store Connect API `.p8`, key ID, and issuer ID. The old `NOTARIZE=0` branch could still reach publication. The updated script requires notarization. |
| Sparkle | Use the Ed25519 private key matching `SUPublicEDKey` in `Scripts/Info.plist`. On `mini-m4`, store that key under account `com.plainsay.sparkle` in the `herdr-release` keychain. `sign_update` signs the ZIP. The script writes a single-item appcast and takes its minimum macOS version from the plist. |
| Version and source | Both version fields in `Scripts/Info.plist` had to be committed. Historically `CFBundleVersion = major * 10000 + minor * 100 + patch` (0.2.38 used build 238). The release checked the live build, a clean Git tree, reviewed privacy and terms pages, and site checkout freshness. |
| Update host and site | `HOST` defaults to the SSH alias `codex-server`. nginx serves `/var/www/plainsay-updates` as `api.plainsay.app`. The script stages and verifies uploads, then replaces the stable DMG and appcast with same-filesystem renames. `deploy-site.sh` uses rsync to publish `docs/` to `/var/www/plainsay-app` and the old manual path uses sudo for permissions. |
| GitHub and Homebrew | GitHub CLI creates a draft for the committed source, attaches the signed ZIP and notarized DMG, and publishes it as latest with a `v<version>` tag. Then Git updates `Casks/plainsay.rb` on `conrader/homebrew-plainsay:main` with the version and DMG SHA-256. GitHub API verifies the cask. GitHub and Git credentials must permit writes to their respective repositories. No `brew` executable is required to release. |

The baseline's `.github/workflows/ci.yml` builds and tests on main pushes and
PRs. Its unit suite needs no speech model or microphone. The path-filtered
Windows workflow builds debug assets for a separate platform.

## Nightly release

Use the dedicated Apple silicon Mac, for example `mini-m4`, with the `konrad`
Aqua login session and the system time zone set to `Europe/Warsaw`.
`Scripts/com.plainsay.nightly-release.plist` runs at 02:10 local time. Keep the
Mac awake and the user logged in with the signing Keychain available. The
calendar may skip the spring DST hour and runs missed sleep events on wake.
Logs go to `~/Library/Logs/PlainsayRelease/nightly.log`.

`Scripts/nightly-release.sh --dry-run` fetches remote main and numeric
`vMAJOR.MINOR.PATCH` tags and reads GitHub CI and version metadata. It leaves
release destinations and the source checkout untouched. `--prepare-only` also
runs the Swift build, tests, Developer ID signing, Sparkle signature verification,
and both Apple notarizations. The scratch worktree is removed on exit unless
publication needs reconciliation.
Use a normal run to publish.

The newest main push run of `ci.yml` must have succeeded for the exact
candidate SHA. If the head is pending or red, the run defers. Each successful
night covers all merges through that tested head. When main's plist version is
ahead of the last stable tag, the nightly uses the committed version and build
as-is. If that build is at or below the last tagged build or the live feed
build, correct the plist on main before trying again. Otherwise, the nightly
increments the last stable patch version and adds one to the higher of the
tagged and main plist builds. All releases must exceed the live feed build.
For a manual release, commit both plist fields and use a build above the
highest shipped build, including withdrawn builds.
A successful nightly publication completes the release for that version.

For a manual release on `mini-m4`, set
`PLAINSAY_SPARKLE_ACCOUNT=com.plainsay.sparkle` in the environment when running
`Scripts/release.sh`. Keep `herdr-release` in the release user's keychain search
list and keep its password file at `~/.herdr-release/kcpass` (or the path set
by `PLAINSAY_RELEASE_KCPASS`) readable only by that user. The release unlocks
this keychain for ZIP signing, including when it reuses a notarized app.
An unset or empty `PLAINSAY_SPARKLE_ACCOUNT` selects the legacy `ed25519` account.

On `mini-m4`, run `~/bin/plainsay-import-sparkle-key` as the release user. It
grants `/usr/bin/security` and Sparkle's `sign_update` access to the
`com.plainsay.sparkle` item in `herdr-release.keychain-db` without an interactive
prompt. The release checkout pins Sparkle to 2.9.5. After any Sparkle upgrade,
run `swift build` to resolve the new binary, then re-run the import helper or
repair the item's access control list (ACL) for the new `sign_update` binary.

A detached worktree gets a version-only commit when the nightly generates a
version bump. For a version already committed on main, the tag points directly
at the tested main SHA. Nightly DMGs include the app and Applications shortcut
with a standard Finder layout. The nightly checks main before the Swift build
and again during packaging. Both release paths recheck the live feed before
creating the remote backup, and the nightly rechecks main at that point too.
If main advances after publication starts, the site deploy waits for the next
release to avoid overwriting newer site content. The nightly SSH account owns
both deployment roots and publishes without sudo.

Manual and nightly releases on the signing host share an exclusive lock and
publication marker. Run them as the same user with the same state directory
(`PLAINSAY_NIGHTLY_STATE_DIR` can override the default). Before signing, both
paths check that the default keychain is unlocked and the Developer ID signing
identity is available. Keychain checks and unlocks have a 15-second limit.
`sign_update` and Developer ID signing each have a 120-second limit per call.
The whole `notarytool` invocation has a 30-minute limit, including upload and
the 20-minute service wait. At the deadline, the watchdog sends TERM to the
command's process group, gives it two seconds to exit, then sends KILL and
returns status 124. It forwards INT, TERM, and HUP to the same group on
interruption and ends the grace period early once the commands have exited. If
the release shell dies, the watchdog kills the command group. A guardian in the
command group handles cleanup if launchd kills the watchdog itself. A timeout
stops the nightly before publication.
For a Sparkle signing timeout, check the item's ACL as described above. For
Developer ID or notarization failures, check the signing identity or the
`plainsay-notary` profile in the release user's login session before retrying.

To pause the agent, run
`launchctl disable "gui/$(id -u)/com.plainsay.nightly-release"` as the release
user, wait for an active run to finish, and then boot out the service.
Use `launchctl enable` with the same service target before bootstrapping again.
To pick up `PLAINSAY_SPARKLE_ACCOUNT`, reinstall the updated
`com.plainsay.nightly-release.plist` in the release user's
`~/Library/LaunchAgents/`, preserving any host-specific paths and settings.
In the release user's Aqua session, run the first command if the agent is
loaded, then run the second command to load the updated plist.

```bash
launchctl bootout "gui/$(id -u)/com.plainsay.nightly-release"
launchctl bootstrap "gui/$(id -u)" ~/Library/LaunchAgents/com.plainsay.nightly-release.plist
```

The `nightly.lock` directory and `publish.pending` marker live under
`~/Library/Application Support/PlainsayRelease/` by default. If a crash leaves
the lock behind, confirm its PID and any child build or publish processes are
gone before removing it. A scratch worktree may remain under `nightly.*/source`
in the state directory. If a marker exists, retain the worktree through
reconciliation.

### Known limits of the release watchdog

`Scripts/release-timeout.pl` has these known gaps:

- When the command exits on its own, the watchdog kills only the guardian.
  Grandchildren left in the command's process group keep running. This
  predates the guardian.
- The group kill reaches only processes that stay in the command's process
  group. A descendant that calls `setsid()` or changes its process group
  escapes it. The `codesign` and `notarytool` helpers are not expected to.
- If the watchdog is SIGKILLed after forking the guardian but before the
  guardian's `setpgid`, the guardian's group kill does nothing. This is
  harmless because the command has not started yet.
- If launchd SIGKILLs the nightly bash shell, its EXIT trap does not run and
  `nightly.lock` stays behind. The next run refuses to start until the lock is
  inspected and removed as described above. Nothing is published after a
  failed step.
- On a timeout the watchdog always waits the full two-second grace period
  before KILL. Only an INT, TERM or HUP ends the grace period early.
- The watchdog has been tested only in a Linux sandbox. Its behaviour on macOS
  with perl 5.34 and during a launchd bootout has not been exercised on
  `mini-m4` yet. The first dry signing run there covers it.

## Interrupted publication

GitHub, nginx, the website, and the Homebrew tap commit independently. The
manual and nightly publishers write `publish.pending` before the first GitHub
mutation and clear it after channel verification. Both paths stop while it
exists. The marker records the tag, build, commits, staging and backup paths,
SHA-256 checksums, and local checkout and tap paths. A failed publish retains
the ZIP, DMG, appcast and committed tap clone in that checkout's `dist` folder.
The nightly prints the retained worktree path and releases the lock. Failures
before the marker leave public artifacts untouched and can be retried.

Pause the agent and inspect the GitHub tag and release (including drafts),
public appcast, stable DMG, the versioned ZIP and the tap. If the tag and
release became public, reconcile the staged files or use the rollback below.
Activate any remaining valid staged files in ZIP, DMG, appcast order using the
recorded checksums. Use the public GitHub DMG checksum to finish the cask
update, and deploy the current website checkout if necessary. If publication
only created an unused tag or incomplete draft, inspect and resolve those
before retrying. Preserve any tag that corresponds to an artifact users may
already have installed. Clear the marker after confirming the resulting state,
then remove any retained nightly checkout with `git worktree remove --force`
and remove its empty scratch directory. Resume scheduling after cleanup.

## Pulling a bad Sparkle build

1. Pause the agent using the procedure above. From
   `codex-server`, pick the logged backup under
   `/var/www/plainsay-updates/.release-backups/vBAD.XXXXXX`. Verify its
   `appcast.xml` identifies the last good version and still references the
   matching signed ZIP. The generated feed has one item, so restoring the prior
   feed is preferable to deleting just that item.
2. With `backup` set to that full backup directory, run on the update host
   as the deploy user. This replaces each public file with a same-filesystem
   rename and leaves the backups available.

   ```bash
   set -e
   : "${backup:?Set backup to the verified release backup directory}"
   cd /var/www/plainsay-updates
   xmllint --nonet --noout "$backup/appcast.xml"
   stage=$(mktemp -d .rollback.XXXXXX)
   install -m 0644 "$backup/appcast.xml" "$stage/appcast.xml"
   install -m 0644 "$backup/Plainsay-latest.dmg" "$stage/Plainsay-latest.dmg"
   mv "$stage/appcast.xml" appcast.xml
   mv "$stage/Plainsay-latest.dmg" releases/Plainsay-latest.dmg
   rmdir "$stage"
   ```

3. Purge any caching layer for `/appcast.xml` and the stable DMG if present.
   Verify the feed and DMG from `https://api.plainsay.app`, mark the bad GitHub
   release as withdrawn in its notes, restore the previous release as Latest,
   and revert the corresponding cask update. Keep the bad tag as a version and
   build high-water mark. The next release must have a higher build.
4. Devices that installed or already downloaded the bad update can require
   a forward fix. Merge the fix or revert to main and release it at a higher
   build number. Test update discovery from both the bad and prior good builds.

## GitHub Actions alternative

An Apple silicon `macos-15` scheduled job could use a protected production
environment, `concurrency`, 02:10 `Europe/Warsaw` plus manual dispatch, and
the same exact-main CI gate. The environment would require
`DEVELOPER_ID_P12_BASE64`, `DEVELOPER_ID_P12_PASSWORD`,
`APP_STORE_CONNECT_KEY_P8_BASE64`, `APP_STORE_CONNECT_KEY_ID`,
`APP_STORE_CONNECT_ISSUER_ID`, `SPARKLE_EDDSA_PRIVATE_KEY`,
`UPDATE_HOST_SSH_PRIVATE_KEY`, and `BREW_TAP_WRITE_TOKEN`. Pin
`UPDATE_HOST_SSH_KNOWN_HOSTS` as trusted configuration. Use
`GITHUB_TOKEN` with `actions: read` and `contents: write` for Plainsay.
The built-in token is scoped to that repo, so the tap requires its own
credential. Generate the temporary Keychain password on the runner, import the
Developer ID and Sparkle keys, store the notary profile there, and grant
non-interactive signing access. Persist publication state outside the ephemeral
VM. The runner also needs a reachable SSH endpoint or private network route.
GitHub scheduled jobs can be delayed or dropped. [Runner architecture](https://docs.github.com/en/actions/reference/runners/github-hosted-runners) · [Scheduled workflow behavior](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows#schedule) · [GitHub token scope](https://docs.github.com/en/actions/concepts/security/github_token) · [Keychain import](https://docs.github.com/en/actions/how-tos/deploy/deploy-to-third-party-platforms/sign-xcode-applications) · [Sparkle key handling](https://sparkle-project.org/documentation/#eddsa-ed25519-signatures)

The dedicated Mac keeps existing production keys in a persistent Keychain,
uses the existing network route to the update host, and preserves local
publication state after interruptions. Use that host for initial rollout.
