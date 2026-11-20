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
import tarfile
from xml.etree import ElementTree

from plainsay_release_retention import (
    Stop, UPDATE, VERSION, backup_directories, file_info, live_references,
    unfinished_publication, verify_rollback,
)

LAUNCH = Path("/var/backups/plainsay-launch-0.2.24")
SETUP_LOCK = Path("/run/plainsay-deploy-setup.lock")
MAC = "macbook-m4"
MINI = "mini-m4"
DOWNLOADS = "/Users/konradsierzputowski/Downloads"
LAUNCH_FILES = {"appcast.xml", "Plainsay-latest.dmg", "plainsay-app.tar.gz"}


def launch_files():
    if LAUNCH.resolve(strict=True) != LAUNCH or {item.name for item in LAUNCH.iterdir()} != LAUNCH_FILES:
        raise Stop(f"Unexpected files in {LAUNCH}")
    return sorted(LAUNCH / name for name in LAUNCH_FILES)


def rollback():
    candidates = backup_directories(UPDATE)
    if LAUNCH.exists() or LAUNCH.is_symlink():
        candidates.append(LAUNCH)
    if candidates:
        path = max(candidates, key=lambda item: (item.lstat().st_mtime_ns, item.name))
        try:
            if not path.is_dir() or path.resolve(strict=True) != path:
                raise Stop("Unsafe rollback directory")
            package = verify_rollback(UPDATE, path)
            if path == LAUNCH:
                launch_files()
                archive = path / "plainsay-app.tar.gz"
                file_info(archive)
                subprocess.run(["gzip", "-t", "--", archive], check=True, stderr=subprocess.DEVNULL)
                with tarfile.open(archive) as site:
                    if not any(member.name == "plainsay-app/index.html" and member.isfile() and member.size
                               for member in site.getmembers()):
                        raise Stop("Rollback site archive has no index")
            return path, {package}
        except (Stop, OSError, KeyError, ValueError, ElementTree.ParseError, tarfile.TarError,
                subprocess.CalledProcessError) as error:
            raise Stop(f"Unverified newest OVH release rollback {path}") from error
    raise Stop("No verified OVH release rollback")


MAC_LIST = f"""set -eu
test "$HOME/Downloads" = {shlex.quote(DOWNLOADS)}
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
               "-o", "ConnectTimeout=8", host, f"/bin/sh -c {shlex.quote(script)}"]
    if user:
        command = ["sudo", "-n", "-H", "-u", user, *command]
    return subprocess.check_output(command, text=True, stderr=subprocess.DEVNULL, timeout=15)


def check_release_pause(user):
    try:
        if ssh(user, MINI, PAUSE_CHECK) == "paused\n":
            return
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
        pass
    raise Stop(f"{MINI} release pause could not be verified (nightly.lock/oneoff-prune)")


def mac_inventory(user, expected):
    try:
        raw = ssh(user, MAC, MAC_LIST)
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
        raise Stop(f"{MAC} Downloads inventory unavailable") from error
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


def prune(entries, dry_run, user):
    local = [Path(path) for path in entries if not path.startswith(f"{MAC}:")]
    mac = [path.removeprefix(f"{MAC}:") for path in entries if path.startswith(f"{MAC}:")]
    if (len(entries) != len(set(entries)) or not mac
            or any(path != LAUNCH and (path.parent != UPDATE / "releases"
                   or not re.fullmatch(rf"Plainsay-{VERSION}\.zip", path.name)) for path in local)
            or any(PurePosixPath(path).parent != PurePosixPath(DOWNLOADS)
                   or not re.fullmatch(r"plainsay[^/]*\.dmg", PurePosixPath(path).name, re.IGNORECASE) for path in mac)):
        raise Stop("Unsafe explicit inventory")

    errors = []
    try:
        check_release_pause(user)
    except Stop as error:
        errors.append(str(error))
    candidates = local + [Path(path) for path in mac]
    references = live_references(UPDATE)
    protected = {path for path in candidates if path.name.casefold() in references}
    errors.extend(f"live reference matches {path}" for path in sorted(protected))
    if unfinished_publication(UPDATE):
        errors.append("update root contains an unfinished publication")
    retained, dependencies = rollback()
    print(f"KEEP verified rollback {retained}", flush=True)
    for path in sorted(dependencies):
        print(f"KEEP rollback artifact {path}", flush=True)

    plans = {}
    inventory = {}
    for path in local:
        if path in protected or path == retained or path in dependencies:
            continue
        if not os.path.lexists(path):
            print(f"MISSING {path}", flush=True)
            continue
        files = launch_files() if path == LAUNCH else [path]
        for file in files:
            info = file_info(file)
            inventory[file] = (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns)
        plans[path] = sum(inventory[file][2] for file in files)
    mac_files = {}
    listing = ""
    try:
        listing, mac_files = mac_inventory(user, set(mac))
    except Stop as error:
        errors.append(str(error))
    for path, size in plans.items():
        print(f"PLAN ovh:{path} {size} bytes", flush=True)
    mac_files = {path: size for path, size in mac_files.items() if Path(path) not in protected}
    for path, size in mac_files.items():
        print(f"PLAN {MAC}:{path} {size} bytes", flush=True)
    count = len(plans) + len(mac_files)
    size = sum(plans.values()) + sum(mac_files.values())
    print(f"SUMMARY candidates={len(entries)} planned={count} bytes={size} dry_run={int(dry_run)}", flush=True)
    if errors:
        raise Stop("; ".join(errors))
    if dry_run:
        return
    for file, expected in inventory.items():
        info = file_info(file)
        if (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns) != expected:
            raise Stop(f"Inventory changed at {file}")
    references = live_references(UPDATE)
    newly_referenced = [str(path) for path in candidates if path.name.casefold() in references]
    if newly_referenced:
        raise Stop(f"live reference matches {', '.join(newly_referenced)}")
    if unfinished_publication(UPDATE):
        raise Stop("update root contains an unfinished publication")
    check_release_pause(user)
    if mac_files:
        mac_remove(user, listing, mac_files)
    for path in plans:
        if path == LAUNCH:
            for file in launch_files():
                file.unlink()
            path.rmdir()
        else:
            path.unlink()
    print(f"REMOVED {count} paths ({size} bytes)", flush=True)


def main():
    mode = os.environ["DRY_RUN"]
    if mode not in {"0", "1"}:
        raise Stop("DRY_RUN must be 0 or 1")
    if os.geteuid() != 0:
        raise Stop("Run on OVH via sudo from the MacBook SSH account")
    if UPDATE.resolve(strict=True) != UPDATE:
        raise Stop("Unsafe update root")
    with ExitStack() as stack:
        # Use the same inode as the kit even before its first run after a reboot.
        setup = os.open(SETUP_LOCK, os.O_CREAT | os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600)
        stack.callback(os.close, setup)
        if not stat.S_ISREG(os.fstat(setup).st_mode):
            raise Stop("Expected a regular kit lock file")
        fcntl.flock(setup, fcntl.LOCK_EX | fcntl.LOCK_NB)
        root = os.open(UPDATE, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        stack.callback(os.close, root)
        fcntl.flock(root, fcntl.LOCK_EX | fcntl.LOCK_NB)
        prune(sys.stdin.read().splitlines(), mode == "1", os.environ.get("SUDO_USER"))


if __name__ == "__main__":
    try:
        main()
    except Stop as error:
        print(f"STOP {error}", file=sys.stderr)
        sys.exit(1)
    except (OSError, ElementTree.ParseError, KeyError, ValueError, TypeError, AttributeError,
            subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
        # Avoid printing remote responses or the SSH command.
        print(f"STOP verification or operation failed ({type(error).__name__})", file=sys.stderr)
        sys.exit(1)
