#!/usr/bin/env python3
"""Offline coverage for atomic installation, off-box retention, and the park."""

import base64
from contextlib import redirect_stdout
import fcntl
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / "Scripts"


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, SCRIPTS / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


OFFBOX = load("offbox", "plainsay-offbox-backup.py")
PARK = load("park", "oneoff-prune-old-copies.py")


class OnboxRetention(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory(prefix="plainsay-onbox-fixture-")
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.backups = self.root / "backups"
        self.backups.mkdir()
        self.source = self.root / "plainsay.db"
        subprocess.run(["sqlite3", self.source, "CREATE TABLE fixture (id); INSERT INTO fixture VALUES (42);"],
                       check=True)
        self.older = self.backups / "plainsay-daily-20200101T000000Z.db"
        self.older.write_bytes(b"previous snapshot")
        self.other = self.backups / "pre-deploy.db"
        self.other.write_bytes(b"manual snapshot")

    def produce(self):
        return subprocess.run(
            ["bash", "-c", 'source "$1"; backup_database "$2" "$3"', "_",
             SCRIPTS / "plainsay-db-backup.sh", self.source, self.backups],
            capture_output=True, text=True,
        )

    def test_publish_standalone_verified_database_then_prune(self):
        output = self.produce()
        self.assertEqual(output.returncode, 0, output.stderr)
        self.assertIn("integrity=ok retention=1", output.stdout)
        self.assertFalse(self.older.exists())
        self.assertTrue(self.other.exists())
        new, = self.backups.glob("plainsay-daily-*.db")
        report = subprocess.check_output(
            ["sqlite3", "-readonly", new, "PRAGMA integrity_check;", "SELECT id FROM fixture;"], text=True)
        self.assertEqual(report, "ok\n42\n")
        self.assertEqual(new.stat().st_mode & 0o777, 0o600)
        self.assertFalse(list(self.backups.glob(".plainsay-backup.*")))

    def test_failed_copy_leaves_previous_database(self):
        self.source.write_bytes(b"corrupt snapshot")
        self.assertNotEqual(self.produce().returncode, 0)
        self.assertEqual(list(self.backups.glob("plainsay-daily-*.db")), [self.older])
        self.assertFalse(list(self.backups.glob(".plainsay-backup.*")))

    def test_age_rotation_exempts_daily_backups(self):
        os.utime(self.older, (1, 1))
        os.utime(self.other, (1, 1))
        subprocess.run(
            ["bash", "-c", 'source "$1"; rotate_manual_backups "$2"', "_",
             SCRIPTS / "plainsay-backup-rotate.sh", self.root],
            check=True, capture_output=True,
        )
        self.assertFalse(self.other.exists())
        self.assertTrue(self.older.exists())


class OffboxRetention(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory(prefix="plainsay-offbox-fixture-")
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.remote = self.root / "offbox"
        self.remote.mkdir()
        self.source = self.root / "live.db"
        subprocess.run(["sqlite3", self.source, "CREATE TABLE fixture (id); INSERT INTO fixture VALUES (42);"],
                       check=True)
        self.older = self.remote / "plainsay-20200101T000000Z.db.age"
        self.older.write_bytes(b"previous snapshot")
        self.other = self.remote / "plainsay-existing-unmanaged.db.age"
        self.other.write_bytes(b"unmanaged")
        self.corruption = ""
        original_run = OFFBOX.run

        def run(command, step, timeout=120):
            if command[0] == "fixture-ssh":
                if step.startswith("verify,") and self.corruption == "published":
                    script = command[-1].replace('test ! -e ', 'printf broken > "$(ls plainsay-20*.db.age | sort | tail -1)"\ntest ! -e ', 1)
                else:
                    script = command[-1]
                return original_run(["/bin/sh", "-c", script], step, timeout)
            if command[0] == "fixture-scp":
                destination = Path(command[-1].split(":", 1)[1])
                destination.write_bytes(b"broken" if self.corruption == "upload" else Path(command[1]).read_bytes())
                return b""
            if command[0] == "/usr/bin/age":
                Path(command[4]).write_bytes(b"fixture ciphertext " + Path(command[5]).read_bytes())
                return b""
            return original_run(command, step, timeout)

        settings = patch.multiple(OFFBOX, REMOTE=str(self.remote), SSH=["fixture-ssh"], SCP=["fixture-scp"],
                                  SQLITE=["/usr/bin/sqlite3", "-readonly"], source_file=lambda: self.source,
                                  run=run, log=lambda message: None)
        settings.start()
        self.addCleanup(settings.stop)

    def test_retains_new_verified_copy_and_unmanaged_files(self):
        OFFBOX.backup()
        self.assertFalse(self.older.exists())
        self.assertTrue(self.other.exists())
        new, = self.remote.glob("plainsay-20*.db.age")
        self.assertTrue(new.read_bytes().startswith(b"fixture ciphertext SQLite format 3"))
        self.assertFalse(list(self.remote.glob(".*.part")))

    def test_corrupt_upload_keeps_previous_copy(self):
        self.corruption = "upload"
        with self.assertRaises(OFFBOX.BackupError):
            OFFBOX.backup()
        self.assertEqual(list(self.remote.glob("plainsay-20*.db.age")), [self.older])
        self.assertFalse(list(self.remote.glob(".*.part")))

    def test_failed_post_rename_verification_keeps_previous_copy(self):
        self.corruption = "published"
        with self.assertRaises(OFFBOX.BackupError):
            OFFBOX.backup()
        self.assertEqual(list(self.remote.glob("plainsay-20*.db.age")), [self.older])

    def test_stale_writer_keeps_newer_copy(self):
        newer = self.remote / "plainsay-99990101T000000Z.db.age"
        newer.write_bytes(b"newer snapshot")
        with self.assertRaises(OFFBOX.BackupError):
            OFFBOX.backup()
        self.assertEqual(newer.read_bytes(), b"newer snapshot")
        self.assertTrue(self.older.exists())


class OneOffPrune(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory(prefix="plainsay-park-fixture-")
        self.addCleanup(temp.cleanup)
        root = Path(temp.name)
        self.update = root / "updates"
        releases = self.update / "releases"
        releases.mkdir(parents=True)
        self.launch = root / "plainsay-launch-0.2.24"
        self.launch.mkdir()
        self.rollback_zip = releases / "Plainsay-0.2.23.zip"
        self.old = releases / "Plainsay-0.2.24.zip"
        self.old.write_bytes(b"old")
        self.rollback_zip.write_bytes(b"verified ZIP")
        rollback_dmg = self.launch / "Plainsay-latest.dmg"
        rollback_dmg.write_bytes(b"verified DMG")
        with tarfile.open(self.launch / "plainsay-app.tar.gz", "w:gz") as archive:
            member = tarfile.TarInfo("plainsay-app/index.html")
            member.size = 1
            archive.addfile(member, io.BytesIO(b"x"))
        (self.launch / "appcast.xml").write_bytes(self.feed("Plainsay-0.2.23.zip"))
        self.live = self.feed("Plainsay-0.2.38.zip")
        (self.update / "appcast.xml").write_bytes(self.live)
        self.cask = b'  version "0.2.38"\n  url "https://example.invalid/Plainsay-#{version}.dmg"\n'
        self.mac_dmg = f"{PARK.DOWNLOADS}/Plainsay-latest.dmg"
        self.listing = f"-rw-r--r--  1 501 20 123 Nov 20 10:00 {self.mac_dmg}\n"
        self.mac_removals = []
        self.latest = [self.asset("Plainsay-0.2.38.dmg", b"x")]
        self.historical = [self.asset(self.rollback_zip.name, self.rollback_zip.read_bytes()),
                           self.asset("Plainsay-0.2.23.dmg", rollback_dmg.read_bytes())]
        settings = patch.multiple(PARK, UPDATE=self.update, LAUNCH=self.launch, fetch=self.fetch,
                                  mac_ssh=self.mac_ssh, mac_remove=self.mac_remove)
        settings.start()
        self.addCleanup(settings.stop)
        self.entries = [str(self.rollback_zip), str(self.old), str(self.launch), f"{PARK.MAC}:{self.mac_dmg}"]

    @staticmethod
    def feed(name, delta=""):
        return (
            f"""<rss xmlns:sparkle="urn:sparkle"><channel><item>
            <enclosure url='https://api.plainsay.app/releases/{name}?source=a&amp;cache=0' />
            {delta}
            </item></channel></rss>"""
        ).encode()

    @staticmethod
    def asset(name, data):
        return {"name": name, "browser_download_url": f"https://example.invalid/{name}",
                "size": len(data), "digest": "sha256:" + hashlib.sha256(data).hexdigest()}

    def fetch(self, url):
        if url == PARK.APPCAST:
            return self.live
        if url == PARK.CASK:
            return json.dumps({"encoding": "base64", "content": base64.b64encode(self.cask).decode()})
        if url.endswith("releases/latest"):
            return '{"id": 1, "draft": false, "prerelease": false}'
        if url.endswith("tags/v0.2.23"):
            return '{"id": 2, "tag_name": "v0.2.23", "draft": false, "prerelease": false}'
        if "/1/assets?" in url:
            return json.dumps(self.latest)
        if "/2/assets?" in url:
            return json.dumps(self.historical)
        raise AssertionError(url)

    def mac_ssh(self, user, command):
        self.assertEqual(command, PARK.MAC_LIST)
        if self.listing is None:
            raise subprocess.TimeoutExpired("fixture ssh", 1)
        return self.listing

    def mac_remove(self, user, listing, paths):
        self.assertEqual(listing, self.listing)
        self.mac_removals.extend(paths)

    def run_prune(self, dry=True):
        output = io.StringIO()
        with redirect_stdout(output):
            PARK.prune(self.entries, dry, "fixture-user")
        return output.getvalue()

    def assert_protected(self, error):
        with self.assertRaisesRegex(PARK.Stop, error):
            self.run_prune(dry=False)
        self.assertTrue(self.old.exists())
        self.assertTrue(self.rollback_zip.exists())
        self.assertTrue(self.launch.exists())
        self.assertEqual(self.mac_removals, [])

    def test_dry_run_plans_only_unprotected_paths(self):
        output = self.run_prune()
        self.assertIn("candidates=4 planned=2 bytes=126 dry_run=1", output)
        self.assertTrue(self.old.exists())
        self.assertEqual(self.mac_removals, [])

    def test_explicit_delete_keeps_rollback_and_its_feed_asset(self):
        self.run_prune(dry=False)
        self.assertFalse(self.old.exists())
        self.assertTrue(self.rollback_zip.exists())
        self.assertTrue(self.launch.exists())
        self.assertEqual(self.mac_removals, [self.mac_dmg])

    def test_newest_verified_rollback_allows_launch_backup_removal(self):
        backups = self.update / ".release-backups"
        newer = backups / "v0.2.24.ABC123"
        newer.mkdir(parents=True)
        for name in ("Plainsay-latest.dmg", "appcast.xml"):
            shutil.copyfile(self.launch / name, newer / name)
        now = newer.stat().st_mtime
        os.utime(newer, (now, now + 1))
        self.run_prune(dry=False)
        self.assertFalse(self.launch.exists())
        self.assertTrue(newer.exists())
        self.assertTrue(self.rollback_zip.exists())

    def test_reference_appearing_at_final_gate_blocks_every_delete(self):
        first_fetch = self.fetch

        def fetch(url):
            if url == PARK.APPCAST and self.mac_ssh_called:
                return self.feed(self.old.name)
            return first_fetch(url)

        self.mac_ssh_called = False

        def record_mac(user, cmd):
            self.mac_ssh_called = True
            return self.mac_ssh(user, cmd)

        with patch.multiple(PARK, fetch=fetch, mac_ssh=record_mac):
            self.assert_protected("live reference matches")

    def test_single_quotes_and_percent_encoded_delta_block_every_delete(self):
        self.live = self.feed("Plainsay-0.2.38.zip", """<sparkle:deltas>
          <enclosure url="https://api.plainsay.app/releases/Plainsay-0.2.%32%34.zip?build=1"/>
          </sparkle:deltas>""")
        self.assert_protected("live reference matches")

    def test_hosted_origin_feed_also_blocks_delete(self):
        (self.update / "appcast.xml").write_bytes(self.feed(self.old.name))
        self.assert_protected("live reference matches")

    def test_cask_checks_both_architectures_and_query_strings(self):
        self.cask += b"""on_arm do
             url "https://example.invalid/arm.dmg"
          end
          on_intel do
               url('https://example.invalid/Plainsay-latest.dmg?arch=intel')
          end
        """
        self.assert_protected("live reference matches")

    def test_computed_cask_url_blocks_every_delete(self):
        self.cask += b'url compute_url(version)\n'
        self.assert_protected("Unsupported Homebrew")

    def test_latest_github_asset_blocks_every_delete(self):
        self.latest.append(self.asset(self.old.name, self.old.read_bytes()))
        self.assert_protected("live reference matches")

    def test_unreachable_mac_blocks_every_delete(self):
        self.listing = None
        self.assert_protected("inventory unavailable")

    def test_unknown_mac_download_blocks_every_delete(self):
        self.listing = self.listing.replace("Plainsay-latest.dmg", "Plainsay-other.dmg")
        self.assert_protected("outside the verified explicit inventory")

    def test_corrupt_rollback_blocks_every_delete(self):
        (self.launch / "Plainsay-latest.dmg").write_bytes(b"corrupt")
        self.assert_protected("No verified OVH release rollback")

    def test_unsafe_candidate_blocks_every_delete(self):
        unrelated = self.old.with_suffix(".unrelated")
        self.old.rename(unrelated)
        self.old.symlink_to(unrelated)
        self.assert_protected("Expected a regular file")
        self.assertTrue(unrelated.exists())

    def test_incomplete_publication_blocks_every_delete(self):
        (self.update / ".release-stage.ABC123").mkdir()
        self.assert_protected("unfinished publication")


    def test_setup_and_update_locks_both_gate_the_run(self):
        setup_lock = self.update.parent / "setup.lock"
        setup_lock.touch()
        for locked in (setup_lock, self.update):
            with self.subTest(locked=locked), patch.object(PARK, "SETUP_LOCK", setup_lock):
                fd = os.open(locked, os.O_RDONLY)
                try:
                    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    with patch.dict(os.environ, {"DRY_RUN": "0"}), patch.object(os, "geteuid", return_value=0):
                        with self.assertRaises(BlockingIOError):
                            PARK.main()
                finally:
                    os.close(fd)
        self.assertTrue(self.old.exists())
        self.assertEqual(self.mac_removals, [])


class BundleInstall(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory(prefix="plainsay-install-fixture-")
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.apps = self.root / "Applications"
        self.installed = self.apps / "Plainsay.app"
        self.installed.mkdir(parents=True)
        (self.installed / "original").touch()
        content = self.root / "Scripts"
        content.mkdir()
        self.script = content / "bundle.sh"
        self.script.write_text((SCRIPTS / "bundle.sh").read_text().replace("/Applications", str(self.apps)))
        wrapper = content / "release-timeout.pl"
        wrapper.write_text('#!/bin/sh\nshift 2\nexec "$@"\n')
        wrapper.chmod(0o755)
        for file in ("Scripts/Info.plist", "Scripts/AppIcon.icns", "LICENSE", "THIRD_PARTY_NOTICES.md",
                     ".build/checkouts/FluidAudio/LICENSE", ".build/checkouts/WhisperKit/LICENSE",
                     ".build/checkouts/WhisperKit/NOTICES", ".build/checkouts/Sparkle/LICENSE",
                     "binary/PlainsayApp"):
            target = self.root / file
            target.parent.mkdir(parents=True, exist_ok=True)
            target.touch()
        (self.root / "binary/Sparkle.framework").mkdir()
        tools = self.root / "tools"
        tools.mkdir()
        shim = tools / "shim"
        shim.write_text("""#!/bin/bash
set -euo pipefail
tool=${0##*/}
case "$tool" in
  swift)
    if [ "$1" = build ]; then
      if [[ $* = *--show-bin-path* ]]; then echo "$FIXTURE/binary"; fi
    elif [[ $3 = "$FIXTURE/Applications/"* ]]; then
      [ -e "$3/original" ] && [ -e "$FIXTURE/verified" ]
      [ "${FAIL_STEP:-}" != swap ] || exit 2
      # Simulate success at the syscall boundary. Real Swift is tested on macOS.
      mv "$3" "$2.previous"
      mv "$2" "$3"
    else
      mv "$2" "$3"
    fi ;;
  ditto)
    [ -e "$FIXTURE/Applications/Plainsay.app/original" ]
    [ "${FAIL_STEP:-}" != copy ] || exit 2
    cp -R "$@" ;;
  codesign)
    if [[ ${!#} = "$FIXTURE/Applications/"* ]]; then
      [ -e "$FIXTURE/Applications/Plainsay.app/original" ]
      [ "${FAIL_STEP:-}" != verify ] || exit 2
      touch "$FIXTURE/verified"
    fi ;;
  xcrun|rsync|install_name_tool) ;;
  *) exit 99 ;;
esac
""")
        shim.chmod(0o755)
        for tool in ("swift", "ditto", "codesign", "xcrun", "rsync", "install_name_tool"):
            (tools / tool).symlink_to(shim)
        self.env = {**os.environ, "PATH": f"{tools}:{os.environ['PATH']}",
                    "FIXTURE": str(self.root), "INSTALL": "1"}

    def install(self, fail=""):
        return subprocess.run(["bash", self.script], env={**self.env, "FAIL_STEP": fail},
                              capture_output=True, text=True)

    def test_copy_verify_and_swap_before_removing_old_installation(self):
        result = self.install()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.installed / "Contents/MacOS/PlainsayApp").is_file())
        self.assertFalse(list(self.apps.glob(".plainsay-install.*")))

    def test_failed_copy_verification_and_swap_each_keep_installed_app(self):
        for step in ("copy", "verify", "swap"):
            with self.subTest(step=step):
                self.assertNotEqual(self.install(step).returncode, 0)
                self.assertTrue((self.installed / "original").exists())
                self.assertFalse(list(self.apps.glob(".plainsay-install.*")))
                # Each attempt builds a new local app. Start its stub afresh.
                shutil.rmtree(self.root / "build")

    @unittest.skipUnless(sys.platform == "darwin" and shutil.which("swift"), "macOS Swift required")
    def test_native_rename_installs_then_exchanges_directories(self):
        candidate = self.root / "candidate"
        destination = self.root / "destination"
        candidate.mkdir()
        (candidate / "first").touch()
        subprocess.run(["swift", SCRIPTS / "swap-app.swift", candidate, destination], check=True)
        self.assertTrue((destination / "first").exists())
        candidate.mkdir()
        (candidate / "second").touch()
        subprocess.run(["swift", SCRIPTS / "swap-app.swift", candidate, destination], check=True)
        self.assertTrue((candidate / "first").exists())
        self.assertTrue((destination / "second").exists())


if __name__ == "__main__":
    unittest.main()
