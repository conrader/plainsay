"""Validate the explicit one-off inventory before allowing any deletions."""

from contextlib import ExitStack
import fcntl
import os
from pathlib import Path, PurePosixPath
import re
import shlex
import stat
import subprocess
import sys
from xml.etree import ElementTree

from plainsay_release_retention import (
    BACKUP_FILES, LAUNCH, Stop, UPDATE, VERSION, backup_directories, backup_zip, check_backup_dependencies,
    check_directory, file_info, live_references, unfinished_publication, verify_rollback,
)

LEGACY_ZIP = "Plainsay-0.2.23.zip"
ROLLBACK_ZIP = "Plainsay-0.2.38.zip"
SETUP_LOCK = Path("/run/plainsay-deploy-setup.lock")
MAC = "macbook-m4"
MINI = "mini-m4"
DOWNLOADS = "/Users/konradsierzputowski/Downloads"
LAUNCH_FILES = {"appcast.xml", "Plainsay-latest.dmg", "plainsay-app.tar.gz"}


def launch_files():
    check_directory(LAUNCH)
    if {item.name for item in LAUNCH.iterdir()} != LAUNCH_FILES:
        raise Stop(f"Unexpected files in {LAUNCH}")
    return sorted(LAUNCH / name for name in LAUNCH_FILES)


def rollback(candidates):
    if not candidates:
        raise Stop("No saved v0.2.38 rollback in .release-backups; wait for the first verified publish")
    path = max(candidates, key=lambda item: (item.lstat().st_mtime_ns, item.name))
    check_directory(path)
    if {file.name for file in path.iterdir()} != BACKUP_FILES:
        raise Stop(f"Unexpected files in {path}")
    return path, verify_rollback(UPDATE, path, expected_zip=ROLLBACK_ZIP)


MAC_LIST = f"""set -eu
cd -P -- "$HOME/Downloads"
test "$(pwd -P)" = {shlex.quote(DOWNLOADS)}
for f in "$HOME"/Downloads/[Pp][Ll][Aa][Ii][Nn][Ss][Aa][Yy]*.[Dd][Mm][Gg]; do
    [ -e "$f" ] || [ -L "$f" ] || continue
    LC_ALL=C ls -ldn "$f"
done
"""


PAUSE_CHECK = """set -eu
state="$HOME/Library/Application Support/PlainsayRelease"
lock="$state/nightly.lock"
test -d "$lock"
test ! -L "$lock"
test -f "$lock/oneoff-prune"
test ! -L "$lock/oneoff-prune"
test ! -e "$lock/pid"
test ! -L "$lock/pid"
test ! -e "$state/publish.pending"
test ! -L "$state/publish.pending"
printf '%s\\n' paused
"""


def ssh(user, host, script):
    command = ["ssh", "-n", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes",
               "-o", "UpdateHostKeys=no", "-o", "ControlPath=none", "-o", "ConnectTimeout=8",
               host, f"/bin/sh -c {shlex.quote(script)}"]
    if user:
        command = ["sudo", "-n", "-H", "-u", user, *command]
    return subprocess.check_output(command, text=True, stderr=subprocess.DEVNULL, timeout=15)


def check_release_pause(user):
    try:
        if ssh(user, MINI, PAUSE_CHECK) == "paused\n":
            return
    except (OSError, subprocess.CalledProcessError, subprocess.TimeoutExpired):
        pass
    raise Stop(f"{MINI} release pause could not be verified (nightly.lock/oneoff-prune)")


def mac_inventory(user, expected):
    try:
        raw = ssh(user, MAC, MAC_LIST)
    except (OSError, subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
        raise Stop(f"{MAC} Downloads inventory unavailable; MacBook step skipped") from error
    files = {}
    for line in raw.splitlines():
        fields = line.split(maxsplit=8)
        if len(fields) != 9 or not fields[0].startswith("-") or fields[8] not in expected:
            raise Stop(f"{MAC} has a DMG outside the verified explicit inventory or an unsafe file type")
        files[fields[8]] = int(fields[4])
    return raw, files


def mac_remove(user, listing, paths):
    # Compare the lightweight inventory again on the Mac before any unlink.
    args = " ".join(shlex.quote(path) for path in paths)
    ssh(user, MAC, f"set -eu\nlisting=$(/bin/sh -c {shlex.quote(MAC_LIST)})\n"
                   f"test \"$listing\" = {shlex.quote(listing.rstrip(chr(10)))}\n"
                   f"rm -- {args}")


def check_references(paths):
    references = live_references(UPDATE)
    hits = [str(path) for path in paths if path.name.casefold() in references]
    if hits:
        raise Stop(f"live reference matches {', '.join(hits)}")


def file_identity(path):
    info = file_info(path)
    return (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns)


def prune(entries, dry_run, user):
    local = [Path(path) for path in entries]
    legacy_zip = UPDATE / "releases" / LEGACY_ZIP
    if (len(local) != len(set(local)) or not {LAUNCH, legacy_zip} <= set(local)
            or any(path != LAUNCH and (path.parent != legacy_zip.parent
                   or not re.fullmatch(rf"Plainsay-{VERSION}\.zip", path.name)) for path in local)):
        raise Stop("Unsafe explicit OVH inventory")

    errors = []
    try:
        check_release_pause(user)
    except Stop as error:
        errors.append(str(error))
    try:
        check_references(local)
        if unfinished_publication(UPDATE):
            raise Stop("update root contains an unfinished publication")
        backups = backup_directories(UPDATE)
        retained, package = rollback(backups)
        if os.path.lexists(LAUNCH):
            if backup_zip(UPDATE, LAUNCH) != legacy_zip:
                raise Stop(f"Unexpected launch rollback dependency in {LAUNCH}")
            file_info(legacy_zip)
    except Stop as error:
        raise Stop("; ".join([*errors, str(error)])) from error
    print(f"KEEP verified rollback {retained}", flush=True)
    print(f"KEEP rollback artifact {package}", flush=True)

    plans = {}
    inventory = {}
    # Remove the launch backup before unlinking its ZIP.
    for path in [LAUNCH, *(path for path in local if path != LAUNCH)]:
        if path == package:
            continue
        if not os.path.lexists(path):
            print(f"MISSING {path}", flush=True)
            continue
        files = launch_files() if path == LAUNCH else [path]
        for file in files:
            inventory[file] = file_identity(file)
        plans[path] = sum(inventory[file][2] for file in files)
    check_backup_dependencies(UPDATE, backups, plans)
    for path, size in plans.items():
        print(f"PLAN ovh:{path} {size} bytes", flush=True)
    size = sum(plans.values())
    print(f"SUMMARY candidates={len(local)} planned={len(plans)} bytes={size} dry_run={int(dry_run)}", flush=True)
    if errors:
        raise Stop("; ".join(errors))
    if dry_run:
        return
    check_references(local)
    if unfinished_publication(UPDATE):
        raise Stop("update root contains an unfinished publication")
    check_release_pause(user)
    for file, expected in inventory.items():
        if file_identity(file) != expected:
            raise Stop(f"Inventory changed at {file}")
    for path in plans:
        if path == LAUNCH:
            for file in launch_files():
                file.unlink()
            path.rmdir()
        else:
            path.unlink()
    print(f"REMOVED {len(plans)} paths ({size} bytes)", flush=True)


def prune_macbook(entries, dry_run, user):
    paths = [PurePosixPath(path) for path in entries]
    if (not paths or len(paths) != len(set(paths))
            or any(path.parent != PurePosixPath(DOWNLOADS)
                   or not re.fullmatch(r"plainsay[^/]*\.dmg", path.name, re.IGNORECASE) for path in paths)):
        raise Stop("Unsafe explicit MacBook inventory")
    listing, files = mac_inventory(user, set(entries))
    check_references(paths)
    for path, size in files.items():
        print(f"PLAN {MAC}:{path} {size} bytes", flush=True)
    print(f"SUMMARY candidates={len(paths)} planned={len(files)} bytes={sum(files.values())} "
          f"dry_run={int(dry_run)}", flush=True)
    if files and not dry_run:
        check_references(paths)
        mac_remove(user, listing, files)
        print(f"REMOVED {len(files)} MacBook paths", flush=True)


def main(macbook=False):
    mode = os.environ.get("DRY_RUN", "1")
    if mode not in {"0", "1"}:
        raise Stop("DRY_RUN must be 0 or 1")
    if os.geteuid() != 0:
        raise Stop("Run on OVH via sudo from the account with the required SSH access")
    check_directory(UPDATE)
    entries = sys.stdin.read().splitlines()
    user = os.environ.get("SUDO_USER")
    if macbook:
        prune_macbook(entries, mode == "1", user)
        return
    with ExitStack() as stack:
        # Use the same inode as the kit even before its first run after a reboot.
        flags = os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK
        try:
            setup = os.open(SETUP_LOCK, flags | (os.O_CREAT if mode == "0" else 0), 0o600)
        except FileNotFoundError as error:
            raise Stop(f"Cannot take the kit lock without creating {SETUP_LOCK}") from error
        stack.callback(os.close, setup)
        if not stat.S_ISREG(os.fstat(setup).st_mode):
            raise Stop("Expected a regular kit lock file")
        fcntl.flock(setup, fcntl.LOCK_EX | fcntl.LOCK_NB)
        root = os.open(UPDATE, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        stack.callback(os.close, root)
        fcntl.flock(root, fcntl.LOCK_EX | fcntl.LOCK_NB)
        prune(entries, mode == "1", user)


if __name__ == "__main__":
    try:
        if sys.argv[1:] not in ([], ["--macbook"]):
            raise Stop("Usage: oneoff-prune-old-copies.sh [--macbook]")
        main(macbook=len(sys.argv) == 2)
    except Stop as error:
        print(f"STOP {error}", file=sys.stderr)
        sys.exit(1)
    except (OSError, ElementTree.ParseError, KeyError, ValueError, TypeError, AttributeError,
            subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
        # Avoid printing remote responses or the SSH command.
        print(f"STOP verification or operation failed ({type(error).__name__})", file=sys.stderr)
        sys.exit(1)
