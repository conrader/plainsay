#!/usr/bin/env python3
"""Run macOS release control flow with local Git remotes and fake release tools."""

import hashlib
import os
import plistlib
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = Path(__file__).resolve()
DEV_ID = "Test Developer ID"


def git(*args, **kwargs):
    return subprocess.check_output(("git", *args), text=True, **kwargs).strip()


def fake_bundle():
    app = Path("build/Plainsay.app/Contents")
    app.mkdir(parents=True, exist_ok=True)
    shutil.copyfile("Scripts/Info.plist", app / "Info.plist")


def fake_tool(tool, args):
    case = Path(os.environ["RELEASE_TEST_CASE"])
    with (case / "events").open("a") as events:
        events.write(shlex.join([tool, *args]) + "\n")
    mode = os.environ.get("RELEASE_TEST_MODE")
    env = os.environ
    marker = Path(env["PLAINSAY_NIGHTLY_STATE_DIR"]) / "publish.pending"
    remote = case / "origin.git"
    server = case / "staged"

    def advance_main():
        subprocess.run(
            (env["REAL_GIT"], "--git-dir", remote, "update-ref", "refs/heads/main", env["NEXT_SHA"]),
            check=True,
        )

    def assert_marker():
        state = dict(line.split("=", 1) for line in marker.read_text().splitlines())
        assert state["tag"] and state["backup"] and state["stage"]
        for item in ("zip_sha", "dmg_sha", "feed_sha"):
            assert re.fullmatch(r"[a-f0-9]{64}", state[item])
        assert (Path(state["local_tap"]) / ".git").is_dir()

    if tool == "git":
        command = args[2] if args[0] == "-C" else args[0]
        if command == "push":
            assert_marker()  # Deliberately intercept every push, even local ones.
            return 0
        if command == "clone" and "https://github.com/conrader/homebrew-plainsay.git" in args:
            args[args.index("https://github.com/conrader/homebrew-plainsay.git")] = (case / "tap.git").as_uri()
            if mode == "late-main":
                advance_main()
            if mode == "late-feed":
                (case / "feed-build").write_text("300")
        os.execv(env["REAL_GIT"], [env["REAL_GIT"], *args])
    elif tool == "gh":
        if args[:2] == ["release", "view"]:
            if "--json" not in args:
                return 1
            output = env.get("STABLE", "true") if "isDraft,isPrerelease" in args else "false"
            print(output)
        elif args[:2] == ["api", "--method"]:
            if mode == "early-main":
                advance_main()
            sha = next(arg.split("=", 1)[1] for arg in args if arg.startswith("head_sha="))
            ci = env.get("CI_RESULT", "completed success")
            print("missing" if ci == "missing" else f"{sha} {ci}")
        elif args[:2] == ["release", "create"]:
            assert_marker()
            return 1 if mode == "draft-fails" else 0
        elif args[:2] == ["release", "edit"]:
            assert_marker()
        elif args[0] == "api" and "Casks/plainsay.rb" in args[-1]:
            state = dict(line.split("=", 1) for line in marker.read_text().splitlines())
            print((Path(state["local_tap"]) / "Casks/plainsay.rb").read_text(), end="")
        elif args[:2] == ["repo", "view"]:
            print("https://example.invalid/plainsay")
        else:
            raise AssertionError(args)
    elif tool == "PlistBuddy":
        command, key, *value = args[1].split()
        path = Path(args[2])
        data = plistlib.loads(path.read_bytes())
        if command == "Print":
            print(data[key[1:]])
        elif command == "Set":
            data[key[1:]] = value[0]
            path.write_bytes(plistlib.dumps(data))
        else:
            raise AssertionError(args)
    elif tool == "uname":
        print({"-s": "Darwin", "-m": "arm64"}[args[0]])
    elif tool == "swift":
        if args[0] == "build":
            sign_update = Path(".build/artifacts/sparkle/Sparkle/bin/sign_update")
            sign_update.parent.mkdir(parents=True, exist_ok=True)
            sign_update.symlink_to(case / "bin/sign_update")
        elif args[0] == "Scripts/check-release-keychain.swift":
            return 1 if mode == "locked-keychain" else 0
        elif args[0] not in ("test", "Scripts/verify-sparkle-signature.swift", "Scripts/make-dmg-background.swift"):
            raise AssertionError(args)
    elif tool == "security":
        assert args == ["find-identity", "-v", "-p", "codesigning"]
        if mode == "hung-keychain":
            time.sleep(60)
        print(f'  1) 1234 "{DEV_ID}"')
    elif tool == "ditto":
        src, dst = map(Path, args[-2:])
        if len(args) == 2:
            shutil.copytree(src, dst)
        else:
            dst.write_text("fake zip\n")
    elif tool == "stat":
        assert args[0] == "-f%z"
        print(Path(args[1]).stat().st_size)
    elif tool == "sign_update":
        print("fake-signature")
    elif tool == "hdiutil":
        if args[0] == "create":
            Path(args[-1]).write_text("fake dmg\n")
        elif args[0] == "attach":
            (case / "mount").mkdir()
            print("test-disk\t/Volumes/FakeRelease")
        elif args[0] == "convert":
            shutil.copyfile(args[1], args[-1])
        elif args[0] not in ("info", "detach"):
            raise AssertionError(args)
    elif tool == "awk":
        if "mount = $NF" in args[-1]:
            assert "/Volumes/FakeRelease" in sys.stdin.read()
            print(case / "mount")
        else:
            os.execv(env["REAL_AWK"], [env["REAL_AWK"], *args])
    elif tool == "xcrun":
        if args[0] == "notarytool":
            print('{"status": "Accepted"}')
        else:
            assert args[0] == "stapler"
    elif tool == "plutil":
        assert '"Accepted"' in sys.stdin.read()
        print("Accepted")
    elif tool == "ssh":
        command = args[-1]
        if not command.startswith("sudo -n "):
            # The nightly deploy key's forced command must admit every remote command.
            subprocess.run(
                ("bash", "-c", 'source "$1"; allowed_shell "$2"', "_",
                 ROOT / "kit/ovh-deploy-command.sh", command),
                check=True,
            )
        if ".release-backups" in command:
            print("/var/www/plainsay-updates/.release-backups/vtest.ABC123")
        elif ".release-stage" in command and command.startswith("mktemp"):
            server.mkdir()
            print("/var/www/plainsay-updates/.release-stage.ABC123")
        elif command.startswith("sha256sum"):
            package = Path(command.strip("'")).name
            print(hashlib.sha256((server / package).read_bytes()).hexdigest())
        elif command.startswith("rm -rf"):
            shutil.rmtree(server)
        elif command.startswith("set -eu\nchmod"):
            assert_marker()
            (server / next(server.glob("*.dmg")).name).rename(server / "Plainsay-latest.dmg")
        else:
            assert command.startswith("sudo -n "), command
    elif tool == "scp":
        for package in args[-4:-1]:
            shutil.copyfile(package, server / Path(package).name)
    elif tool == "curl":
        artifact = Path(args[-1]).name
        if artifact == "appcast.xml" and not (server / "Plainsay-latest.dmg").exists():
            print(f"<sparkle:version>{(case / 'feed-build').read_text()}</sparkle:version>")
        else:
            sys.stdout.buffer.write((server / artifact).read_bytes())
    else:
        assert tool in {"codesign", "osascript", "rsync", "spctl", "xmllint"}, tool
    return 0


class ReleaseSandbox(unittest.TestCase):
    def setUp(self):
        workspace = tempfile.TemporaryDirectory(prefix="plainsay-release-test-")
        self.addCleanup(workspace.cleanup)
        self.case = Path(workspace.name).resolve()
        self.seed = self.case / "seed"
        self.checkout = self.case / "checkout"
        self.remote = self.case / "origin.git"
        self.state = self.case / "release state"
        self.state.mkdir()
        (self.case / "feed-build").write_text("238")
        (self.case / "events").touch()
        bin_dir = self.case / "bin"
        bin_dir.mkdir()
        for name in ("awk", "codesign", "curl", "ditto", "gh", "git", "hdiutil", "osascript",
                     "PlistBuddy", "plutil", "rsync", "scp", "security", "sign_update", "spctl",
                     "ssh", "stat", "swift", "uname", "xcrun", "xmllint"):
            (bin_dir / name).symlink_to(SCRIPT)
        self.env = {
            "PATH": f"{bin_dir}{os.pathsep}{os.environ['PATH']}",
            "HOME": str(self.case),
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_GLOBAL": os.devnull,
            "GIT_ALLOW_PROTOCOL": "file",
            "GIT_AUTHOR_NAME": "Release Test",
            "GIT_AUTHOR_EMAIL": "release@example.invalid",
            "GIT_COMMITTER_NAME": "Release Test",
            "GIT_COMMITTER_EMAIL": "release@example.invalid",
            "REAL_AWK": shutil.which("awk"),
            "REAL_GIT": shutil.which("git"),
            "RELEASE_TEST_CASE": str(self.case),
            "PLAINSAY_NIGHTLY_STATE_DIR": str(self.state),
            "SIGN_IDENTITY": DEV_ID,
            "REBUILD": "1",
        }
        self.git("init", "-q", self.seed, cwd=self.case)
        self.git("symbolic-ref", "HEAD", "refs/heads/main")
        scripts = self.seed / "Scripts"
        scripts.mkdir()
        for file in ("nightly-release.sh", "release.sh", "release-state.sh",
                     "check-release-keychain.swift", "deploy-site.sh"):
            shutil.copy2(ROOT / "Scripts" / file, scripts / file)
        bundle = scripts / "bundle.sh"
        bundle.write_text(f"#!/bin/bash\nexec {shlex.quote(str(SCRIPT))} --bundle\n")
        bundle.chmod(0o755)
        (self.seed / ".gitignore").write_text("build/\n.build/\ndist/\n")
        for slug in ("privacy", "terms"):
            path = self.seed / "docs" / slug
            path.mkdir(parents=True)
            (path / "index.html").write_text("DMT Sp. z o.o.\n")
        (self.seed / "docs/index.html").write_text("Test site\n")
        self.plist("0.2.38", "238")
        self.git("add", ".")
        self.git("commit", "-qm", "last stable")
        self.git("tag", "v0.2.38")
        self.git("commit", "--allow-empty", "-qm", "new source")
        self.source = self.git("rev-parse", "HEAD")
        self.git("commit", "--allow-empty", "-qm", "next source")
        self.env["NEXT_SHA"] = self.git("rev-parse", "HEAD")
        self.git("reset", "--hard", self.source)
        self.local_checkout()

    def git(self, *args, cwd=None):
        # Fixture setup only. Production scripts use the guarded git shim.
        return git(*args, cwd=cwd or self.seed, env={**self.env, "PATH": os.defpath})

    def local_checkout(self):
        for path in (self.remote, self.checkout):
            if path.exists():
                shutil.rmtree(path)
        self.git("clone", "-q", "--bare", self.seed, self.remote)
        self.git("clone", "-q", self.remote, self.checkout)
        self.git("update-ref", "refs/test/next", self.env["NEXT_SHA"], cwd=self.remote)

    def plist(self, version, build):
        data = {
            "CFBundleShortVersionString": version,
            "CFBundleVersion": build,
            "LSMinimumSystemVersion": "14.0",
            "SUPublicEDKey": "fixture",
        }
        (self.seed / "Scripts/Info.plist").write_bytes(plistlib.dumps(data))

    def bump_main(self, version="0.3.0", build="300"):
        self.plist(version, build)
        self.git("commit", "-qam", f"version {version}")
        self.local_checkout()

    def add_off_main_tag(self, rogue=False, new_source=True):
        self.plist("0.2.39", "239")
        if rogue:
            (self.seed / "unexpected").touch()
        self.git("add", ".")
        self.git("commit", "-qm", "off-main release")
        self.git("tag", "v0.2.39")
        self.git("reset", "--hard", self.source)
        if new_source:
            self.git("commit", "--allow-empty", "-qm", "new source after tag")
        self.local_checkout()

    def make_tap(self):
        tap = self.case / "tap"
        self.git("init", "-q", tap)
        self.git("symbolic-ref", "HEAD", "refs/heads/main", cwd=tap)
        (tap / "Casks").mkdir()
        (tap / "Casks/plainsay.rb").write_text(
            'cask "plainsay" do\n  version "0.2.38"\n  sha256 "old"\n  url "old"\nend\n'
        )
        self.git("add", ".", cwd=tap)
        self.git("commit", "-qm", "old cask", cwd=tap)
        self.git("clone", "-q", "--bare", tap, self.case / "tap.git")

    def run_release(self, *args, status=0, match="", mode=None, **overrides):
        env = {**self.env, **overrides}
        if mode:
            env["RELEASE_TEST_MODE"] = mode
        result = subprocess.run(
            args, cwd=self.checkout, env=env, stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT, text=True, timeout=45, check=False,
        )
        self.assertEqual(result.returncode, status, result.stdout)
        self.assertIn(match, result.stdout)
        return result.stdout

    def nightly(self, *args, **kwargs):
        return self.run_release("./Scripts/nightly-release.sh", *args, **kwargs)

    def manual(self, *args, **kwargs):
        return self.run_release("./Scripts/release.sh", "0.3.0", "Test notes", *args, **kwargs)

    def install_sign_update(self):
        path = self.checkout / ".build/artifacts/sparkle/Sparkle/bin/sign_update"
        path.parent.mkdir(parents=True)
        path.symlink_to(self.case / "bin/sign_update")

    def events(self):
        return (self.case / "events").read_text()

    def assert_unlocked(self):
        self.assertFalse((self.state / "nightly.lock").exists())

    def assert_clean_nightly(self):
        self.assert_unlocked()
        self.assertFalse(list(self.state.glob("nightly.*")))

    def assert_artifacts_retained(self):
        data = dict(
            line.split("=", 1)
            for line in (self.state / "publish.pending").read_text().splitlines()
        )
        dist = Path(data["local_checkout"]) / "dist"
        for filename, field in (
            ("Plainsay-0.3.0.zip", "zip_sha"),
            ("Plainsay-0.3.0.dmg", "dmg_sha"),
            ("appcast.xml", "feed_sha"),
        ):
            self.assertEqual(hashlib.sha256((dist / filename).read_bytes()).hexdigest(), data[field])
        tap = Path(data["local_tap"])
        self.assertEqual(self.git("log", "-1", "--format=%s", cwd=tap), "Plainsay 0.3.0")
        self.assertTrue((self.case / "staged").is_dir())
        self.assert_unlocked()
        return data

    def test_green(self):
        self.nightly("--dry-run", match="v0.2.39 (build 239)")

    def test_pending_ci(self):
        self.nightly("--dry-run", CI_RESULT="in_progress pending", match="Deferring")

    def test_missing_ci(self):
        self.nightly("--dry-run", CI_RESULT="missing", match="Deferring")

    def test_last_tag_unreleased(self):
        self.nightly("--dry-run", status=1, STABLE="false", match="no public stable release")

    def test_held_lock_preserved(self):
        lock = self.state / "nightly.lock"
        lock.mkdir()
        (lock / "pid").write_text("fixture")
        self.nightly("--dry-run", status=1, match="cannot acquire")
        self.manual(status=1, match="cannot acquire")
        self.assertEqual((lock / "pid").read_text(), "fixture")

    def test_pending_marker_blocks_both(self):
        marker = self.state / "publish.pending"
        marker.write_text("fixture")
        self.nightly("--dry-run", status=1, match="needs reconciliation")
        self.manual(status=1, match="needs reconciliation")
        self.assertEqual(marker.read_text(), "fixture")
        self.assert_clean_nightly()

    def test_off_main_tag_no_new_source(self):
        self.add_off_main_tag(new_source=False)
        self.nightly("--dry-run", match="No new main commits since v0.2.39")

    def test_off_main_tag_new_source(self):
        self.add_off_main_tag()
        self.nightly("--dry-run", match="v0.2.40 (build 240)")

    def test_plist_ahead(self):
        self.bump_main()
        self.nightly("--dry-run", match="v0.3.0 (build 300)")

    def test_rogue_tag(self):
        self.add_off_main_tag(rogue=True)
        self.nightly("--dry-run", status=1, match="outside main's release history")

    def test_red_ci(self):
        self.nightly("--dry-run", CI_RESULT="completed failure", match="Deferring")

    def test_ahead_build_must_exceed_last_tag(self):
        self.bump_main(build="238")
        self.nightly("--dry-run", status=1, match="needs a build newer than")

    def test_plist_ahead_keeps_tested_sha_and_recovery_artifacts(self):
        self.bump_main()
        self.make_tap()
        output = self.nightly(status=1, mode="draft-fails", match="Kept worktree")
        data = self.assert_artifacts_retained()
        self.assertIn(data["local_checkout"], output)
        self.assertEqual(data["commit"], self.git("rev-parse", "HEAD", cwd=self.checkout))
        self.assertEqual(data["tag"], "v0.3.0")
        self.assertEqual(data["build"], "300")
        self.assertIn("<sparkle:version>300</sparkle:version>",
                      (Path(data["local_checkout"]) / "dist/appcast.xml").read_text())
        self.manual(status=1, match="needs reconciliation")

    def test_manual_failure_blocks_nightly_and_retains_artifacts(self):
        self.bump_main()
        self.make_tap()
        self.install_sign_update()
        self.manual(status=1, mode="draft-fails", match="Kept release artifacts")
        self.assertEqual(self.assert_artifacts_retained()["local_checkout"], str(self.checkout))
        self.nightly("--dry-run", status=1, match="needs reconciliation")

    def test_manual_same_version_after_nightly_dry_run(self):
        self.bump_main()
        self.nightly("--dry-run", match="v0.3.0 (build 300)")
        self.make_tap()
        self.install_sign_update()
        self.manual(match="Published 0.3.0")
        self.assertFalse((self.state / "publish.pending").exists())
        self.assertFalse(list((self.checkout / "dist").glob("tap.*")))
        self.assertIn("osascript Scripts/dmg-layout.applescript", self.events())
        self.assert_unlocked()

    def test_nightly_from_unchanged_plist_cleans_worktree_on_success(self):
        self.make_tap()
        self.nightly(match="Nightly publish complete for v0.2.39")
        self.assertFalse((self.state / "publish.pending").exists())
        self.assertIn("refs/tags/v0.2.39", self.events())
        self.assert_clean_nightly()

    def test_locked_keychain_releases_nightly_lock(self):
        self.nightly("--prepare-only", status=1, mode="locked-keychain", match="Unlock it")
        self.assertNotRegex(self.events(), r"codesign |xcrun |sign_update -p |ssh ")
        self.assert_clean_nightly()

    def test_hung_identity_check_times_out_and_releases_manual_lock(self):
        self.bump_main()
        self.install_sign_update()
        started = time.monotonic()
        self.manual("--prepare-only", status=1, mode="hung-keychain", match="15 seconds")
        self.assertLess(time.monotonic() - started, 25)
        self.assertNotRegex(self.events(), r"codesign |xcrun |sign_update -p |ssh ")
        self.assert_unlocked()

    def test_main_advanced_before_build(self):
        self.nightly(status=1, mode="early-main", match="origin/main moved")
        self.assertNotRegex(self.events(), r"swift build|xcrun |ssh ")
        self.assert_clean_nightly()

    def test_main_advanced_after_staging(self):
        self.make_tap()
        self.nightly(status=1, mode="late-main", match="origin/main moved")
        self.assertIn("rm -rf", self.events())
        self.assertNotRegex(self.events(), r"\.release-backups|git push|gh release create")
        self.assert_clean_nightly()

    def test_live_feed_advanced_after_staging(self):
        self.make_tap()
        self.nightly(status=1, mode="late-feed", match="newer than the published Sparkle build 300")
        self.assertIn("rm -rf", self.events())
        self.assertNotRegex(self.events(), r"\.release-backups|git push|gh release create")
        self.assert_clean_nightly()


if __name__ == "__main__":
    name = Path(sys.argv[0]).name
    if name != SCRIPT.name:
        sys.exit(fake_tool(name, sys.argv[1:]))
    if sys.argv[1:] == ["--bundle"]:
        fake_bundle()
    else:
        unittest.main()
