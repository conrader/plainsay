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
| Sparkle | Use the existing Ed25519 private key in the release Mac's login Keychain, matching `SUPublicEDKey` in `Scripts/Info.plist`. `sign_update` signs the ZIP. The script writes a single-item appcast and takes its minimum macOS version from the plist. It uses no `generate_appcast`. |
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
and both Apple notarizations. The scratch worktree is removed on exit.
Use a normal run to publish.

The newest main push run of `ci.yml` must have succeeded for the exact
candidate SHA. If the head is pending or red, the run defers. Each successful
night covers all merges through that tested head. The patch version increments
from the higher of the last stable tag and main's plist version. The build
increments from the higher of the last tag's plist build and main's plist build,
and publication also requires it to exceed the live feed build. This keeps
builds monotonic across marketing version changes and after restoring an older
feed. For a subsequent manual release, commit both plist fields and pick an
integer build above the highest shipped build, including withdrawn builds.

A detached worktree gets a version-only commit whose parent is the tested main
SHA. The nightly pushes the version tag to that commit and uses the tag when
creating the release. This leaves main free of release commits. Nightly DMGs
include the app and Applications shortcut with a standard Finder layout.
A fresh main check before pushing avoids publishing a stale candidate. If main
advances after publication starts, the site deploy waits for the next release
to avoid overwriting newer site content. The nightly SSH account owns both
deployment roots and publishes without sudo.

Run only one production publisher at a time. To pause the agent, run
`launchctl disable "gui/$(id -u)/com.plainsay.nightly-release"` as the release
user, wait for an active run to finish, and then boot out the service.
Use `launchctl enable` with the same service target before bootstrapping again.
The nightly lock and a possible
`publish.pending` marker live at
`~/Library/Application Support/PlainsayRelease/`. If a lock is left after a
crash, confirm its PID and any child build/publish processes are gone. Use
`git worktree list` and `git worktree remove --force` for its recorded scratch
worktree if present, then remove the stale lock directory.

## Interrupted publication

GitHub, nginx, the website, and the Homebrew tap commit independently. The
nightly writes `publish.pending` before the first public GitHub mutation and
clears it after channel verification. A later run stops while it exists. Logs
and the marker record the exact tag, staged paths, backup and SHA-256 checksums.
Failures before that marker, including tests, signing and notarization, leave
public artifacts untouched and can be retried.

Pause the agent and inspect the GitHub tag and release (including drafts),
public appcast, stable DMG, the versioned ZIP and the tap. If the tag and
release became public, reconcile the staged files or use the rollback below.
Activate any remaining valid staged files in ZIP, DMG, appcast order using the
recorded checksums. Use the public GitHub DMG checksum to finish the cask
update, and deploy the current website checkout if necessary. If publication
only created an unused tag or incomplete draft, inspect and resolve those
before retrying. Preserve any tag that corresponds to an artifact users may
already have installed. Clear the marker after confirming the resulting state,
then resume scheduling.

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
