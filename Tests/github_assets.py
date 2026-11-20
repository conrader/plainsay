#!/usr/bin/env python3
"""Exercise Scripts/prune-github-assets.sh against a fake gh."""

import copy
import hashlib
import itertools
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

import fake_github

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "Scripts/prune-github-assets.sh"
RESTORE = ROOT / "Scripts/restore-github-assets.sh"
DMG_SHA = "a" * 64
ZIP_SHA = "d" * 64
URL = '  url "https://github.com/conrader/plainsay/releases/download/v#{version}/Plainsay-#{version}.dmg"'
CASK = f'cask "plainsay" do\n  version "0.2.39"\n  sha256 "{DMG_SHA}"\n{URL}\n  app "Plainsay.app"\nend\n'


IDS = itertools.count(1)


def release(tag, *names, draft=False, prerelease=False, digests=()):
    digests = dict(digests)
    return {"tag_name": tag, "draft": draft, "prerelease": prerelease,
            "assets": [{"id": next(IDS), "name": name, "digest": f"sha256:{digests.get(name, '0' * 64)}"}
                       for name in names]}


STATE = {"latest": "v0.2.39", "cask": CASK, "releases": [
    release("v0.2.40", "Plainsay-0.2.40.dmg", "Plainsay-0.2.40.zip", draft=True),
    release("v0.3.0-beta", "Plainsay-0.3.0.zip"),
    release("v0.2.39", "Plainsay-0.2.39.dmg", "Plainsay-0.2.39.zip",
            digests={"Plainsay-0.2.39.dmg": DMG_SHA, "Plainsay-0.2.39.zip": ZIP_SHA}),
    release("v0.2.38", "Plainsay-0.2.38.dmg", "Plainsay-0.2.38.zip", "notes.txt"),
    release("v0.2.10", "Plainsay-0.2.10.dmg", "Plainsay-0.2.39.zip"),
    release("v0.2.9", "Plainsay-0.2.9.zip"),
    release("v0.1.40", "Plainsay-0.1.40.dmg"),
    release("v0.2.5", "Plainsay-0.2.5.dmg", draft=True),
    release("v0.2.6", "Plainsay-0.2.6.dmg", "Plainsay-0.2.6.zip", prerelease=True),
]}
LIVE = ("0.2.39", DMG_SHA, ZIP_SHA)


class Fixture(unittest.TestCase):
    def setUp(self):
        workspace = tempfile.TemporaryDirectory(prefix="plainsay-gh-assets-")
        self.addCleanup(workspace.cleanup)
        self.case = Path(workspace.name)
        bin_dir = self.case / "bin"
        bin_dir.mkdir()
        gh = bin_dir / "gh"
        gh.write_text(f'#!/bin/sh\nexec python3 {ROOT / "Tests/fake_github.py"} "$@"\n')
        gh.chmod(0o755)
        self.state = self.case / "github.json"
        self.log = self.case / "gh.log"
        self.log.touch()
        self.write(copy.deepcopy(STATE))
        self.env = {**os.environ, "PATH": f"{bin_dir}{os.pathsep}{os.environ['PATH']}",
                    "FAKE_GITHUB_STATE": str(self.state), "FAKE_GITHUB_LOG": str(self.log)}

    def write(self, state):
        fake_github.save(self.state, state)

    def edit(self, change):
        state = fake_github.load(self.state)
        change(state)
        self.write(state)

    def assets(self):
        return {r["tag_name"]: sorted(a["name"] for a in r["assets"]) for r in fake_github.load(self.state)["releases"]}

    def run_prune(self, *args, status=0, **env):
        result = subprocess.run((SCRIPT, *args), env={**self.env, **env}, text=True, check=False,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        self.assertEqual(result.returncode, status, result.stdout)
        return result.stdout

    def deletes(self):
        return [line for line in self.log.read_text().splitlines() if " -X DELETE " in line]



class PruneGithubAssets(Fixture):
    def test_deletes_only_older_versioned_binaries(self):
        output = self.run_prune(*LIVE)
        self.assertIn("(5 older assets deleted)", output)
        self.assertEqual(self.assets(), {
            "v0.2.40": ["Plainsay-0.2.40.dmg", "Plainsay-0.2.40.zip"],  # in-flight draft
            "v0.3.0-beta": ["Plainsay-0.3.0.zip"],  # not a plain release tag
            "v0.2.39": ["Plainsay-0.2.39.dmg", "Plainsay-0.2.39.zip"],  # live
            "v0.2.38": ["notes.txt"],
            "v0.2.10": ["Plainsay-0.2.39.zip"],  # name does not match its tag
            "v0.2.9": [],
            "v0.1.40": [],
            "v0.2.5": ["Plainsay-0.2.5.dmg"],  # draft
            "v0.2.6": ["Plainsay-0.2.6.dmg", "Plainsay-0.2.6.zip"],  # prerelease
        })

    def test_rerun_and_missing_assets_are_not_errors(self):
        self.run_prune(*LIVE)
        self.assertIn("(0 older assets deleted)", self.run_prune(*LIVE))
        self.assertEqual(len(self.deletes()), 5)

    def test_asset_deleted_concurrently_is_skipped(self):
        listing = fake_github.load(self.state)
        self.edit(lambda s: s["releases"].pop(3))  # v0.2.38 vanished after listing
        real = fake_github.load(self.state)
        # Serve the stale listing while deletions see the current state.
        stale = self.case / "stale.json"
        fake_github.save(stale, listing)
        shim = self.case / "bin/gh"
        shim.write_text(
            "#!/bin/sh\n"
            'case "$*" in *"releases?per_page"*) FAKE_GITHUB_STATE=' + str(stale) + ";; esac\n"
            f'exec python3 {ROOT / "Tests/fake_github.py"} "$@"\n')
        self.assertEqual(real["releases"][3]["tag_name"], "v0.2.10")
        output = self.run_prune(*LIVE)
        self.assertIn("Already gone: v0.2.38/Plainsay-0.2.38.dmg", output)
        self.assertIn("(3 older assets deleted)", output)

    def test_server_error_fails_without_claiming_success(self):
        doomed = next(r for r in STATE["releases"] if r["tag_name"] == "v0.2.38")["assets"][0]["id"]
        self.edit(lambda s: s.update(delete_errors={str(doomed): 502}))
        output = self.run_prune(*LIVE, status=1)
        self.assertIn("HTTP 502", output)
        self.assertNotIn("Kept only", output)

    def test_unverified_live_release_deletes_nothing(self):
        cases = {
            "cask is another version": lambda s: s.update(cask=CASK.replace('"0.2.39"', '"0.2.38"')),
            "latest is another tag": lambda s: s.update(latest="v0.2.38"),
            "live digest differs": lambda s: s["releases"][2]["assets"][0].update(digest="sha256:" + "b" * 64),
            "live zip missing": lambda s: s["releases"][2]["assets"].pop(1),
            "live zip has no digest": lambda s: s["releases"][2]["assets"][1].pop("digest"),
            "live zip is another build": lambda s: s["releases"][2]["assets"][1].update(digest="sha256:" + "e" * 64),
            "live release is a draft": lambda s: s["releases"][2].update(draft=True),
            "live release is a prerelease": lambda s: s["releases"][2].update(prerelease=True),
            "cask pins an older DMG": lambda s: s.update(cask=CASK.replace(
                URL, '  url "https://github.com/conrader/plainsay/releases/download/v0.2.38/Plainsay-0.2.38.dmg"')),
            "cask has a second url": lambda s: s.update(cask=CASK.replace(URL, URL + "\n" + URL)),
            "cask has no url": lambda s: s.update(cask=CASK.replace(URL + "\n", "")),
        }
        for name, change in cases.items():
            with self.subTest(name):
                self.write(copy.deepcopy(STATE))
                self.edit(change)
                self.run_prune(*LIVE, status=1)
                self.assertEqual(self.deletes(), [])
        with self.subTest("shipped DMG differs from cask"):
            self.write(copy.deepcopy(STATE))
            self.run_prune("0.2.39", "c" * 64, ZIP_SHA, status=1)
            self.assertEqual(self.deletes(), [])
        for bad in (("",), ("0.2", DMG_SHA, ZIP_SHA), ("v0.2.39", DMG_SHA, ZIP_SHA),
                    ("0.2.39; rm", DMG_SHA, ZIP_SHA), ("0.2.39", DMG_SHA)):
            with self.subTest(args=bad):
                self.run_prune(*bad, status=1)
        self.assertEqual(self.deletes(), [])

    def test_dry_run_lists_without_deleting(self):
        output = self.run_prune(*LIVE, DRY_RUN="1")
        self.assertEqual(output.count("Would delete"), 5)
        self.assertEqual(self.deletes(), [])

    def test_rollback_after_listing_stops_before_any_delete(self):
        cases = {
            "Latest switched back": {"latest": "v0.2.38"},
            "cask reverted": {"cask": CASK.replace('"0.2.39"', '"0.2.38"')},
        }
        for name, change in cases.items():
            with self.subTest(name):
                self.write({**copy.deepcopy(STATE), "after_list": change})
                output = self.run_prune(*LIVE, status=1)
                self.assertIn("prune-github-assets:", output)
                self.assertEqual(self.deletes(), [])
                self.assertEqual(self.assets()["v0.2.38"],
                                 ["Plainsay-0.2.38.dmg", "Plainsay-0.2.38.zip", "notes.txt"])

    def test_release_turned_prerelease_after_listing_is_kept(self):
        self.write({**copy.deepcopy(STATE), "after_list": {"releases": [
            {**r, "prerelease": True} if r["tag_name"] == "v0.2.38" else r for r in STATE["releases"]]}})
        output = self.run_prune(*LIVE)
        self.assertIn("Kept v0.2.38/Plainsay-0.2.38.dmg", output)
        self.assertEqual(self.assets()["v0.2.38"], ["Plainsay-0.2.38.dmg", "Plainsay-0.2.38.zip", "notes.txt"])

    def test_delete_404_for_a_visible_asset_fails(self):
        doomed = next(r for r in STATE["releases"] if r["tag_name"] == "v0.2.38")["assets"][0]["id"]
        self.edit(lambda s: s.update(delete_errors={str(doomed): 404}))
        output = self.run_prune(*LIVE, status=1)
        self.assertIn("returned HTTP 404 but the asset is still listed", output)
        self.assertNotIn("Kept only", output)
        self.assertIn("Plainsay-0.2.38.dmg", self.assets()["v0.2.38"])

    def test_delete_404_for_a_concurrently_deleted_asset_is_skipped(self):
        doomed = next(r for r in STATE["releases"] if r["tag_name"] == "v0.2.38")["assets"][0]["id"]
        self.edit(lambda s: s.update(delete_errors={str(doomed): "404-gone"}))
        output = self.run_prune(*LIVE)
        self.assertIn("Already gone: v0.2.38/Plainsay-0.2.38.dmg", output)
        self.assertIn("(4 older assets deleted)", output)


class RestoreGithubAssets(Fixture):
    """Rollback order: restore and verify binaries, then switch Latest."""

    def setUp(self):
        super().setUp()
        self.dmg = self.case / "Plainsay-latest.dmg"
        self.dmg.write_bytes(b"previous dmg")
        self.zip = self.case / "Plainsay-0.2.38.zip"
        self.zip.write_bytes(b"previous zip")
        self.dmg_sha = hashlib.sha256(b"previous dmg").hexdigest()
        self.run_prune(*LIVE)  # v0.2.38 lost its binaries to the prune.
        self.log.write_text("")

    def restore(self, *args, status=0):
        result = subprocess.run((RESTORE, *args), env=self.env, text=True, check=False,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        self.assertEqual(result.returncode, status, result.stdout)
        return result.stdout

    def calls(self):
        return [line for line in self.log.read_text().splitlines()
                if line.startswith(("gh release upload", "gh release edit"))]

    def test_restores_and_verifies_before_switching_latest(self):
        self.restore("0.2.38", self.dmg, self.zip, self.dmg_sha)
        state = fake_github.load(self.state)
        self.assertEqual(state["latest"], "v0.2.38")
        live = {a["name"]: a["digest"] for r in state["releases"] if r["tag_name"] == "v0.2.38" for a in r["assets"]}
        self.assertEqual(live["Plainsay-0.2.38.dmg"], f"sha256:{self.dmg_sha}")
        self.assertEqual(live["Plainsay-0.2.38.zip"], "sha256:" + hashlib.sha256(b"previous zip").hexdigest())
        calls = self.calls()
        self.assertEqual([c.split()[2] for c in calls], ["upload", "upload", "edit"])
        self.restore("0.2.38", self.dmg, self.zip, self.dmg_sha)  # Rerun keeps the verified assets.
        self.assertEqual(sum("upload" in c for c in self.calls()), 2)

    def test_unverified_upload_never_switches_latest(self):
        self.edit(lambda s: s.update(corrupt_uploads=True))
        self.assertIn("digest does not match after upload",
                      self.restore("0.2.38", self.dmg, self.zip, self.dmg_sha, status=1))
        self.assertFalse(any("release edit" in c for c in self.calls()))
        self.assertEqual(fake_github.load(self.state)["latest"], "v0.2.39")

    def test_mismatch_never_switches_latest(self):
        self.restore("0.2.38", self.dmg, self.zip, "f" * 64, status=1)  # not the cask's DMG
        self.edit(lambda s: s["releases"][3]["assets"].append(
            {"id": 999, "name": "Plainsay-0.2.38.dmg", "digest": "sha256:" + "b" * 64}))
        self.assertIn("not replacing it", self.restore("0.2.38", self.dmg, self.zip, self.dmg_sha, status=1))
        self.edit(lambda s: s["releases"][3].update(prerelease=True))
        self.restore("0.2.38", self.dmg, self.zip, self.dmg_sha, status=1)
        self.assertFalse(any("release edit" in c for c in self.calls()))
        self.assertEqual(fake_github.load(self.state)["latest"], "v0.2.39")


if __name__ == "__main__":
    unittest.main()
