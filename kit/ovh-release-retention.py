#!/usr/bin/python3
"""Activate and retain a Plainsay release on the update host."""

from contextlib import contextmanager
import fcntl
import hashlib
import os
from pathlib import Path
import re
import shutil
import stat
import sys
import tarfile
import tempfile
from urllib.parse import urlsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener
import xml.etree.ElementTree as ET

UPDATES = Path("/var/www/plainsay-updates")
ORIGIN = "https://api.plainsay.app"
DMG = "releases/Plainsay-latest.dmg"
FEED = "appcast.xml"
SPARKLE_VERSION = "{http://www.andymatuschak.org/xml-namespaces/sparkle}version"
VERSION = r"[0-9]+\.[0-9]+\.[0-9]+"
BACKUP = rf"v{VERSION}\.[a-zA-Z0-9_]{{6,8}}"
STAGE = r"\.release-stage\.[a-zA-Z0-9]{6}"
SHA = r"[a-f0-9]{64}"
ARTIFACT = r"Plainsay[a-zA-Z0-9._-]*\.(?:dmg|zip|delta|tar\.gz|tar|tgz|aar|pkg|tbz2|txz)|[a-zA-Z0-9._-]+\.delta"


def require(condition, reason):
    if not condition:
        raise ValueError(reason)


def regular(path):
    require(stat.S_ISREG(path.lstat().st_mode), f"Expected a regular file at {path}")
    return path


def directory(path):
    require(path.resolve(strict=True) == path and path.is_dir(), f"Expected a real directory at {path}")
    return path


def digest(stream):
    checksum = hashlib.sha256()
    for block in iter(lambda: stream.read(1024 * 1024), b""):
        checksum.update(block)
    return checksum.hexdigest()


def file_digest(path):
    with regular(path).open("rb") as stream:
        return digest(stream)


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def verify_live(relative, checksum):
    request = Request(f"{ORIGIN}/{relative}", headers={"Cache-Control": "no-cache"})
    with build_opener(NoRedirect()).open(request, timeout=30) as response:
        require(response.status == 200 and digest(response) == checksum,
                f"Public HTTP status or checksum mismatch for {relative}")


def appcast(feed):
    """Return the newest Sparkle build and all local enclosure paths."""
    root = ET.fromstring(feed)
    require(root.tag == "rss" and root.find("channel") is not None, "Expected an RSS appcast")
    require(not any("{http://www.w3.org/XML/1998/namespace}base" in node.attrib for node in root.iter()),
            "Appcast xml:base is unsupported")
    assets = set()
    count = 0
    for node in root.iter():
        if node.tag.rsplit("}", 1)[-1] != "enclosure":
            continue
        count += 1
        url = urlsplit(node.get("url", ""))
        require(url.scheme == "https" and url.hostname, "Expected an absolute HTTPS enclosure URL")
        if url.hostname != urlsplit(ORIGIN).hostname:
            continue
        require(url.netloc == urlsplit(ORIGIN).netloc and
                re.fullmatch(r"/releases/[a-zA-Z0-9][a-zA-Z0-9._-]*", url.path),
                "Unsupported local enclosure path")
        assets.add(url.path[1:])
    require(count > 0, "Appcast contains no enclosures")
    builds = [node.text or "" for node in root.iter(SPARKLE_VERSION)]
    require(builds and all(re.fullmatch(r"[1-9][0-9]{0,8}", build) for build in builds),
            "Expected numeric Sparkle builds")
    return max(map(int, builds)), assets


def backup(root, version):
    backups = directory(root / ".release-backups")
    feed = regular(root / FEED).read_bytes()
    expected = {FEED: hashlib.sha256(feed).hexdigest()}
    _, assets = appcast(feed)
    for relative in sorted(assets | {DMG}):
        expected[relative] = file_digest(root / relative)
    for relative, checksum in expected.items():
        verify_live(relative, checksum)

    # The archive lives in the HTTP-denied backup directory. Both deploy
    # accounts can read it there, and rotation can unlink it from the parent.
    with tempfile.NamedTemporaryFile(prefix=f"v{version}.", suffix=".tar", dir=backups,
                                    delete=False) as temp:
        path = Path(temp.name)
    try:
        with tarfile.open(path, "w") as archive:
            for relative in expected:
                archive.add(regular(root / relative), arcname=relative, recursive=False)
        with tarfile.open(path, "r") as archive:
            require(all(digest(archive.extractfile(relative)) == checksum for relative, checksum in expected.items()),
                    "Rollback archive differs from the verified public files")
        path.chmod(0o644)
        return f"{path.name} {file_digest(path)}"
    except BaseException:
        path.unlink()
        raise


def activate(root, version, stage, archive, expected):
    stage = directory(root / stage)
    zip_name = f"Plainsay-{version}.zip"
    dmg_name = f"Plainsay-{version}.dmg"
    with tarfile.open(archive, "r") as rollback:
        previous_feed = rollback.extractfile(FEED).read()
        require(hashlib.sha256(previous_feed).hexdigest() == file_digest(root / FEED) and
                digest(rollback.extractfile(DMG)) == file_digest(root / DMG),
                "Live release changed after its rollback archive was taken")
    previous_build, _ = appcast(previous_feed)
    build, assets = appcast(regular(stage / FEED).read_bytes())
    require(build > previous_build, "Staged Sparkle build must exceed the current build")
    require(f"releases/{zip_name}" in assets, "Staged feed is missing the new ZIP")
    for path, checksum in zip((stage / zip_name, stage / dmg_name, stage / FEED), expected):
        require(file_digest(path) == checksum, f"Staged checksum mismatch for {path.name}")
        path.chmod(0o644)
    target_zip = root / "releases" / zip_name
    require(not target_zip.exists() and not target_zip.is_symlink(), "Versioned ZIP already exists")
    (stage / zip_name).replace(target_zip)
    (stage / dmg_name).replace(root / DMG)
    (stage / FEED).replace(root / FEED)
    stage.rmdir()


def prune(root, version, archive, expected):
    feed = regular(root / FEED).read_bytes()
    _, assets = appcast(feed)
    zip_path = f"releases/Plainsay-{version}.zip"
    require(zip_path in assets, "Live appcast does not contain the uploaded ZIP")
    zip_sha, dmg_sha, feed_sha = expected
    require(hashlib.sha256(feed).hexdigest() == feed_sha, "Live appcast changed")
    checksums = {FEED: feed_sha, DMG: dmg_sha, zip_path: zip_sha}
    for relative in sorted(assets - checksums.keys()):
        checksums[relative] = file_digest(root / relative)
    for relative, checksum in checksums.items():
        require(file_digest(root / relative) == checksum, f"Live file changed at {relative}")
        verify_live(relative, checksum)

    # Plan every backup removal before unlinking anything, so an unremovable
    # backup cannot interrupt the prune halfway. A backup for a newer version
    # belongs to a publisher that has not activated yet and must survive.
    live = version_key(version)
    doomed = []
    for path in sorted(archive.parent.iterdir()):
        match = re.fullmatch(rf"v({VERSION})\.[a-zA-Z0-9_]{{6,8}}(\.tar)?", path.name)
        if path == archive or not match or version_key(match[1]) > live:
            continue
        mode = path.lstat().st_mode
        if stat.S_ISREG(mode) or (stat.S_ISDIR(mode) and not match[2] and removable(path)):
            doomed.append(path)
        elif stat.S_ISDIR(mode) and not match[2]:
            print(f"plainsay retention: kept unremovable legacy backup {path}", file=sys.stderr)

    for path in sorted((root / "releases").iterdir()):
        if re.fullmatch(ARTIFACT, path.name) and f"releases/{path.name}" not in checksums:
            if stat.S_ISREG(path.lstat().st_mode):
                path.unlink()
    for path in doomed:
        if path.is_dir() and not path.is_symlink():
            shutil.rmtree(path)
        else:
            path.unlink()


def version_key(version):
    return tuple(map(int, version.split(".")))


def removable(top):
    """Make a backup tree owned by this account deletable; report whether it is."""
    uid = os.geteuid()

    def grant(path):
        info = os.lstat(path)
        if stat.S_ISDIR(info.st_mode) and info.st_uid == uid:
            os.chmod(path, stat.S_IMODE(info.st_mode) | stat.S_IRWXU)

    def fail(error):
        raise error

    try:
        grant(top)
        for parent, dirs, _ in os.walk(top, onerror=fail):
            if not os.access(parent, os.R_OK | os.W_OK | os.X_OK):
                return False
            for name in dirs:
                grant(os.path.join(parent, name))
    except OSError:
        return False
    return True


@contextmanager
def release_lock(root):
    lock = os.open(directory(root), os.O_RDONLY | os.O_DIRECTORY)
    try:
        fcntl.flock(lock, fcntl.LOCK_EX)
        yield
    finally:
        os.close(lock)


def run(root, args):
    directory(root / "releases")
    with release_lock(root):
        if args == ["check"]:
            directory(root / ".release-backups")
            return
        require(len(args) >= 2, "Invalid release operation")
        action, version, *args = args
        require(re.fullmatch(VERSION, version), "Invalid release version")
        if action == "backup" and not args:
            return backup(root, version)
        stage = None
        if action == "activate":
            require(len(args) == 6, "Invalid release activation")
            stage, *args = args
            require(re.fullmatch(STAGE, stage), "Invalid release stage")
        require(action in ("activate", "prune") and len(args) == 5, "Invalid release operation")
        name, archive_sha, *expected = args
        require(re.fullmatch(rf"{BACKUP}\.tar", name) and name.startswith(f"v{version}."),
                "Invalid rollback archive")
        require(all(re.fullmatch(SHA, checksum) for checksum in (archive_sha, *expected)),
                "Invalid release checksum")
        archive = directory(root / ".release-backups") / name
        require(file_digest(archive) == archive_sha, "Rollback archive checksum mismatch")
        if action == "activate":
            activate(root, version, stage, archive, expected)
        else:
            prune(root, version, archive, expected)


if __name__ == "__main__":
    try:
        result = run(UPDATES, sys.argv[1:])
        if result:
            print(result)
    except (OSError, ValueError, ET.ParseError, tarfile.TarError) as error:
        sys.exit(f"plainsay retention: {error}")
