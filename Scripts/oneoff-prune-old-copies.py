"""Validate the explicit one-off inventory before allowing any deletions."""

import base64
from contextlib import ExitStack
import fcntl
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shlex
import stat
import subprocess
import sys
from urllib.parse import unquote, urlsplit
from xml.etree import ElementTree

UPDATE = Path("/var/www/plainsay-updates")
LAUNCH = Path("/var/backups/plainsay-launch-0.2.24")
APPCAST = "https://api.plainsay.app/appcast.xml"
GITHUB = "https://api.github.com/repos/conrader/plainsay"
CASK = "https://api.github.com/repos/conrader/homebrew-plainsay/contents/Casks/plainsay.rb?ref=main"
VERSION = r"[0-9]+\.[0-9]+\.[0-9]+"
BACKUP_NAME = rf"v{VERSION}\.[A-Za-z0-9]{{6}}"
BACKUP_FILES = {"appcast.xml", "Plainsay-latest.dmg"}
LEGACY_ZIP = "Plainsay-0.2.23.zip"
LAUNCH_VERSION = (0, 2, 24)
LAUNCH_FILES = BACKUP_FILES | {"plainsay-app.tar.gz"}
SETUP_LOCK = Path("/run/plainsay-deploy-setup.lock")
MAC = "macbook-m4"
MINI = "mini-m4"
DOWNLOADS = "/Users/konradsierzputowski/Downloads"


class Stop(Exception):
    pass


def fetch(url):
    try:
        return subprocess.check_output(
            ["curl", "-qfsSL", "--proto", "=https", "--proto-redir", "=https",
             "--max-time", "25", "-H", "Cache-Control: no-cache", url],
            stderr=subprocess.DEVNULL,
        )
    except subprocess.CalledProcessError as error:
        # The fixed source URLs contain no credentials.
        raise Stop(f"HTTPS read failed for {url}") from error


def url_path(url):
    parsed = urlsplit(url)
    if (parsed.scheme != "https" or not parsed.hostname or parsed.username is not None
            or re.search(r"[\s\\\x00-\x1f\x7f]", url) or re.search(r"%(?![0-9a-fA-F]{2})", parsed.path)):
        raise Stop("Expected an absolute HTTPS artifact URL")
    return PurePosixPath(unquote(parsed.path, errors="strict"))


def url_name(url):
    return url_path(url).name


def enclosure_urls(data):
    root = ElementTree.fromstring(data)
    if root.tag != "rss" or root.find("channel") is None:
        raise Stop("Malformed appcast")
    urls = []
    for element in root.iter():
        name = element.tag.rsplit("}", 1)[-1]
        if name in {"enclosure", "delta"}:
            if not element.get("url"):
                raise Stop("Appcast enclosure or delta has no URL")
            urls.append(element.get("url"))
    if not urls:
        raise Stop("Appcast has no enclosures")
    return urls


def cask_names(data):
    # Inspect every stanza, including those in architecture and OS blocks.
    # Consider every literal version for a URL with version interpolation.
    # Unsupported Ruby expressions block the run.
    versions = set()
    templates = []
    # Ruby also accepts a quote immediately after the directive name.
    directive = re.compile(r"\b(version|url)\b")
    literal = re.compile(r"""^\s*(?:\(\s*)?(["'])(.*?)\1\s*(?=$|[,);#}])""")
    for line in data.decode().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        # Consume the string before searching again for inline stanzas.
        while match := directive.search(line):
            rest = line[match.end():]
            value = literal.match(rest)
            if not value or "\\" in value[2]:
                raise Stop("Unsupported Homebrew version or URL stanza")
            if match[1] == "version":
                if not re.fullmatch(VERSION, value[2]):
                    raise Stop("Unsupported Homebrew version")
                versions.add(value[2])
            else:
                if value[1] == "'" and "#{" in value[2]:
                    raise Stop("Unsupported literal Homebrew URL fragment")
                templates.append(value[2])
            line = rest[value.end():]
            if line.startswith("#"):
                break
    if not templates:
        raise Stop("Homebrew cask has no URL stanzas")
    names = set()
    for template in templates:
        if re.search(r"#[{@$]", template.replace("#{version}", "")):
            raise Stop("Unsupported Homebrew URL interpolation")
        if "#{version}" in template:
            if not versions:
                raise Stop("Homebrew URL requires a literal version")
            for version in versions:
                names.update(url_path(template.replace("#{version}", version)).parts)
        else:
            names.update(url_path(template).parts)
    return names


def github_assets(ref):
    release = json.loads(fetch(f"{GITHUB}/releases/{ref}"))
    release_id = release.get("id")
    if type(release_id) is not int or release.get("draft") is not False or release.get("prerelease") is not False:
        raise Stop("Could not confirm a public stable GitHub release")
    if ref.startswith("tags/") and release.get("tag_name") != ref.removeprefix("tags/"):
        raise Stop("GitHub rollback tag mismatch")
    assets = {}
    for page in range(1, 21):
        batch = json.loads(fetch(f"{GITHUB}/releases/{release_id}/assets?per_page=100&page={page}"))
        if not isinstance(batch, list):
            raise Stop("Unexpected GitHub asset response")
        for asset in batch:
            name = asset["name"]
            if PurePosixPath(name).name != name or name in assets:
                raise Stop("Unexpected GitHub asset name")
            assets[name] = asset
        if len(batch) < 100:
            if not assets:
                raise Stop("GitHub release has no visible assets")
            return assets
    raise Stop("GitHub asset pagination exceeded the limit")


def file_info(path):
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or path.resolve(strict=True) != path:
        raise Stop(f"Expected a regular file at {path}")
    return info


def matches_asset(path, asset):
    info = file_info(path)
    with path.open("rb") as content:
        digest = hashlib.file_digest(content, "sha256").hexdigest()
    return info.st_size > 0 and asset.get("size") == info.st_size and asset.get("digest") == f"sha256:{digest}"


def live_references(update):
    urls = enclosure_urls(fetch(APPCAST))
    # Include the origin file in case an HTTPS cache still serves an older feed.
    file_info(update / "appcast.xml")
    urls += enclosure_urls((update / "appcast.xml").read_bytes())
    references = {part for url in urls for part in url_path(url).parts}
    cask = json.loads(fetch(CASK))
    if cask["encoding"] != "base64":
        raise Stop("Unexpected Homebrew cask encoding")
    content = "".join(cask["content"].split())
    references.update(cask_names(base64.b64decode(content, validate=True)))
    latest = github_assets("latest")
    for name, asset in latest.items():
        references.add(name)
        references.update(url_path(asset["browser_download_url"]).parts)
    return {name.casefold() for name in references}


def local_zip(urls):
    names = {url_name(url) for url in urls}
    for url in urls:
        parsed = urlsplit(url)
        if parsed.netloc != "api.plainsay.app" or unquote(parsed.path) != f"/releases/{url_name(url)}":
            raise Stop("Appcast has a nonlocal artifact")
    if len(names) != 1:
        raise Stop("Appcast needs one versioned ZIP")
    return names.pop()


def backup_zip(update, path):
    check_directory(path)
    feed = path / "appcast.xml"
    file_info(feed)
    name = local_zip(enclosure_urls(feed.read_bytes()))
    if not re.fullmatch(rf"Plainsay-{VERSION}\.zip", name):
        raise Stop("Rollback artifact has no supported versioned digest")
    return update / "releases" / name


def verify_rollback(update, path):
    package = backup_zip(update, path)
    name = package.name
    version = package.stem.removeprefix("Plainsay-")
    assets = github_assets(f"tags/v{version}")
    if not matches_asset(package, assets.get(name, {})):
        raise Stop("Rollback ZIP checksum mismatch")
    if not matches_asset(path / "Plainsay-latest.dmg", assets.get(f"Plainsay-{version}.dmg", {})):
        raise Stop("Rollback installer checksum mismatch")
    return package


def check_directory(path):
    if not path.is_dir() or path.resolve(strict=True) != path:
        raise Stop(f"Expected a real directory at {path}")


def backup_directories(update):
    root = update / ".release-backups"
    if not os.path.lexists(root):
        return []
    check_directory(root)
    paths = sorted(root.iterdir())
    if any(not re.fullmatch(BACKUP_NAME, path.name) for path in paths):
        raise Stop(f"Unexpected entries in {root}")
    return paths


def check_backup_dependencies(update, backups, obsolete):
    for path in backups:
        package = backup_zip(update, path)
        if package in obsolete:
            raise Stop(f"{path} still depends on {package.name}")


def unfinished_publication(update):
    return (any(update.glob(".release-stage.*"))
            or os.path.lexists(update / ".release-backups/activation"))


def launch_files():
    check_directory(LAUNCH)
    if {item.name for item in LAUNCH.iterdir()} != LAUNCH_FILES:
        raise Stop(f"Unexpected files in {LAUNCH}")
    return sorted(LAUNCH / name for name in LAUNCH_FILES)


def rollback(candidates):
    if not candidates:
        raise Stop("No saved newer rollback in .release-backups")
    stamps = {path: path.lstat().st_mtime_ns for path in candidates}
    latest = max(stamps.values())
    newest = [path for path, stamp in stamps.items() if stamp == latest]
    if len(newest) != 1:
        raise Stop("Cannot identify a unique newest rollback")
    path, = newest
    check_directory(path)
    if {file.name for file in path.iterdir()} != BACKUP_FILES:
        raise Stop(f"Unexpected files in {path}")
    package = verify_rollback(UPDATE, path)
    version = tuple(map(int, package.stem.removeprefix("Plainsay-").split(".")))
    if version <= LAUNCH_VERSION:
        raise Stop("Newest verified rollback must be newer than v0.2.24")
    return path, package


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
    except (OSError, subprocess.CalledProcessError, subprocess.TimeoutExpired):
        return None, {}
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
    return (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns)


def check_rollback(paths):
    if unfinished_publication(UPDATE):
        raise Stop("update root contains an unfinished publication")
    backups = backup_directories(UPDATE)
    retained, package = rollback(backups)
    if {retained.name.casefold(), package.name.casefold()} & {p.name.casefold() for p in paths}:
        raise Stop("a candidate matches the newest verified rollback")
    check_backup_dependencies(UPDATE, backups, paths)
    return retained, package


def verify_ovh(paths, user):
    errors = []
    for check in (lambda: check_release_pause(user), lambda: check_references(paths)):
        try:
            check()
        except Stop as error:
            errors.append(str(error))
    try:
        retained = check_rollback(paths)
        if os.path.lexists(LAUNCH) and backup_zip(UPDATE, LAUNCH) != UPDATE / "releases" / LEGACY_ZIP:
            raise Stop(f"Unexpected launch rollback dependency in {LAUNCH}")
    except Stop as error:
        errors.append(str(error))
    if errors:
        raise Stop("\nSTOP ".join(errors))
    return retained


def ovh_inventory(paths):
    check_directory(UPDATE / "releases")
    return {path: {file: file_identity(file) for file in (launch_files() if path == LAUNCH else [path])}
            for path in paths if os.path.lexists(path)}


def prune(entries, dry_run, user):
    local = [Path(path) for path in entries]
    legacy_zip = UPDATE / "releases" / LEGACY_ZIP
    if (len(local) != len(set(local)) or not {LAUNCH, legacy_zip} <= set(local)
            or any(path != LAUNCH and (path.parent != legacy_zip.parent
                   or not re.fullmatch(rf"Plainsay-{VERSION}\.zip", path.name)) for path in local)):
        raise Stop("Unsafe explicit OVH inventory")

    # Remove the launch backup before unlinking its ZIP.
    paths = [LAUNCH, *(path for path in local if path != LAUNCH)]
    inventory = ovh_inventory(paths)
    plans = {path: sum(file[2] for file in files.values()) for path, files in inventory.items()}
    size = sum(plans.values())
    print(f"INVENTORY ovh candidates={len(local)} present={len(plans)} bytes={size} dry_run={int(dry_run)}",
          flush=True)
    for path in paths:
        if path not in inventory:
            print(f"MISSING {path}", flush=True)
    if LAUNCH in inventory and legacy_zip not in inventory:
        raise Stop("Launch backup ZIP is missing")
    retained, package = verify_ovh(paths, user)
    print(f"KEEP verified rollback {retained}", flush=True)
    print(f"KEEP rollback artifact {package}", flush=True)
    for path, path_size in plans.items():
        print(f"PLAN ovh:{path} {path_size} bytes", flush=True)
    print(f"SUMMARY candidates={len(local)} planned={len(plans)} bytes={size} dry_run={int(dry_run)}", flush=True)
    if dry_run:
        return
    verify_ovh(paths, user)
    if ovh_inventory(paths) != inventory:
        raise Stop("OVH inventory changed during verification")
    for path, files in inventory.items():
        for file in files:
            file.unlink()
        if path == LAUNCH:
            path.rmdir()
    print(f"REMOVED {len(plans)} paths ({size} bytes)", flush=True)


def prune_macbook(entries, dry_run, user):
    paths = [PurePosixPath(path) for path in entries]
    if (not paths or len(paths) != len(set(paths))
            or any(path.parent != PurePosixPath(DOWNLOADS)
                   or not re.fullmatch(r"plainsay[^/]*\.dmg", path.name, re.IGNORECASE) for path in paths)):
        raise Stop("Unsafe explicit MacBook inventory")
    listing, files = mac_inventory(user, set(entries))
    if listing is None:
        print(f"SKIP {MAC} Downloads inventory unavailable", flush=True)
        return
    check_references(paths)
    check_rollback(paths)
    for path, size in files.items():
        print(f"PLAN {MAC}:{path} {size} bytes", flush=True)
    print(f"SUMMARY candidates={len(paths)} planned={len(files)} bytes={sum(files.values())} "
          f"dry_run={int(dry_run)}", flush=True)
    if files and not dry_run:
        check_references(paths)
        check_rollback(paths)
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
        if macbook:
            prune_macbook(entries, mode == "1", user)
        else:
            prune(entries, mode == "1", user)


if __name__ == "__main__":
    try:
        if sys.argv[1:] not in ([], ["--macbook"]):
            raise Stop("Usage: oneoff-prune-old-copies.sh [--macbook]")
        main(macbook=len(sys.argv) == 2)
    except (Stop, OSError, ElementTree.ParseError, KeyError, ValueError, TypeError, AttributeError,
            subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
        # Avoid printing remote responses or the SSH command.
        reason = str(error) if isinstance(error, Stop) else f"verification or operation failed ({type(error).__name__})"
        print(f"STOP {reason}", file=sys.stderr, flush=True)
        if os.environ.get("DRY_RUN", "1") == "1":
            print("SUMMARY planned=0 bytes=0 dry_run=1", flush=True)
        sys.exit(1)
