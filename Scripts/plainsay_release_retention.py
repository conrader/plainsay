"""Verify release artifacts and prune the OVH release inventory after publication."""

import base64
import fcntl
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
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
    if parsed.scheme != "https" or not parsed.hostname:
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


def live_references(update, expected_zip=None):
    urls = enclosure_urls(fetch(APPCAST))
    # Include the origin file in case an HTTPS cache still serves an older feed.
    file_info(update / "appcast.xml")
    urls += enclosure_urls((update / "appcast.xml").read_bytes())
    references = {part for url in urls for part in url_path(url).parts}
    if expected_zip is not None and local_zip(urls) != expected_zip:
        raise Stop("Hosted and origin appcasts must reference the new ZIP")
    cask = json.loads(fetch(CASK))
    if cask["encoding"] != "base64":
        raise Stop("Unexpected Homebrew cask encoding")
    content = "".join(cask["content"].split())
    references.update(cask_names(base64.b64decode(content, validate=True)))
    latest = github_assets("latest")
    if expected_zip is not None and expected_zip not in latest:
        raise Stop("GitHub Latest does not contain the new ZIP")
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


def verify_rollback(update, path, *, expected_zip=None):
    package = backup_zip(update, path)
    name = package.name
    if expected_zip is not None and name != expected_zip:
        raise Stop(f"Newest OVH release rollback {path} does not enclose {expected_zip}")
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


def plan_retention(update, version, backup):
    check_directory(update / "releases")
    if unfinished_publication(update):
        raise Stop("Update root contains an unfinished publication")
    backups = backup_directories(update)
    if backup not in backups or backup != max(backups, key=lambda path: (path.lstat().st_mtime_ns, path.name)):
        raise Stop("Expected the just-created backup to be newest")
    files_by_backup = {}
    for path in backups:
        check_directory(path)
        files = sorted(path.iterdir())
        names = {file.name for file in files}
        if not names <= BACKUP_FILES or (path == backup and names != BACKUP_FILES):
            raise Stop(f"Unexpected files in {path}")
        for file in files:
            file_info(file)
        if path != backup:
            files_by_backup[path] = files

    live = update / "releases" / f"Plainsay-{version}.zip"
    file_info(live)
    previous = verify_rollback(update, backup)
    if live == previous:
        raise Stop("Expected distinct live and rollback ZIPs")
    obsolete = sorted(path for path in live.parent.iterdir()
                      if re.fullmatch(rf"Plainsay-{VERSION}\.zip", path.name) and path not in {live, previous})
    for path in obsolete:
        file_info(path)
    return live, previous, obsolete, files_by_backup


def retain(update, version, backup):
    check_directory(update)
    fd = os.open(update, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        live, previous, obsolete, backups = plan_retention(update, version, backup)
        references = live_references(update, expected_zip=live.name)
        hits = [path.name for path in [*obsolete, *backups] if path.name.casefold() in references]
        if hits:
            raise Stop(f"Live reference matches {', '.join(hits)}")
        if unfinished_publication(update):
            raise Stop("Update root contains an unfinished publication")
        if os.path.lexists(LAUNCH):
            check_backup_dependencies(update, [LAUNCH], obsolete)
        # Remove backup directories first so a failed cleanup can't strand an
        # older backup with a missing ZIP. The verified rollback stays intact.
        for path, files in sorted(backups.items()):
            for file in files:
                file.unlink()
            path.rmdir()
        for path in obsolete:
            path.unlink()
        print(f"KEEP {live.name}, {previous.name}, {backup.name} "
              f"removed_zips={len(obsolete)} removed_backups={len(backups)}")
    finally:
        os.close(fd)


if __name__ == "__main__":
    try:
        if (len(sys.argv) != 3 or not re.fullmatch(VERSION, sys.argv[1])
                or not re.fullmatch(rf"v{re.escape(sys.argv[1])}\.[A-Za-z0-9]{{6}}", sys.argv[2])):
            raise Stop("Expected a release version and release backup name")
        retain(UPDATE, sys.argv[1], UPDATE / ".release-backups" / sys.argv[2])
    except Stop as error:
        print(f"STOP {error}", file=sys.stderr)
        sys.exit(1)
    except (OSError, ValueError, TypeError, KeyError, AttributeError, ElementTree.ParseError) as error:
        print(f"STOP release retention failed ({type(error).__name__})", file=sys.stderr)
        sys.exit(1)
