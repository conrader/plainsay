"""Validate the explicit one-off inventory before allowing any deletions."""

from contextlib import ExitStack
import base64
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
import tarfile
from urllib.parse import unquote, urlsplit
from xml.etree import ElementTree

UPDATE = Path("/var/www/plainsay-updates")
LAUNCH = Path("/var/backups/plainsay-launch-0.2.24")
SETUP_LOCK = Path("/run/plainsay-deploy-setup.lock")
MAC = "macbook-m4"
DOWNLOADS = "/Users/konradsierzputowski/Downloads"
APPCAST = "https://api.plainsay.app/appcast.xml"
GITHUB = "https://api.github.com/repos/conrader/plainsay"
CASK = "https://api.github.com/repos/conrader/homebrew-plainsay/contents/Casks/plainsay.rb?ref=main"
VERSION = r"\d+\.\d+\.\d+"
LAUNCH_FILES = {"appcast.xml", "Plainsay-latest.dmg", "plainsay-app.tar.gz"}


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


def url_name(url):
    parsed = urlsplit(url)
    if parsed.scheme != "https" or not parsed.hostname:
        raise Stop("Expected an absolute HTTPS artifact URL")
    return PurePosixPath(unquote(parsed.path, errors="strict")).name


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
    directive = re.compile(r"\b(version|url)\b(?=\s|\(|$)")
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
        if "#{" in template.replace("#{version}", ""):
            raise Stop("Unsupported Homebrew URL interpolation")
        if "#{version}" in template:
            if not versions:
                raise Stop("Homebrew URL requires a literal version")
            names.update(url_name(template.replace("#{version}", v)) for v in versions)
        else:
            names.add(url_name(template))
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


def live_references():
    urls = enclosure_urls(fetch(APPCAST))
    # Include the origin file in case an HTTPS cache still serves an older feed.
    file_info(UPDATE / "appcast.xml")
    urls += enclosure_urls((UPDATE / "appcast.xml").read_bytes())
    references = {url_name(url) for url in urls}
    cask = json.loads(fetch(CASK))
    if cask["encoding"] != "base64":
        raise Stop("Unexpected Homebrew cask encoding")
    content = "".join(cask["content"].split())
    references.update(cask_names(base64.b64decode(content, validate=True)))
    for name, asset in github_assets("latest").items():
        references.update((name, url_name(asset["browser_download_url"])))
    return {name.casefold() for name in references}


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


def launch_files():
    if LAUNCH.resolve(strict=True) != LAUNCH or {item.name for item in LAUNCH.iterdir()} != LAUNCH_FILES:
        raise Stop(f"Unexpected files in {LAUNCH}")
    return sorted(LAUNCH / name for name in LAUNCH_FILES)


def rollback():
    backups = UPDATE / ".release-backups"
    candidates = []
    if backups.exists():
        if backups.resolve(strict=True) != backups or not backups.is_dir():
            raise Stop("Unsafe rollback backup root")
        candidates.extend(path for path in backups.iterdir()
                          if re.fullmatch(rf"v{VERSION}\.[A-Za-z0-9]{{6}}", path.name))
    if LAUNCH.exists() or LAUNCH.is_symlink():
        candidates.append(LAUNCH)
    for path in sorted(candidates, key=lambda item: (item.lstat().st_mtime_ns, item.name), reverse=True):
        try:
            if not path.is_dir() or path.resolve(strict=True) != path:
                raise Stop("Unsafe rollback directory")
            feed = path / "appcast.xml"
            file_info(feed)
            urls = enclosure_urls(feed.read_bytes())
            names = {url_name(url) for url in urls}
            for url in urls:
                parsed = urlsplit(url)
                if parsed.netloc != "api.plainsay.app" or unquote(parsed.path) != f"/releases/{url_name(url)}":
                    raise Stop("Rollback feed has a nonlocal artifact")
            if len(names) != 1:
                raise Stop("Rollback appcast needs one versioned ZIP")
            name = names.pop()
            match = re.fullmatch(rf"Plainsay-({VERSION})\.zip", name)
            if not match:
                raise Stop("Rollback artifact has no supported versioned digest")
            version = match[1]
            assets = github_assets(f"tags/v{version}")
            package = UPDATE / "releases" / name
            if not matches_asset(package, assets[name]):
                raise Stop("Rollback ZIP checksum mismatch")
            if not matches_asset(path / "Plainsay-latest.dmg", assets[f"Plainsay-{version}.dmg"]):
                raise Stop("Rollback installer checksum mismatch")
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
                subprocess.CalledProcessError):
            print(f"SKIP unverified rollback {path}", flush=True)
    raise Stop("No verified OVH release rollback")


MAC_LIST = f"""set -eu
test "$HOME/Downloads" = {shlex.quote(DOWNLOADS)}
for f in "$HOME"/Downloads/[Pp][Ll][Aa][Ii][Nn][Ss][Aa][Yy]*.[Dd][Mm][Gg]; do
    [ -e "$f" ] || [ -L "$f" ] || continue
    LC_ALL=C ls -ldn "$f"
done
"""


def mac_ssh(user, script):
    command = ["ssh", "-n", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes",
               "-o", "ConnectTimeout=8", MAC, f"/bin/sh -c {shlex.quote(script)}"]
    if user:
        command = ["sudo", "-n", "-H", "-u", user, *command]
    return subprocess.check_output(command, text=True, stderr=subprocess.DEVNULL, timeout=15)


def mac_inventory(user, expected):
    try:
        raw = mac_ssh(user, MAC_LIST)
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
    mac_ssh(user, f"set -eu\nlisting=$(/bin/sh -c {shlex.quote(MAC_LIST)})\n"
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
    candidates = local + [Path(path) for path in mac]
    references = live_references()
    protected = {path for path in candidates if path.name.casefold() in references}
    errors.extend(f"live reference matches {path}" for path in sorted(protected))
    if list(UPDATE.glob(".release-stage.*")) or os.path.lexists(UPDATE / ".release-backups/activation"):
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
    references = live_references()
    newly_referenced = [str(path) for path in candidates if path.name.casefold() in references]
    if newly_referenced:
        raise Stop(f"live reference matches {', '.join(newly_referenced)}")
    if list(UPDATE.glob(".release-stage.*")) or os.path.lexists(UPDATE / ".release-backups/activation"):
        raise Stop("update root contains an unfinished publication")
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
        # Take the kit lock when present, then the update-root directory lock.
        if os.path.lexists(SETUP_LOCK):
            setup = os.open(SETUP_LOCK, os.O_RDONLY | os.O_NOFOLLOW)
            stack.callback(os.close, setup)
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
