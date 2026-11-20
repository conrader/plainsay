#!/usr/bin/env python3
"""Offline coverage for atomic installation, off-box retention, and the park."""

import base64
from contextlib import redirect_stdout
from datetime import datetime, timezone
import fcntl
import grp
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import pwd
import shlex
import shutil
import socket
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / "Scripts"
sys.path.insert(0, str(SCRIPTS))


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

    def test_freshness_alert_is_nonzero_and_preserves_the_last_copy(self):
        command = ["bash", "-c", 'source "$1"; check_daily_backup "$2"',
                   "_", SCRIPTS / "plainsay-backup-rotate.sh", self.root]
        stale = subprocess.run(command, capture_output=True, text=True)
        self.assertEqual(stale.returncode, 1)
        self.assertIn("ALERT newest on-box daily backup is older than 2 days", stale.stdout)
        self.assertTrue(self.older.exists())
        stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        (self.backups / f"plainsay-daily-{stamp}.db").touch()
        fresh = subprocess.run(command, capture_output=True, text=True)
        self.assertEqual((fresh.returncode, fresh.stdout), (0, ""))
        self.backups.rename(self.root / "saved-backups")
        missing = subprocess.run(command, capture_output=True, text=True)
        self.assertEqual(missing.returncode, 1)
        self.assertIn("ALERT newest on-box daily backup is unavailable", missing.stdout)
        self.assertFalse(self.backups.exists())

    def test_hourly_freshness_job_notifies_at_most_once_per_24_hours(self):
        lib = self.root / "lib.sh"
        lib.write_text('STATE=$PLAINSAY_BACKUP_ROOT\n'
                       'ts() { /usr/bin/date -u +%Y-%m-%dT%H:%M:%SZ; }\n'
                       'log() { printf "%s\\n" "$*"; }\n'
                       'init_check() { exec 9>"$STATE/$1.lock"; flock -n 9; STARTED=$(ts); }\n')
        notifier = self.root / "sb-codejob"
        notifier.write_text('#!/bin/bash\nprintf "%s\\n" "$*" >>"$FIXTURE_NOTICES"\n'
                            'cat >>"$FIXTURE_NOTICES"\nexit 9\n')
        notifier.chmod(0o755)
        fake_date = self.root / "date"
        fake_date.write_text('#!/bin/bash\nif [[ $* == "-u +%s" ]]; then echo "$FIXTURE_NOW"; '
                             'else exec /usr/bin/date "$@"; fi\n')
        fake_date.chmod(0o755)
        script = self.root / "rotate.sh"
        script.write_text((SCRIPTS / "plainsay-backup-rotate.sh").read_text()
                          .replace("/home/ubuntu/work/Plainsay/cron/lib.sh", str(lib))
                          .replace("/home/ubuntu/sb/bin/sb-codejob", str(notifier)))
        notices = self.root / "notices"
        env = dict(os.environ, PATH=f"{self.root}:{os.environ['PATH']}",
                   PLAINSAY_BACKUP_ROOT=str(self.root), FIXTURE_NOTICES=str(notices))
        now = 2_000_000_000
        os.utime(self.other, (1, 1))

        def check(time):
            return subprocess.run(["bash", script, "--check-freshness"], capture_output=True, text=True,
                                  env={**env, "FIXTURE_NOW": str(time)})

        first = check(now)
        self.assertEqual(first.returncode, 1, first.stderr)
        self.assertIn("failure_wake_exit=9", first.stdout)
        self.assertIn("--label plainsay-onbox-freshness", notices.read_text())
        self.assertIn("ALERT newest on-box daily backup is older than 2 days", notices.read_text())
        self.assertIn("suppressed within 24h", check(now + 86399).stdout)
        self.assertEqual(notices.read_text().count("--label"), 1)
        self.assertEqual(check(now + 86400).returncode, 1)
        self.assertEqual(notices.read_text().count("--label"), 2)
        stamp = datetime.fromtimestamp(now, timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        (self.backups / f"plainsay-daily-{stamp}.db").touch()
        self.assertEqual(check(now + 172800).returncode, 0)
        self.assertEqual(notices.read_text().count("--label"), 2)
        self.assertTrue(self.older.exists())
        self.assertTrue(self.other.exists())


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
                                  run=run, LOG=self.root / "offbox.log", recent=[],
                                  LOCK=self.root / "backup.lock", FRESHNESS_NOTICE=self.root / "freshness-notice")
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

    def test_offbox_freshness_alert_calls_failure_hook_and_preserves_copy(self):
        original_run = subprocess.run
        calls = []

        def run(command, **kwargs):
            if command[0] == OFFBOX.NOTIFY:
                calls.append(command)
                self.assertIn(b"ALERT newest off-box backup is older than 2 days", kwargs["input"])
                return subprocess.CompletedProcess(command, 0)
            return original_run(command, **kwargs)

        with patch.object(subprocess, "run", side_effect=run):
            self.assertEqual(OFFBOX.main(check_only=True), 1)
            stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
            (self.remote / f"plainsay-{stamp}.db.age").touch()
            self.assertEqual(OFFBOX.main(check_only=True), 0)
        self.assertEqual(len(calls), 1)
        self.assertTrue(self.older.exists())

    def test_freshness_notification_attempt_is_persisted_for_24_hours(self):
        now = 10**18
        interval = OFFBOX.FRESHNESS_NOTICE_INTERVAL
        failure = OFFBOX.BackupError("fixture SSH failure", 124)
        with patch.object(OFFBOX, "check_freshness", side_effect=failure) as freshness, \
                patch.object(OFFBOX.time, "time_ns", return_value=now) as clock, \
                patch.object(subprocess, "run", side_effect=subprocess.TimeoutExpired("fixture", 1)) as notify:
            self.assertEqual(OFFBOX.main(check_only=True), 124)
            self.assertEqual(OFFBOX.FRESHNESS_NOTICE.read_text(), f"{now}\n")
            freshness.side_effect = None
            self.assertEqual(OFFBOX.main(check_only=True), 0)
            freshness.side_effect = failure
            clock.return_value = now + interval - 1
            self.assertEqual(OFFBOX.main(check_only=True), 124)
            self.assertEqual(notify.call_count, 1)
            clock.return_value = now + interval
            self.assertEqual(OFFBOX.main(check_only=True), 124)
            self.assertEqual(notify.call_count, 2)
        self.assertIn("freshness_wake=suppressed within 24h", OFFBOX.LOG.read_text())

    def test_freshness_notification_fails_closed_on_invalid_or_unwritable_state(self):
        for state, setup in (
            (self.root / "malformed", lambda path: path.write_text("bad timestamp\n")),
            (self.root / "missing-directory" / "state", lambda path: None),
            (self.root / "symlink", lambda path: path.symlink_to(self.older)),
        ):
            setup(state)
            with self.subTest(state=state.name), patch.object(OFFBOX, "FRESHNESS_NOTICE", state), \
                    patch.object(OFFBOX, "check_freshness", side_effect=OFFBOX.BackupError("fixture")), \
                    patch.object(subprocess, "run") as notify:
                self.assertEqual(OFFBOX.main(check_only=True), 1)
                notify.assert_not_called()
        self.assertEqual(OFFBOX.LOG.read_text().count("freshness_wake=suppressed state unavailable"), 3)

    def test_freshness_cooldown_does_not_suppress_daily_backup_failure(self):
        OFFBOX.FRESHNESS_NOTICE.write_text(f"{OFFBOX.time.time_ns()}\n")
        with patch.object(OFFBOX, "backup", side_effect=OFFBOX.BackupError("fixture")), \
                patch.object(subprocess, "run", return_value=subprocess.CompletedProcess([], 0)) as notify:
            self.assertEqual(OFFBOX.main(), 1)
            notify.assert_called_once()

    def test_freshness_notification_fails_closed_when_lock_is_held(self):
        with OFFBOX.LOCK.open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            with patch.object(OFFBOX, "check_freshness", side_effect=OFFBOX.BackupError("fixture")), \
                    patch.object(subprocess, "run") as notify:
                self.assertEqual(OFFBOX.main(check_only=True), 1)
                notify.assert_not_called()
        self.assertFalse(OFFBOX.FRESHNESS_NOTICE.exists())
        self.assertIn("freshness_wake=suppressed state unavailable", OFFBOX.LOG.read_text())


class BackupScriptsPark(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory(prefix="plainsay-backup-park-fixture-")
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name).resolve()
        cron, bin_dir, cron_d, commands = (self.root / name for name in ("cron", "bin", "cron.d", "tools"))
        for directory in (cron, bin_dir, cron_d, commands):
            directory.mkdir(mode=0o755)
            directory.chmod(0o755)
        (cron / "lib.sh").touch()
        self.targets = [cron / "plainsay-db-backup.sh", cron / "plainsay-backup-rotate.sh",
                        bin_dir / "plainsay-offbox-backup", cron_d / "plainsay-offbox"]
        self.previous = [path.with_name(path.name + ".prev") for path in self.targets]
        self.sources = [SCRIPTS / "plainsay-db-backup.sh", SCRIPTS / "plainsay-backup-rotate.sh",
                        SCRIPTS / "plainsay-offbox-backup.py"]
        self.old_files = [f"original {path.name}\n".encode() for path in self.targets]
        for path, content in zip(self.targets, self.old_files):
            path.write_bytes(content)
            path.chmod(0o644 if path.parent == cron_d else 0o755)
        self.crontab = self.root / "crontab"
        self.old_cron = (
            "# other job\n31 1 * * * /bin/true\n"
            "# Plainsay DB backup rotation: delete backup copies older than 30 days (privacy policy §8), hourly.\n"
            f"41 * * * * {self.targets[1]} >/dev/null 2>&1\n"
            "# Plainsay daily online DB backup (sqlite3 .backup as plainsay) into /var/lib/plainsay/backups; rotated after 30 days.\n"
            f"17 2 * * * {self.targets[0]} >/dev/null 2>&1\n"
        )
        self.crontab.write_text(self.old_cron)
        for name, body in {
            "sudo": '[[ $1 == -n ]]; shift\nif [[ $1 == /usr/bin/id ]]; then echo 0; else exec "$@"; fi\n',
            "git": 'case $3 in symbolic-ref) echo docs/privacy-backup-retention;; merge-base) exit 0;; *) exit 1;; esac\n',
            "crontab": 'case $1 in -l) cat "$FIXTURE_CRONTAB";; -n) test -s "$2";; '
                       '*) cp -- "$1" "$FIXTURE_CRONTAB";; esac\n',
            "sb-codejob": 'exit 99\n',
        }.items():
            executable = commands / name
            executable.write_text(f"#!/bin/bash\nset -eu\n{body}")
            executable.chmod(0o755)
        old_shas = [
            "bfe3091e55c1533bf6f645a76ed914fd8debfcba42e0f812cc7c1f3f37989882",
            "f3526fcc787057b36b701796eb2fa1a5e03218f9f39e5f64ca7d592d9805c78c",
            "d74edd53f36cd3afeed11500daa07ea8405f1662d1d276936d8d9bd191eb4f82",
            "98868456350c171935bf6c4f82662c81632b25d50baa0f92430650c690f13fb2",
        ]
        user = pwd.getpwuid(os.getuid()).pw_name
        group = grp.getgrgid(os.getgid()).gr_name
        text = (SCRIPTS / "privacy-s8-install-backup-scripts.sh").read_text()
        for old, new in (
            ("export PATH=/usr/bin:/bin", f"export PATH={commands}:/usr/bin:/bin"),
            ("/home/ubuntu/work/Plainsay/privacy-s8", str(ROOT)),
            ("/home/ubuntu/work/Plainsay/cron", str(cron)),
            ("bin=/usr/local/bin", f"bin={bin_dir}"),
            ("cron_d=/etc/cron.d", f"cron_d={cron_d}"),
            ("/home/ubuntu/sb/bin/sb-codejob", str(commands / "sb-codejob")),
            ("vps-98fe3bb4", socket.gethostname().split(".")[0]),
            ("$(id -un) == ubuntu", f"$(id -un) == {user}"),
            ("ubuntu:ubuntu:", f"{user}:{group}:"),
            ("root:root:", f"{user}:{group}:"),
            *zip(old_shas, (hashlib.sha256(content).hexdigest() for content in self.old_files)),
        ):
            text = text.replace(old, new)
        install = self.root / "privacy-s8-install-backup-scripts.sh"
        install.write_text(text)
        install.chmod(0o755)
        undo = SCRIPTS / "privacy-s8-undo-backup-scripts.sh"
        fixture_undo = self.root / undo.name
        undo_text = undo.read_text()
        park_source = f"source /home/ubuntu/work/Plainsay/parks/{install.name} --undo"
        self.assertIn(park_source, undo_text)
        fixture_undo.write_text(undo_text.replace(park_source, f"source {shlex.quote(str(install))} --undo"))
        fixture_undo.chmod(0o755)

    def park(self, action, dry_run=None):
        env = dict(os.environ, FIXTURE_CRONTAB=str(self.crontab))
        env.pop("DRY_RUN", None)
        if dry_run is not None:
            env["DRY_RUN"] = dry_run
        return subprocess.run([self.root / f"privacy-s8-{action}-backup-scripts.sh"],
                              env=env, capture_output=True, text=True)

    def test_install_and_undo_are_dry_by_default_and_idempotent(self):
        for action in ("install", "undo"):
            result = self.park(action)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn(f"{action} DRY_RUN=1", result.stdout)
        self.assertEqual([path.read_bytes() for path in self.targets], self.old_files)
        self.assertEqual(self.crontab.read_text(), self.old_cron)
        self.assertFalse(any(path.exists() for path in self.previous))

        for _ in range(2):
            result = self.park("install", "0")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual([path.read_bytes() for path in self.previous], self.old_files)
            self.assertEqual([path.read_bytes() for path in self.targets[:3]],
                             [path.read_bytes() for path in self.sources])
            self.assertEqual(self.crontab.read_text().count("--check-freshness"), 1)
            self.assertIn("47 * * * *", self.crontab.read_text())
            self.assertNotIn("rotated after 30 days", self.crontab.read_text())
            self.assertEqual(self.targets[3].read_text().count("--check-freshness"), 1)
            self.assertIn("53 * * * * ubuntu", self.targets[3].read_text())

        unrelated = "# edited after install\n12 8 * * * /bin/false\n"
        with self.crontab.open("a") as table:
            table.write(unrelated)
        review = self.park("undo")
        self.assertEqual(review.returncode, 0, review.stderr)
        self.assertIn(hashlib.sha256(self.old_files[0]).hexdigest(), review.stdout)
        self.assertIn("--check-freshness", self.crontab.read_text())
        for _ in range(2):
            result = self.park("undo", "0")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual([path.read_bytes() for path in self.targets], self.old_files)
            self.assertEqual([path.read_bytes() for path in self.previous], self.old_files)
            self.assertEqual(self.crontab.read_text(), self.old_cron + unrelated)

    def test_preflight_refuses_unexpected_cron_or_rollback_file_before_writing(self):
        bad = self.old_cron + f"41 * * * * {self.targets[1]} --check-freshness\n"
        self.crontab.write_text(bad)
        result = self.park("install", "0")
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("differ from the reviewed layout", result.stderr)
        self.assertFalse(any(path.exists() for path in self.previous))
        self.crontab.write_text(self.old_cron)
        self.previous[-1].symlink_to(self.targets[-1])
        result = self.park("install", "0")
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("Unexpected rollback file", result.stderr)
        self.assertFalse(any(path.exists() for path in self.previous[:-1]))
        self.assertEqual([path.read_bytes() for path in self.targets], self.old_files)
        self.assertEqual(self.crontab.read_text(), self.old_cron)


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
        self.legacy_zip = releases / "Plainsay-0.2.23.zip"
        self.legacy_zip.write_bytes(b"legacy ZIP")
        self.rollback_zip = releases / "Plainsay-0.2.38.zip"
        self.old = releases / "Plainsay-0.2.24.zip"
        self.old.write_bytes(b"old")
        self.rollback_zip.write_bytes(b"verified ZIP")
        (self.launch / "Plainsay-latest.dmg").write_bytes(b"legacy DMG")
        (self.launch / "plainsay-app.tar.gz").write_bytes(b"legacy site archive")
        (self.launch / "appcast.xml").write_bytes(self.feed(self.legacy_zip.name))
        self.newest = self.make_release_backup("v0.2.39.NEW123")
        self.live = self.feed("Plainsay-0.2.39.zip")
        (self.update / "appcast.xml").write_bytes(self.live)
        self.cask = b'  version "0.2.39"\n  url "https://example.invalid/Plainsay-#{version}.dmg"\n'
        self.mac_dmg = f"{PARK.DOWNLOADS}/Plainsay-latest.dmg"
        self.listing = f"-rw-r--r--  1 501 20 123 Nov 20 10:00 {self.mac_dmg}\n"
        self.paused = True
        setup_lock = root / "setup.lock"
        setup_lock.touch()
        self.mac_removals = []
        self.latest = [self.asset("Plainsay-0.2.39.dmg", b"x")]
        self.historical = [self.asset(self.rollback_zip.name, self.rollback_zip.read_bytes()),
                           self.asset("Plainsay-0.2.38.dmg", b"verified DMG")]
        settings = patch.multiple(PARK, UPDATE=self.update, LAUNCH=self.launch,
                                  SETUP_LOCK=setup_lock, ssh=self.ssh, mac_remove=self.mac_remove)
        settings.start()
        self.addCleanup(settings.stop)
        fetch = patch.object(PARK, "fetch", self.fetch)
        fetch.start()
        self.addCleanup(fetch.stop)
        self.entries = [str(self.legacy_zip), str(self.old), str(self.launch)]

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
        if "/releases/tags/" in url:
            return json.dumps({"id": 2, "tag_name": url.rsplit("/", 1)[-1],
                               "draft": False, "prerelease": False})
        if "/1/assets?" in url:
            return json.dumps(self.latest)
        if "/2/assets?" in url:
            return json.dumps(self.historical)
        raise AssertionError(url)

    def ssh(self, user, host, command):
        if host == PARK.MINI:
            self.assertEqual(command, PARK.PAUSE_CHECK)
            return "paused\n" if self.paused else ""
        self.assertEqual(host, PARK.MAC)
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
        self.assertTrue(self.legacy_zip.exists())
        self.assertTrue(self.launch.exists())
        self.assertEqual(self.mac_removals, [])

    def test_dry_run_plans_only_unprotected_paths(self):
        output = self.run_prune()
        self.assertRegex(output, r"candidates=3 planned=3 bytes=\d+ dry_run=1")
        self.assertTrue(self.legacy_zip.exists())
        self.assertTrue(self.launch.exists())
        self.assertTrue(self.old.exists())
        self.assertEqual(self.mac_removals, [])

    def test_explicit_delete_removes_legacy_pair_and_keeps_verified_rollback(self):
        self.run_prune(dry=False)
        self.assertFalse(self.old.exists())
        self.assertFalse(self.legacy_zip.exists())
        self.assertFalse(self.launch.exists())
        self.assertTrue(self.rollback_zip.exists())
        self.assertTrue(self.newest.exists())
        self.assertEqual(self.mac_removals, [])

    def make_release_backup(self, name, package=None):
        backups = self.update / ".release-backups"
        newer = backups / name
        newer.mkdir(parents=True, exist_ok=False)
        (newer / "appcast.xml").write_bytes(self.feed((package or self.rollback_zip).name))
        (newer / "Plainsay-latest.dmg").write_bytes(b"verified DMG")
        return newer

    def test_unsaved_newer_rollback_blocks_every_delete_even_with_live_artifacts(self):
        (self.rollback_zip.parent / "Plainsay-latest.dmg").write_bytes(b"verified DMG")
        (self.update / "appcast.xml").write_bytes(self.feed(self.rollback_zip.name))
        shutil.rmtree(self.newest)
        self.assert_protected("No saved newer rollback")

    def test_unverifiable_newest_rollback_stops_before_falling_back(self):
        older = self.make_release_backup("v0.2.38.OLD123")
        os.utime(older, (1, 1))
        (self.newest / "Plainsay-latest.dmg").write_bytes(b"corrupt")
        self.assert_protected("Rollback installer checksum mismatch")
        self.assertTrue(older.exists())

    def test_bad_rollback_zip_digest_blocks_every_delete(self):
        self.historical[0]["digest"] = "sha256:" + "0" * 64
        self.assert_protected("Rollback ZIP checksum mismatch")

    def test_newest_verified_rollback_must_be_newer_than_launch(self):
        (self.newest / "appcast.xml").write_bytes(self.feed(self.old.name))
        self.historical = [self.asset(self.old.name, self.old.read_bytes()),
                           self.asset("Plainsay-0.2.24.dmg", b"verified DMG")]
        self.assert_protected("Newest verified rollback must be newer than v0.2.24")

    def test_another_backup_needing_legacy_zip_blocks_oneoff(self):
        older = self.make_release_backup("v0.2.38.OLD123", self.legacy_zip)
        os.utime(older, (1, 1))
        self.assert_protected("still depends on Plainsay-0.2.23.zip")

    def test_unknown_launch_dependency_blocks_every_delete(self):
        (self.launch / "appcast.xml").write_bytes(self.feed(self.old.name))
        self.assert_protected("Unexpected launch rollback dependency")

    def test_reference_appearing_at_final_gate_blocks_every_delete(self):
        first_fetch = self.fetch
        count = 0

        def fetch(url):
            nonlocal count
            if url == PARK.APPCAST:
                count += 1
                if count == 2:
                    return self.feed(self.legacy_zip.name)
            return first_fetch(url)

        with patch.object(PARK, "fetch", fetch):
            self.assert_protected("live reference matches")

    def test_single_quotes_and_percent_encoded_delta_block_every_delete(self):
        self.live = self.feed("Plainsay-0.2.39.zip", """<sparkle:deltas>
          <enclosure url="https://api.plainsay.app/releases/Plainsay-0.2.%32%34.zip?build=1"/>
          </sparkle:deltas>""")
        self.assert_protected("live reference matches")

    def test_hosted_origin_feed_also_blocks_delete(self):
        (self.update / "appcast.xml").write_bytes(self.feed(self.legacy_zip.name))
        self.assert_protected("live reference matches")

    def test_cask_checks_both_architectures_and_query_strings(self):
        self.cask += b"""on_arm do
             url "https://example.invalid/arm.dmg"
          end
          on_intel do
               url('https://example.invalid/plainsay-launch-0.2.24/Plainsay-latest.dmg?arch=intel')
          end
        """
        self.assert_protected("live reference matches")

    def test_computed_cask_url_blocks_every_delete(self):
        self.cask += b'url compute_url(version)\n'
        self.assert_protected("Unsupported Homebrew")

    def test_no_space_cask_stanzas_cannot_hide_a_candidate(self):
        self.cask += (
            b'version"0.2.24"; url"https://example.invalid/Plainsay-#{version}.zip"\n'
        )
        self.assert_protected("live reference matches")

    def test_unparsed_no_space_cask_stanzas_block_every_delete(self):
        cask = self.cask
        for directive in (b'url"https://example.invalid/x" + suffix', b'version"latest"'):
            with self.subTest(directive=directive):
                self.cask = cask + directive + b"\n"
                self.assert_protected("Unsupported Homebrew")

    def test_rollback_digest_is_rechecked_before_every_delete(self):
        first_fetch = self.fetch
        checks = 0

        def fetch(url):
            nonlocal checks
            if "/releases/tags/" in url:
                checks += 1
                if checks == 2:
                    (self.newest / "Plainsay-latest.dmg").write_bytes(b"corrupt")
            return first_fetch(url)

        with patch.object(PARK, "fetch", fetch):
            self.assert_protected("Rollback installer checksum mismatch")

    def test_latest_github_asset_blocks_every_delete(self):
        self.latest.append(self.asset(self.legacy_zip.name, self.legacy_zip.read_bytes()))
        self.assert_protected("live reference matches")

    def test_unreachable_mac_skips_only_optional_step(self):
        self.listing = None
        with redirect_stdout(io.StringIO()) as output:
            PARK.prune_macbook([self.mac_dmg], False, "fixture-user")
        self.assertIn("SKIP macbook-m4 Downloads inventory unavailable", output.getvalue())
        self.assertTrue(self.launch.exists())
        self.assertEqual(self.mac_removals, [])
        self.run_prune(dry=False)
        self.assertFalse(self.launch.exists())
        self.assertFalse(self.legacy_zip.exists())

    def test_unknown_mac_download_blocks_mac_removal(self):
        self.listing = self.listing.replace("Plainsay-latest.dmg", "Plainsay-other.dmg")
        with self.assertRaisesRegex(PARK.Stop, "outside the verified explicit inventory"):
            PARK.prune_macbook([self.mac_dmg], False, "fixture-user")
        self.assertEqual(self.mac_removals, [])

    def test_optional_macbook_step_needs_no_mini_pause_and_defaults_to_dry_run(self):
        self.paused = False
        with patch.dict(os.environ, {}, clear=True), patch.object(os, "geteuid", return_value=0), \
                patch.object(sys, "stdin", io.StringIO(self.mac_dmg)), redirect_stdout(io.StringIO()) as output:
            PARK.main(macbook=True)
        self.assertIn("candidates=1 planned=1 bytes=123 dry_run=1", output.getvalue())
        self.assertEqual(self.mac_removals, [])
        with redirect_stdout(io.StringIO()):
            PARK.prune_macbook([self.mac_dmg], False, "fixture-user")
        self.assertEqual(self.mac_removals, [self.mac_dmg])
        self.assertTrue(self.launch.exists())

    def test_release_pause_is_required_and_rechecked_before_delete(self):
        self.paused = False
        self.assert_protected("release pause could not be verified")
        self.paused = True

        def resume_after_check(user, host, command):
            result = self.ssh(user, host, command)
            self.paused = False
            return result

        with patch.object(PARK, "ssh", resume_after_check):
            self.assert_protected("release pause could not be verified")

    def test_mini_pause_check_requires_lock_flag_and_no_pending_publication(self):
        home = self.update.parent
        state = home / "Library/Application Support/PlainsayRelease"
        lock = state / "nightly.lock"
        lock.mkdir(parents=True)
        command = ["/bin/sh", "-c", PARK.PAUSE_CHECK]
        env = {**os.environ, "HOME": str(home)}
        self.assertNotEqual(subprocess.run(command, env=env, capture_output=True).returncode, 0)
        (lock / "oneoff-prune").touch()
        self.assertEqual(subprocess.check_output(command, env=env, text=True), "paused\n")
        (state / "publish.pending").touch()
        self.assertNotEqual(subprocess.run(command, env=env, capture_output=True).returncode, 0)

    def test_missing_setup_lock_is_created_and_held_during_prune(self):
        setup_lock = self.update.parent / "missing-setup.lock"

        def concurrent_kit(*args):
            with setup_lock.open("w") as fd:
                with self.assertRaises(BlockingIOError):
                    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)

        with patch.multiple(PARK, SETUP_LOCK=setup_lock, prune=concurrent_kit), \
                patch.dict(os.environ, {"DRY_RUN": "0"}), patch.object(os, "geteuid", return_value=0), \
                patch.object(sys, "stdin", io.StringIO()):
            self.assertFalse(setup_lock.exists())
            PARK.main()
        self.assertEqual(setup_lock.stat().st_mode & 0o777, 0o600)

    def test_dry_run_does_not_create_missing_setup_lock(self):
        setup_lock = self.update.parent / "missing-setup.lock"
        with patch.object(PARK, "SETUP_LOCK", setup_lock), patch.dict(os.environ, {}, clear=True), \
                patch.object(os, "geteuid", return_value=0), patch.object(sys, "stdin", io.StringIO()):
            with self.assertRaisesRegex(PARK.Stop, "Cannot take the kit lock without creating"):
                PARK.main()
        self.assertFalse(setup_lock.exists())

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
        setup_lock = self.update.parent / "missing-setup.lock"
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


class ParkRollout(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory(prefix="plainsay-rollout-fixture-")
        self.addCleanup(temp.cleanup)
        root = Path(temp.name)
        self.checkout = root / "checkout"
        self.checkout.mkdir()
        self.remote = root / "origin"
        self.deploy = root / "deploy"
        self.deploy.mkdir()
        self.current = self.deploy / "deploy-command"
        self.current.write_text("original\n")
        self.log = root / "sudo.log"
        executables = root / "bin"
        executables.mkdir()
        sudo = executables / "sudo"
        sudo.write_text(
            '#!/bin/bash\nset -eu\nshift\nprintf "%s\\n" "$1" >> "$FIXTURE_SUDO_LOG"\n'
            'if [[ $1 == install ]]; then exec install -m "$7" "${@:8}"; fi\n'
            'exec "$@"\n'
        )
        sudo.chmod(0o755)
        self.env = dict(os.environ, PATH=f"{executables}:{os.environ['PATH']}",
                        FIXTURE_SUDO_LOG=str(self.log))
        self.git("init", "-q", "-b", "main")
        self.git("config", "user.email", "fixture@example.invalid")
        self.git("config", "user.name", "Fixture")
        source = self.checkout / "kit/ovh-deploy-command.sh"
        source.parent.mkdir()
        source.write_text("original\n")
        self.git("add", "kit")
        self.git("commit", "-qm", "base")
        self.base = self.git("rev-parse", "HEAD")
        self.git("init", "-q", "--bare", str(self.remote))
        self.git("remote", "add", "origin", str(self.remote))
        self.git("push", "-q", "origin", "main")
        source.write_text("new command\n")
        self.git("commit", "-qam", "rollout")
        self.new = self.git("rev-parse", "HEAD")
        self.prev = self.deploy / f"deploy-command.prev-{self.base[:7]}"

    def git(self, *args):
        return subprocess.check_output(["git", *args], cwd=self.checkout, text=True).strip()

    def park(self, action):
        script = (SCRIPTS / f"park-no-old-copies-{action}.sh").read_text()
        script = script.replace("/var/lib/plainsay-deploy/bin", str(self.deploy))
        return subprocess.run(["bash", "-s", "--", self.base, self.new], cwd=self.checkout, env=self.env,
                              input=script, text=True, capture_output=True)

    def test_step1_rerun_preserves_prev_after_rejected_push(self):
        hook = self.remote / "hooks/pre-receive"
        hook.write_text("#!/bin/sh\nexit 1\n")
        hook.chmod(0o755)
        self.assertIn("Could not fast-forward", self.park("step1").stderr)
        self.assertEqual(self.prev.read_text(), "original\n")
        self.assertEqual(self.current.read_text(), "new command\n")
        hook.unlink()
        result = self.park("step1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.prev.read_text(), "original\n")
        self.assertEqual(self.git("ls-remote", "origin", "refs/heads/main").split()[0], self.new)
        self.log.unlink()
        self.assertEqual(self.park("step1").returncode, 0)
        self.assertFalse(self.log.exists())

    def test_step1_guard_runs_before_any_production_write(self):
        self.git("commit", "--allow-empty", "-qm", "unexpected")
        self.git("push", "-q", "origin", "HEAD:main")
        result = self.park("step1")
        self.assertEqual(result.returncode, 1)
        self.assertIn("origin/main is outside", result.stderr)
        self.assertFalse(self.log.exists())
        self.assertFalse(self.prev.exists())
        self.assertEqual(self.current.read_text(), "original\n")

    def test_undo_restores_prev_and_is_idempotent(self):
        self.assertEqual(self.park("step1").returncode, 0)
        for _ in range(2):
            result = self.park("undo")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(self.current.read_text(), "original\n")
            self.assertEqual(self.prev.read_text(), "original\n")
            self.assertEqual(self.git("ls-remote", "origin", "refs/heads/main").split()[0], self.base)


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
      [ ! -e "$FIXTURE/running" ]
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
  pgrep)
    [ "$*" = '-x PlainsayApp' ] || exit 99
    touch "$FIXTURE/polled"
    [ -e "$FIXTURE/running" ] ;;
  osascript)
    [ -e "$FIXTURE/verified" ] && [[ $* == *'to quit'* ]]
    touch "$FIXTURE/asked-to-quit"
    if [ "${FAIL_STEP:-}" != quit ]; then rm "$FIXTURE/running"; fi ;;
  xcrun|rsync|install_name_tool|sleep) ;;
  *) exit 99 ;;
esac
""")
        shim.chmod(0o755)
        for tool in ("swift", "ditto", "codesign", "xcrun", "rsync", "install_name_tool", "pgrep", "osascript", "sleep"):
            (tools / tool).symlink_to(shim)
        self.env = {**os.environ, "PATH": f"{tools}:{os.environ['PATH']}",
                    "FIXTURE": str(self.root), "INSTALL": "1"}

    def install(self, fail=""):
        return subprocess.run(["bash", self.script], env={**self.env, "FAIL_STEP": fail},
                              capture_output=True, text=True)

    def test_copy_verify_and_swap_before_removing_old_installation(self):
        (self.root / "running").touch()
        result = self.install()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.installed / "Contents/MacOS/PlainsayApp").is_file())
        self.assertFalse(list(self.apps.glob(".plainsay-install.*")))
        self.assertTrue((self.root / "asked-to-quit").exists())

    def test_running_app_that_refuses_to_quit_blocks_swap(self):
        (self.root / "running").touch()
        result = self.install("quit")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Plainsay is still running", result.stderr)
        self.assertTrue((self.installed / "original").exists())
        self.assertFalse(list(self.apps.glob(".plainsay-install.*")))

    def test_release_build_does_not_request_app_quit(self):
        (self.root / "running").touch()
        self.env["INSTALL"] = "0"
        result = self.install()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.root / "polled").exists())
        self.assertTrue((self.installed / "original").exists())

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
