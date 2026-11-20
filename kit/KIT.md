# Plainsay nightly release credential setup

Konrad approved GitHub write access for `conrader/plainsay` and
`conrader/homebrew-plainsay` and SSH access from mini-m4 to the OVH update
server. The nightly uses `codex-server` for both update and website publishing.
Run the setup commands on the named host during the rollout.

## 1. Preflight

- Pause nightly and coordinate a window with the current website publisher.
  Wait for active releases and site deploys to finish. Keep a separate OVH
  admin session open throughout setup and verify `conrader` access afterward.
- On Ubuntu, confirm the update and website roots are the real directories in
  use by nginx, with no nested mounts in the managed trees. Confirm nginx's
  worker runs as `www-data`, can read the current appcast, stable DMG and
  website, and denies HTTP access to dot paths such as `.release-backups` and
  `.release-stage.*`. The update root and `releases/` must share a filesystem
  for the publish renames. Check the live feed has a numeric Sparkle build.
- On OVH, confirm at least 8 GiB free on `/` and on the update root
  (`df -h / /var/www/plainsay-updates`). Provisioning stops below that.
- On OVH, install `rsync`, `python3`, `libxml2-utils` (`xmllint`), and `acl` if needed.
  Check `command -v rsync sha256sum mktemp python3 xmllint getfacl setfacl`. Check
  OpenSSH accepts public keys for the dedicated account and uses Ubuntu's PAM
  handling for locked-password accounts.
  Check any host-level `AllowUsers`, `Match` and sudo rules for `plainsay-deploy`
  and confirm TCP/22 reaches OpenSSH over the tailnet.
- On the Apple silicon Mac, log in as `konrad` in the Aqua session. Install
  `gh`, Git, current OpenSSH and rsync with `--chmod` support. Keep the login
  Keychain unlocked. The kit uses the dedicated account's `gh:github.com`
  Keychain service and stops at first setup if that service already exists.
  Review any existing SSH settings that apply additional identities to
  `codex-server`.
- In the release checkout, check that `origin` is the HTTPS URL for
  `conrader/plainsay` and that the system and checkout Git config use the
  intended GitHub credentials. The tap clone already uses HTTPS. Complete
  Xcode, Developer ID, Sparkle and `plainsay-notary` setup from
  [RELEASING.md](../RELEASING.md).

## 2. Create the mini-m4 SSH key and provision OVH

Run the key setup from the kit checkout on mini-m4.

```bash
./kit/mini-provision.sh --key-only
```

Copy the single public-key line to your OVH admin shell. Enter it at the
`read` prompt below. Review the plan before applying it.

```bash
IFS= read -r PUBKEY
sudo ./kit/ovh-provision.sh --dry-run "$PUBKEY"
sudo ./kit/ovh-provision.sh "$PUBKEY"
```

The kit installs one key with
`from="100.106.213.49",restrict,command="/var/lib/plainsay-deploy/bin/deploy-command"`.
The forced command (`ovh-deploy-command.sh`) runs only the exact remote
commands sent by `Scripts/release.sh`, an rsync push into
`/var/www/plainsay-app`, and the write probe below. The key refuses shell
sessions and file-transfer subsystems. If `release.sh` changes
its remote commands, update the forced command in the same change;
`Tests/release_sandbox.py` fails otherwise. Use the matching kit and release
scripts before enabling nightly. Release staging, uploads and backups stop
when `/` or the update root has less than 8 GiB free. For the manual Sparkle
rollback in RELEASING.md, use `sudo -u plainsay-deploy bash` from an admin
shell. Confirm that sshd sees `100.106.213.49` for mini-m4. The account has a
locked password, a dedicated group, and no sudo membership.

OVH saves the original ACLs, owners, groups and modes of changed paths under
`/var/backups/plainsay-deploy/` before granting access. The account can stage
via `mktemp -d`, upload the three artifacts over SSH stdin, and run
`sha256sum`. The root-owned `release-retention` helper verifies and archives
the previous release, activates the staged release, and prunes public
artifacts and previous backups after independent HTTPS verification. The
forced command validates the helper's version, stage, archive and hash
arguments. Pre-publication cleanup removes the unique staging directory.
The release rollback also uses `xmllint` on OVH.

For an existing installation, pause release publishers while installing the
matching helper and forced command on OVH. From this checkout, run:

```bash
sudo install -o root -g root -m 0755 kit/ovh-release-retention.py /var/lib/plainsay-deploy/bin/release-retention
sudo install -o root -g root -m 0755 kit/ovh-deploy-command.sh /var/lib/plainsay-deploy/bin/deploy-command
```

Then check access from the signing Mac with
`ssh codex-server '/var/lib/plainsay-deploy/bin/release-retention check'`.'
Site publishing uses `rsync -az --delete` with the exclusions in
`Scripts/deploy-site.sh` under `/var/www/plainsay-app`. The nightly receiver
accepts the site's regular files and directories.

### Keep the current website deploy working in both directions

The website's receiver at `/var/lib/plainsay-deploy/bin/rsync` preserves
existing directory ACL masks and allows new directories to inherit shared
write. It applies these options only to a push into the site root. The setup
adds the receiver to the new account's remote Bash PATH. Existing owners
and nginx's effective access are preserved, and `conrader` joins
`plainsay-publish`.

Before enabling the nightly, put this line before the noninteractive return
in `conrader`'s OVH `~/.bashrc` if its website job uses bare `rsync` via SSH:

```bash
export PATH="/var/lib/plainsay-deploy/bin:$PATH"
```

For a publisher that sets `--rsync-path` or uses a different remote shell,
configure its receiver to call `/var/lib/plainsay-deploy/bin/rsync` explicitly.
Refresh the `conrader` SSH session to pick up the group. From each publisher,
check that bare `rsync` resolves to the expected receiver or that the job
uses the explicit path. Exercise the actual site transfer with
`--dry-run --itemize-changes`, using the same destination and excludes.
The receiver is required for both publishers because archive mode can mask
shared ACL write access during an otherwise successful website deploy.
Keep the existing publisher's pre/post-deploy ownership steps as configured.

## 3. Pin OVH and install the GitHub credential on mini-m4

Get the Ed25519 key line and its SHA256 fingerprint from a trusted OVH admin
console or another authenticated admin channel. Confirm the fingerprint
independently before installing it.

```bash
sudo awk '{ print "codex-server " $1 " " $2 }' /etc/ssh/ssh_host_ed25519_key.pub
sudo ssh-keygen -l -E sha256 -f /etc/ssh/ssh_host_ed25519_key.pub
```

In GitHub settings as `conrader`, create a fine-grained PAT named
`Plainsay nightly mini-m4` with a one-year expiration. Choose resource owner
`conrader`, **Only select repositories**, and just `plainsay` and
`homebrew-plainsay`. Under repository permissions grant **Contents** read
and write, **Actions** read, and **Metadata** read. Check the selection before
generating. [GitHub PAT settings and scope](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens)

On mini-m4, read in the public pin and independently verified fingerprint at
the first two prompts. At the third prompt, paste the PAT into the hidden
stdin input and press Return. Keep the PAT out of command lines, shell
history, files and logs.

```bash
IFS= read -r OVH_KNOWN_HOST
IFS= read -r OVH_FINGERPRINT
./kit/mini-provision.sh "$OVH_KNOWN_HOST" "$OVH_FINGERPRINT"
./kit/mini-provision.sh --check "$OVH_KNOWN_HOST" "$OVH_FINGERPRINT"
```

The default Tailscale hostname is `vps-ovh-1-ts`. If needed, export
`OVH_HOST` with the verified OVH Tailscale DNS name or IPv4 address for
both commands. The script pins the host key under alias `codex-server` and uses
`plainsay-deploy` with only `~/.ssh/plainsay_deploy` (0600). The check runs
the document-root SSH probe below.

```bash
ssh -o BatchMode=yes -o StrictHostKeyChecking=yes codex-server \
  'test -w /var/www/plainsay-updates && test -w /var/www/plainsay-updates/releases && test -w /var/www/plainsay-app'
```

The PAT is stored in the login Keychain via `gh auth login --with-token`.
GitHub CLI config and Git author/committer configuration use a private
directory at `~/.ssh/plainsay-release-gh/`. The kit detects and removes
GitHub CLI's file-storage fallback. The two `.permissions.push` values
check the authenticated account's repository access. Verify the PAT's
repository selection, Contents permission and Actions permission in the
GitHub settings, and confirm tag and tap branch rules allow the release
identity to publish. [GitHub CLI credential storage](https://cli.github.com/manual/gh_auth_login)

## 4. Rehearse and enable the nightly

In the copied LaunchAgent, add these keys inside its existing
`EnvironmentVariables` dictionary. Use absolute paths and keep its existing
`PATH`. Use the same environment when rehearsing in Terminal.

```xml
<key>GH_CONFIG_DIR</key>
<string>/Users/konrad/.ssh/plainsay-release-gh</string>
<key>GIT_CONFIG_GLOBAL</key>
<string>/Users/konrad/.ssh/plainsay-release-gh/gitconfig</string>
```

```bash
export GH_CONFIG_DIR="$HOME/.ssh/plainsay-release-gh"
export GIT_CONFIG_GLOBAL="$GH_CONFIG_DIR/gitconfig"
unset GH_TOKEN GITHUB_TOKEN GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN
unset HOST
git var GIT_AUTHOR_IDENT
git var GIT_COMMITTER_IDENT
./Scripts/nightly-release.sh --dry-run
```

Use the release runbook for the locked-screen `--prepare-only` rehearsal,
schedule installation and first release review. Include the two environment
keys in both the rehearsal and production plist, and lint each copy. Dry-run
checks CI and planned version when there is a new candidate. Confirm tap
access from its checkout with Git's dry-run push and review the cask and
branch rules. The publisher's `HOST` default must resolve to the installed
`codex-server` alias.

## Rollback

1. Pause the LaunchAgent and let publishes finish. If a publication marker
   exists, reconcile the release first using the release runbook. Pause
   `conrader` website deploys during ACL restoration.
2. On mini-m4, run `./kit/mini-reverse.sh` as `konrad`. It removes the managed
   SSH block, pin and key, logs out `conrader` from `github.com` in the
   release profile, and removes the profile and its Git settings. Remove
   the two release credential environment keys from the copied plist.
   Revoke the PAT by name in GitHub settings, even if local logout fails.
3. On OVH, run `sudo ./kit/ovh-reverse.sh`. It removes the public key, waits
   for you to close any existing deploy sessions, restores the baseline
   metadata on surviving paths, and removes the deploy user and group.
   Published content and populated release backup directories are kept.
   New content owned by the deploy user is transferred to the original
   containing root's owner/group. The baseline is archived under
   `/var/backups/plainsay-deploy-restored.*`. Remove the receiver override from
   `conrader`'s website publisher and verify nginx and the legacy deploy.

For a failed setup before scheduling, correct the error and rerun the
affected script, or use the same rollback steps. If a host key changed,
verify the new pin independently before removing the old pin and repeating
the mini setup.

## Local review

```bash
for file in kit/*.sh; do bash -n "$file" || exit; done
shellcheck -x kit/*.sh
bash kit/test-kit.sh
```

The harness uses GNU tools, POSIX ACLs, rsync, OpenSSH and temporary fixtures
on Linux. It needs no sudo and routes SSH and GitHub verification to local
test doubles.
