#!/usr/bin/env python3
"""Exercise OVH retention against a temporary update root."""

import hashlib
import importlib.util
from io import BytesIO, StringIO
from pathlib import Path
import tarfile
import tempfile
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[1] / "kit/ovh-release-retention.py"
spec = importlib.util.spec_from_file_location("release_retention", SCRIPT)
retention = importlib.util.module_from_spec(spec)
spec.loader.exec_module(retention)

OLD = "releases/Plainsay-0.2.38.zip"
NEW = "releases/Plainsay-0.2.39.zip"
DELTA = "releases/Plainsay239-238.delta"
ORPHANS = ("Plainsay-0.2.1.zip", "Plainsay-0.2.2.dmg", "Plainsay238-237.delta", "Plainsay-0.2.3.tar.gz")


def sha(data):
    return hashlib.sha256(data).hexdigest()


def appcast(zip_path, delta=None, build=None):
    build = build or (239 if zip_path == NEW else 238)
    deltas = (f'<sparkle:deltas><enclosure url="{retention.ORIGIN}/{delta}"/></sparkle:deltas>'
              if delta else "")
    return (f'<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">'
            f'<channel><item><sparkle:version>{build}</sparkle:version>'
            f'<enclosure url="{retention.ORIGIN}/{zip_path}"/>'
            f'{deltas}</item></channel></rss>').encode()


class Retention(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name).resolve()
        self.releases = self.root / "releases"
        self.releases.mkdir()
        self.backups = self.root / ".release-backups"
        self.backups.mkdir()
        self.stage = self.root / ".release-stage.Abc123"
        self.stage.mkdir()
        for name in ORPHANS:
            (self.releases / name).write_text("old")
        (self.releases / "unrelated.zip").write_text("leave this")
        (self.releases / "Plainsay-link.zip").symlink_to("unrelated.zip")
        (self.root / OLD).write_bytes(b"old zip")
        (self.root / retention.DMG).write_bytes(b"old dmg")
        (self.root / retention.FEED).write_bytes(appcast(OLD))
        (self.root / DELTA).write_bytes(b"delta")
        (self.stage / Path(NEW).name).write_bytes(b"new zip")
        (self.stage / "Plainsay-0.2.39.dmg").write_bytes(b"new dmg")
        (self.stage / retention.FEED).write_bytes(appcast(NEW, DELTA))
        self.verifications = []
        self.failed_relative = None

        def verify_live(relative, checksum):
            self.verifications.append(relative)
            if relative == self.failed_relative:
                raise OSError("HTTP 404")
            self.assertEqual(sha((self.root / relative).read_bytes()), checksum)

        verifier = patch.object(retention, "verify_live", side_effect=verify_live)
        verifier.start()
        self.addCleanup(verifier.stop)

    def backup(self):
        name, checksum = retention.run(self.root, ["backup", "0.2.39"]).split()
        return name, checksum

    def activate(self, receipt):
        retention.run(self.root, ["activate", "0.2.39", self.stage.name, *receipt, *self.new_hashes()])

    def prune(self, receipt):
        retention.run(self.root, ["prune", "0.2.39", *receipt, *self.new_hashes()])

    @staticmethod
    def new_hashes():
        return [sha(b"new zip"), sha(b"new dmg"), sha(appcast(NEW, DELTA))]

    def test_success_keeps_only_live_assets_and_verified_rollback(self):
        legacy = self.backups / "v0.2.37.Old123"
        legacy.mkdir()
        (legacy / "appcast.xml").write_text("previous backup")
        (self.backups / "v0.2.38.old_1234.tar").write_text("another old backup")
        # The previous feed was also allowed to reference deltas.
        (self.root / retention.FEED).write_bytes(appcast(OLD, DELTA))
        receipt = self.backup()
        self.assertCountEqual(self.verifications, (retention.FEED, retention.DMG, OLD, DELTA))
        self.activate(receipt)
        self.assertFalse(self.stage.exists())
        self.verifications.clear()
        self.prune(receipt)
        self.prune(receipt)  # A lost SSH reply can be retried.
        self.assertEqual(self.verifications, [retention.FEED, retention.DMG, NEW, DELTA] * 2)
        self.assertEqual({p.name for p in self.releases.iterdir()}, {
            "Plainsay-latest.dmg", Path(NEW).name, Path(DELTA).name, "unrelated.zip", "Plainsay-link.zip",
        })
        self.assertEqual([p.name for p in self.backups.iterdir()], [receipt[0]])
        with tarfile.open(self.backups / receipt[0]) as archive:
            self.assertCountEqual(archive.getnames(), (retention.FEED, retention.DMG, OLD, DELTA))
            self.assertEqual(archive.extractfile(OLD).read(), b"old zip")
            self.assertEqual(archive.extractfile(retention.DMG).read(), b"old dmg")

    def test_unreachable_delta_preserves_old_artifacts(self):
        receipt = self.backup()
        self.activate(receipt)
        self.failed_relative = DELTA
        with self.assertRaisesRegex(OSError, "HTTP 404"):
            self.prune(receipt)
        self.assertTrue((self.root / OLD).exists())
        self.assertTrue(all((self.releases / name).exists() for name in ORPHANS))

    def test_changed_live_feed_cannot_prune_previous_assets(self):
        receipt = self.backup()
        self.activate(receipt)
        (self.root / retention.FEED).write_bytes(appcast(NEW))
        with self.assertRaisesRegex(ValueError, "Live appcast changed"):
            self.prune(receipt)
        self.assertTrue((self.root / OLD).exists())

    def test_changed_release_cannot_activate_stale_backup(self):
        receipt = self.backup()
        (self.root / retention.DMG).write_bytes(b"changed")
        with self.assertRaisesRegex(ValueError, "changed after its rollback archive"):
            self.activate(receipt)
        self.assertTrue(self.stage.exists())
        self.assertFalse((self.root / NEW).exists())

    def test_older_staged_build_cannot_replace_current_release(self):
        (self.root / retention.FEED).write_bytes(appcast(OLD, build=240))
        receipt = self.backup()
        with self.assertRaisesRegex(ValueError, "must exceed the current build"):
            self.activate(receipt)
        self.assertFalse((self.root / NEW).exists())

    def test_failed_backup_verification_leaves_no_archive(self):
        self.failed_relative = OLD
        with self.assertRaisesRegex(OSError, "HTTP 404"):
            self.backup()
        self.assertEqual(list(self.backups.iterdir()), [])

    def test_damaged_backup_blocks_prune(self):
        receipt = self.backup()
        self.activate(receipt)
        (self.backups / receipt[0]).write_bytes(b"damaged")
        with self.assertRaisesRegex(ValueError, "Rollback archive checksum mismatch"):
            self.prune(receipt)
        self.assertTrue((self.root / OLD).exists())

    def test_prune_keeps_backup_of_an_in_flight_newer_publish(self):
        receipt = self.backup()
        self.activate(receipt)
        newer = self.backups / "v0.2.40.Other_12.tar"
        newer.write_text("publisher B's archive, taken before B activates")
        older = self.backups / "v0.2.38.Older_1.tar"
        older.write_text("superseded")
        self.prune(receipt)
        self.assertEqual(sorted(p.name for p in self.backups.iterdir()), sorted((receipt[0], newer.name)))

    def test_prune_repairs_owned_legacy_backup_permissions(self):
        legacy = self.backups / "v0.2.37.Old123"
        (legacy / "nested").mkdir(parents=True)
        (legacy / "nested/appcast.xml").write_text("legacy")
        (legacy / "nested").chmod(0)
        legacy.chmod(0o500)
        receipt = self.backup()
        self.activate(receipt)
        self.prune(receipt)
        self.assertEqual([p.name for p in self.backups.iterdir()], [receipt[0]])
        self.assertFalse((self.root / OLD).exists())

    def test_prune_skips_whole_unremovable_legacy_backup(self):
        legacy = self.backups / "v0.2.37.Old123"
        (legacy / "nested").mkdir(parents=True)
        (legacy / "nested/appcast.xml").write_text("legacy")
        (legacy / "nested").chmod(0)
        self.addCleanup(lambda: (legacy / "nested").chmod(0o700))
        receipt = self.backup()
        self.activate(receipt)
        # Another account's 0700 tree: this account cannot repair its mode.
        with patch.object(retention.os, "chmod", side_effect=PermissionError("not owner")), \
                patch("sys.stderr", new_callable=StringIO) as stderr:
            self.prune(receipt)
        self.assertIn("kept unremovable legacy backup", stderr.getvalue())
        self.assertEqual(sorted(p.name for p in self.backups.iterdir()), sorted((receipt[0], legacy.name)))
        self.assertEqual(oct((legacy / "nested").stat().st_mode & 0o777), oct(0))
        self.assertFalse((self.root / OLD).exists())
        self.assertFalse(any((self.releases / name).exists() for name in ORPHANS))

    def test_ambiguous_local_enclosure_fails_closed(self):
        for path in ("releases/subdir/Plainsay.zip", "releases/Plainsay%2e202.zip"):
            with self.subTest(path=path), self.assertRaisesRegex(ValueError, "Unsupported local enclosure"):
                retention.appcast(appcast(path))


class LiveVerification(unittest.TestCase):
    def test_requires_http_200_and_matching_content(self):
        for status, body in [(200, b"expected"), (206, b"expected"), (200, b"unexpected"),
                             (302, b"expected")]:
            with self.subTest(status=status, body=body), patch.object(retention, "build_opener") as opener:
                response = BytesIO(body)
                response.status = status
                opener.return_value.open.return_value = response
                if (status, body) == (200, b"expected"):
                    retention.verify_live(retention.DMG, sha(b"expected"))
                else:
                    with self.assertRaisesRegex(ValueError, "HTTP status or checksum"):
                        retention.verify_live(retention.DMG, sha(b"expected"))


if __name__ == "__main__":
    unittest.main()
