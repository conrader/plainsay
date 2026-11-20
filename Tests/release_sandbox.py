#!/usr/bin/env python3
"""Run macOS release control flow with local Git remotes and fake release tools."""

import hashlib
import os
import plistlib
from pathlib import Path
import re
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = Path(__file__).resolve()
WATCHDOG = ROOT / "Scripts/release-timeout.pl"
DEV_ID = "Test Developer ID"
KEYCHAIN_PASSWORD = 'fixture "quoted" \\ $password'


def git(*args, **kwargs):
    return subprocess.check_output(("git", *args), text=True, **kwargs).strip()


def fake_bundle(checkout=Path(".")):
    if "PLAINSAY_BUILD_SCRATCH_PATH" in os.environ:
        assert os.environ.get("INSTALL") == "0"
        path = Path(os.environ["PLAINSAY_BUILD_SCRATCH_PATH"]) / "artifacts/sparkle/Sparkle/bin/sign_update"
        path.parent.mkdir(parents=True, exist_ok=True)
        if not path.is_symlink():
            path.symlink_to(Path(os.environ["RELEASE_TEST_CASE"]) / "bin/sign_update")
    app = checkout / "build/Plainsay.app/Contents"
    app.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(checkout / "Scripts/Info.plist", app / "Info.plist")


def hang():
    signal.signal(signal.SIGALRM, signal.SIG_IGN)
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    time.sleep(30)


def fake_tool(tool, args):
    case = Path(os.environ["RELEASE_TEST_CASE"])
    logged_args = args
    if tool == "security" and args[:1] == ["unlock-keychain"]:
        logged_args = args[:1] + args[-1:]
    with (case / "events").open("a") as events:
        events.write(shlex.join([tool, *logged_args]) + "\n")
    mode = os.environ.get("RELEASE_TEST_MODE")
    env = os.environ
    marker = Path(env["PLAINSAY_NIGHTLY_STATE_DIR"]) / "publish.pending"
    unlocked_keychain = case / "release-keychain-unlocked"
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
        for item in ("backup_sha", "zip_sha", "dmg_sha", "feed_sha"):
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
    elif tool == "codesign":
        probe = case / "reuse-signature-probed"
        if (mode in ("reuse-signature-invalid", "hung-reuse-signature")
                and args == ["--verify", "--deep", "--strict", "build/Plainsay.app"]
                and not probe.exists()):
            probe.touch()
            print("codesign: fixture reuse signature failure", file=sys.stderr)
            if mode == "hung-reuse-signature":
                hang()
            return 1
    elif tool == "swift":
        if args[0] == "build":
            sign_update = Path(".build/artifacts/sparkle/Sparkle/bin/sign_update")
            sign_update.parent.mkdir(parents=True, exist_ok=True)
            sign_update.symlink_to(case / "bin/sign_update")
        elif args[0] == "Scripts/check-release-keychain.swift":
            return 1 if mode == "locked-keychain" else 0
        elif args[0] == "Scripts/verify-sparkle-signature.swift":
            if mode == "sparkle-signature-mismatch":
                print("The update signature does not match the app's Sparkle public key.", file=sys.stderr)
                return 1
        elif args[0] not in ("test", "Scripts/make-dmg-background.swift"):
            raise AssertionError(args)
    elif tool == "security":
        if args == ["-i"]:
            command = sys.stdin.read().splitlines()
            assert len(command) == 1
            assert shlex.split(command[0]) == [
                "unlock-keychain", "-p", KEYCHAIN_PASSWORD, "--", release_keychain(env),
            ]
            if mode == "notary-unlock-fails":
                print("security: fixture unlock failed", file=sys.stderr)
                return 1
            if mode == "hung-unlock":
                hang()
            unlocked_keychain.touch()
            return 0
        if args == ["list-keychains"]:
            keychain = release_keychain(env)
            if mode == "keychain-not-in-search-list":
                keychain += ".other"
            print(f'    "{keychain}"')
            return 0
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
        if args == ["-f", "%OLp"]:
            print(f"{os.fstat(sys.stdin.fileno()).st_mode & 0o7777:o}")
        else:
            assert args[0] == "-f%z"
            print(Path(args[1]).stat().st_size)
    elif tool == "sign_update":
        # Consume a fresh unlock just as the notary stub does.
        if release_keychain_configured(env):
            unlocked_keychain.unlink()
        if mode == "hung-sign-update":
            hang()
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
        if args == ["--find", "notarytool"]:
            print(case / "bin/notarytool")
        else:
            assert args[0] == "stapler"
    elif tool == "notarytool":
        assert args[0] == "submit"
        profile = ["--keychain-profile", "plainsay-notary"]
        if release_keychain_configured(env):
            assert args[-4:] == [*profile, "--keychain", release_keychain(env)]
            unlocked_keychain.unlink()
        else:
            assert args[-2:] == profile and "--keychain" not in args
        if mode == "hung-notarytool":
            hang()
        print('{"status": "Accepted"}')
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
        if command.startswith("/var/lib/plainsay-deploy/bin/release-retention "):
            action, *parameters = command.split()[1:]
            if action == "check":
                return 0
            if action == "backup":
                print(f"v{parameters[0]}.ABC_1234.tar {'0' * 64}")
            elif action == "activate":
                assert_marker()
                (server / next(server.glob("*.dmg")).name).rename(server / "Plainsay-latest.dmg")
            elif action == "prune":
                assert_marker()
                history = (case / "events").read_text()
                assert "api.plainsay.app/releases/Plainsay-latest.dmg" in history
                assert re.search(r"(?m)^gh api .*Casks/plainsay.rb", history)
                return 1 if mode == "prune-fails" else 0
            else:
                raise AssertionError(action)
        elif ".release-stage" in command and command.startswith("mktemp"):
            server.mkdir()
            print("/var/www/plainsay-updates/.release-stage.ABC123")
        elif command.startswith("cat > "):
            package = Path(command.strip("'")).name
            (server / package).write_bytes(sys.stdin.buffer.read())
        elif command.startswith("sha256sum"):
            package = Path(command.strip("'")).name
            print(hashlib.sha256((server / package).read_bytes()).hexdigest())
        elif command.startswith("rm -rf"):
            shutil.rmtree(server)
        else:
            assert command.startswith("sudo -n "), command
    elif tool == "scp":
        for package in args[-4:-1]:
            shutil.copyfile(package, server / Path(package).name)
    elif tool == "curl":
        artifact = Path(args[-1]).name
        if artifact == "appcast.xml" and not (server / "Plainsay-latest.dmg").exists():
            print(f"<sparkle:version>{(case / 'feed-build').read_text()}</sparkle:version>")
        elif artifact == "Plainsay-latest.dmg" and mode == "bad-public-dmg":
            print("unverified dmg")
        else:
            sys.stdout.buffer.write((server / artifact).read_bytes())
    else:
        assert tool in {"osascript", "rsync", "spctl", "xmllint"}, tool
    return 0


def release_keychain(env):
    return env.get("PLAINSAY_RELEASE_KEYCHAIN") or f"{env['HOME']}/Library/Keychains/herdr-release.keychain-db"


def release_kcpass(env):
    return Path(env.get("PLAINSAY_RELEASE_KCPASS") or f"{env['HOME']}/.herdr-release/kcpass")


def release_keychain_configured(env):
    password_file = release_kcpass(env)
    return "PLAINSAY_RELEASE_KEYCHAIN" in env or password_file.exists() or password_file.is_symlink()


class ReleaseTimeout(unittest.TestCase):
    sleep_commands = {"sleep 77", "/bin/sleep 77"}

    def setUp(self):
        workspace = tempfile.TemporaryDirectory(prefix="plainsay-timeout-test-")
        self.addCleanup(workspace.cleanup)
        self.case = Path(workspace.name)

    def live_process(self, pid):
        result = subprocess.run(("ps", "-p", str(pid), "-o", "stat=", "-o", "command="),
                                capture_output=True, text=True, check=False)
        fields = result.stdout.strip().split(maxsplit=1)
        # A killed orphan may still be a zombie until the system reaps it.
        return result.stdout.strip() if fields and not fields[0].startswith("Z") else ""

    def check_grandchild_stopped(self, pidfile):
        pid = int(pidfile.read_text())
        live = self.live_process(pid)
        if not live:
            return
        self.stop_fixture_sleep(pid, live)
        self.fail(f"Child PID {pid} survived the watchdog: {live}")

    def stop_fixture_sleep(self, pid, live):
        if live and live.split(maxsplit=1)[-1] in self.sleep_commands:
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass

    def check_wrapper_shutdown(self, first_signal, *, escalate=False):
        watchdog_file = self.case / "watchdog.pid"
        sleep_file = self.case / "sleep.pid"
        command = 'echo "$$" > "$1"; exec /bin/sleep 77'
        if escalate:
            command = 'trap "" TERM; ' + command
        with subprocess.Popen(
            ("/bin/bash", "-c", 'trap "exit 143" TERM; "$@"; exit "$?"', "_",
             "/bin/sh", "-c", 'echo "$$" > "$1"; shift; exec "$@"', "_", watchdog_file,
             WATCHDOG, "30", "Wrapper shutdown", "/bin/sh", "-c", command, "_", sleep_file),
            start_new_session=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        ) as wrapper:
            watchdog = None
            try:
                deadline = time.monotonic() + 3
                while time.monotonic() < deadline and wrapper.poll() is None:
                    if sleep_file.exists() and sleep_file.read_text().strip():
                        sleeper = int(sleep_file.read_text())
                        command_fields = self.live_process(sleeper).split(maxsplit=1)
                        if len(command_fields) == 2 and command_fields[1] in self.sleep_commands:
                            watchdog = int(watchdog_file.read_text())
                            break
                    time.sleep(0.01)
                else:
                    self.fail("Wrapper shutdown fixture did not start")
                self.assertEqual(os.getpgid(watchdog), wrapper.pid)
                self.assertNotEqual(os.getpgid(sleeper), wrapper.pid)

                # Mirror launchd's group delivery using the two verified fixture PIDs.
                if first_signal == signal.SIGTERM:
                    wrapper.terminate()
                    os.kill(watchdog, signal.SIGTERM)
                if escalate:
                    time.sleep(0.2)
                    self.assertTrue(self.live_process(sleeper), "Sleep did not ignore TERM")
                if first_signal == signal.SIGKILL or escalate:
                    # Kill the watchdog first so it cannot clean up on wrapper death.
                    os.kill(watchdog, signal.SIGKILL)
                    wrapper.kill()
                    # Bash may finish processing the foreground status or pending TERM first.
                    expected_statuses = (-signal.SIGKILL, 143 if escalate else 137)
                else:
                    expected_statuses = (143,)

                deadline = time.monotonic() + 1.5
                while time.monotonic() < deadline:
                    if wrapper.poll() is not None and not self.live_process(sleeper):
                        break
                    time.sleep(0.01)
                self.assertFalse(self.live_process(sleeper), "Sleep survived release shutdown")
                self.assertIn(wrapper.poll(), expected_statuses, "Wrapper did not exit promptly")
            finally:
                if watchdog is None and watchdog_file.exists() and watchdog_file.read_text().strip():
                    watchdog = int(watchdog_file.read_text())
                if watchdog is not None and str(WATCHDOG) in self.live_process(watchdog):
                    try:
                        os.kill(watchdog, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                if wrapper.poll() is None:
                    wrapper.kill()
                if sleep_file.exists() and sleep_file.read_text().strip():
                    sleeper = int(sleep_file.read_text())
                    self.stop_fixture_sleep(sleeper, self.live_process(sleeper))

    def test_kill_release_group_stops_sleep(self):
        self.check_wrapper_shutdown(signal.SIGKILL)

    def test_term_release_group_stops_sleep_promptly(self):
        self.check_wrapper_shutdown(signal.SIGTERM)

    def test_term_then_kill_release_group_stops_stubborn_sleep(self):
        self.check_wrapper_shutdown(signal.SIGTERM, escalate=True)

    def test_timeout_stops_grandchild(self):
        pidfile = self.case / "sleep.pid"
        self.addCleanup(self.check_grandchild_stopped, pidfile)
        started = time.monotonic()
        result = subprocess.run(
            (WATCHDOG, "1", "Grandchild test", "/bin/bash", "-c",
             'sleep 77 >/dev/null 2>&1 & echo "$!" > "$1"; wait', "_", pidfile),
            capture_output=True, text=True, timeout=4, check=False,
        )
        self.assertEqual(result.returncode, 124, result.stderr)
        self.assertLess(time.monotonic() - started, 4)
        self.assertIn("Grandchild test timed out after 1 seconds", result.stderr)

    def test_timeout_closes_command_substitution_stdout(self):
        pidfile = self.case / "sleep.pid"
        self.addCleanup(self.check_grandchild_stopped, pidfile)
        result = subprocess.run(
            ("/bin/bash", "-c", 'output=$("$@"); status=$?; printf "%s\\n" "$output"; exit "$status"',
             "_", WATCHDOG, "1", "Capture test", "/bin/bash", "-c",
             'trap "echo term; exit 0" TERM; (trap "" TERM; exec sleep 77) & '
             'echo "$!" > "$1"; echo started; wait', "_", pidfile),
            capture_output=True, text=True, timeout=4, check=False,
        )
        self.assertEqual(result.returncode, 124, result.stderr)
        self.assertEqual(result.stdout, "started\nterm\n")
        self.assertIn("Capture test timed out", result.stderr)

    def test_watchdog_forwards_signals_to_child_and_grandchild(self):
        command = """
import os
from pathlib import Path
import signal
import sys

def receive(signum, frame):
    print(f"{role} {signum}", flush=True)
    if role == "grandchild":
        sys.exit(0)

role = "child"
for signum in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
    signal.signal(signum, receive)
pid = os.fork()
signal.alarm(8)
if pid == 0:
    role = "grandchild"
    Path(sys.argv[1]).touch()
    signal.pause()
else:
    os.waitpid(pid, 0)
"""
        for signum in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
            with self.subTest(signal=signum.name):
                ready = self.case / signum.name
                with subprocess.Popen(
                    (WATCHDOG, "15", "Signal test", sys.executable, "-c", command, ready),
                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                ) as watchdog:
                    try:
                        deadline = time.monotonic() + 3
                        while not ready.exists() and watchdog.poll() is None and time.monotonic() < deadline:
                            time.sleep(0.01)
                        self.assertTrue(ready.exists(), "Signal fixture did not start")
                        watchdog.send_signal(signum)
                        stdout, stderr = watchdog.communicate(timeout=1.5)
                    finally:
                        if watchdog.poll() is None:
                            watchdog.kill()
                self.assertEqual(watchdog.returncode, 128 + signum, stderr)
                self.assertCountEqual(stdout.splitlines(), [f"child {int(signum)}", f"grandchild {int(signum)}"])


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
        self.kcpass = release_kcpass({"HOME": self.case})
        self.kcpass.parent.mkdir()
        self.kcpass.touch(mode=0o600)
        self.kcpass.write_text(f"{KEYCHAIN_PASSWORD}\n")
        (self.case / "feed-build").write_text("238")
        (self.case / "events").touch()
        bin_dir = self.case / "bin"
        bin_dir.mkdir()
        for name in ("awk", "codesign", "curl", "ditto", "gh", "git", "hdiutil", "notarytool", "osascript",
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
        for file in ("nightly-release.sh", "release.sh", "release-state.sh", "release-notary.sh",
                     "check-release-keychain.swift", "deploy-site.sh"):
            shutil.copy2(ROOT / "Scripts" / file, scripts / file)
        # Shorten selected deadlines in the fixture while running the real watchdog.
        shutil.copy2(WATCHDOG, scripts / "release-timeout-real.pl")
        timeout = scripts / "release-timeout.pl"
        timeout.write_text(
            '#!/usr/bin/perl\n'
            'use FindBin;\n'
            '$ARGV[0] = 2 if $ARGV[1] eq ($ENV{SHORTEN_RELEASE_TIMEOUT_FOR} // "");\n'
            'exec "$FindBin::Bin/release-timeout-real.pl", @ARGV or die "exec: $!\\n";\n'
        )
        timeout.chmod(0o755)
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

    def make_tap(self, target='app "Plainsay.app"'):
        tap = self.case / "tap"
        self.git("init", "-q", tap)
        self.git("symbolic-ref", "HEAD", "refs/heads/main", cwd=tap)
        (tap / "Casks").mkdir()
        (tap / "Casks/plainsay.rb").write_text(
            f'cask "plainsay" do\n  version "0.2.38"\n  sha256 "old"\n  url "old"\n  {target}\nend\n'
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

    def notary(self, **kwargs):
        return self.run_release("/bin/bash", "-x", "-c",
                                "source Scripts/release-notary.sh; release_notarytool submit fake.zip", **kwargs)

    def install_sign_update(self):
        path = self.checkout / ".build/artifacts/sparkle/Sparkle/bin/sign_update"
        path.parent.mkdir(parents=True)
        path.symlink_to(self.case / "bin/sign_update")

    def stage_notarized_app(self):
        self.bump_main()
        sign_update = self.checkout / "build/release-swiftpm/artifacts/sparkle/Sparkle/bin/sign_update"
        sign_update.parent.mkdir(parents=True)
        sign_update.symlink_to(self.case / "bin/sign_update")
        fake_bundle(self.checkout)
        commit = self.git("rev-parse", "HEAD", cwd=self.checkout)
        (self.checkout / "build/Plainsay.app.release-stamp").write_text(f"0.3.0 300 {commit}\n")

    def events(self):
        return (self.case / "events").read_text()

    def assert_sign_update(self, account, version="0.3.0"):
        calls = [shlex.split(line) for line in self.events().splitlines() if line.startswith("sign_update")]
        self.assertEqual(calls, [["sign_update", "-p", "--account", account, f"dist/Plainsay-{version}.zip"]])

    def assert_unlocked(self):
        self.assertFalse((self.state / "nightly.lock").exists())

    def assert_clean_nightly(self):
        self.assert_unlocked()
        self.assertFalse(list(self.state.glob("nightly.*")))

    def assert_no_publication(self):
        self.assertNotRegex(self.events(), r"(?m)^(?:ssh|scp|rsync|git push|gh release (?:create|edit)) ")
        self.assertFalse((self.state / "publish.pending").exists())

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
        self.manual(match="Published 0.3.0", INSTALL="1")
        self.assertFalse((self.state / "publish.pending").exists())
        for path in ("dist", "build/Plainsay.app", "build/Plainsay.app.release-stamp", "build/release-swiftpm"):
            self.assertFalse((self.checkout / path).exists(), path)
        self.assertTrue((self.checkout / ".build").is_dir())
        self.assertIn("osascript Scripts/dmg-layout.applescript", self.events())
        self.assert_unlocked()

    def test_renamed_cask_target_stops_before_publication(self):
        self.bump_main()
        self.make_tap(target='app "Plainsay.app", target: "Plainsay Next.app"')
        self.manual(status=1, match="must install a single Plainsay.app")
        self.assertNotRegex(self.events(), r"release-retention backup|git push|gh release create")
        self.assertFalse((self.state / "publish.pending").exists())

    def test_bad_public_artifact_blocks_prune_and_retains_staging(self):
        self.bump_main()
        self.make_tap()
        self.manual(status=1, mode="bad-public-dmg", match="published DMG checksum mismatch")
        self.assertNotIn("release-retention prune", self.events())
        self.assert_artifacts_retained()

    def test_prune_failure_keeps_marker_and_local_artifacts(self):
        self.bump_main()
        self.make_tap()
        self.manual(status=1, mode="prune-fails", match="Kept release artifacts")
        self.assertIn("release-retention prune", self.events())
        self.assert_artifacts_retained()

    def test_nightly_from_unchanged_plist_cleans_worktree_on_success(self):
        self.make_tap()
        kcpass = self.kcpass.rename(self.case / "custom kcpass")
        plist = ROOT / "Scripts/com.plainsay.nightly-release.plist"
        agent_env = plistlib.loads(plist.read_bytes())["EnvironmentVariables"]
        agent_env.pop("PATH")  # Keep the fake tools on PATH.
        self.nightly(match="Nightly publish complete for v0.2.39",
                     PLAINSAY_RELEASE_KEYCHAIN=str(self.case / 'custom "release" \\ keychain-db'),
                     PLAINSAY_RELEASE_KCPASS=str(kcpass), **agent_env)
        self.assert_sign_update("com.plainsay.sparkle", "0.2.39")
        self.assertFalse((self.state / "publish.pending").exists())
        self.assertIn("refs/tags/v0.2.39", self.events())
        self.assert_clean_nightly()

    def test_normal_sign_update_completes_nightly_preparation(self):
        self.nightly("--prepare-only", SHORTEN_RELEASE_TIMEOUT_FOR="sign_update",
                     match="Nightly prepare complete for v0.2.39")
        self.assert_sign_update("ed25519", "0.2.39")
        self.assertIn("swift Scripts/verify-sparkle-signature.swift dist/Plainsay-0.2.39.zip fake-signature ",
                      self.events())
        self.assert_no_publication()
        self.assert_clean_nightly()

    def test_hung_sign_update_times_out_before_publication(self):
        self.nightly(status=124, mode="hung-sign-update", SHORTEN_RELEASE_TIMEOUT_FOR="sign_update",
                     match="sign_update timed out after 2 seconds. See RELEASING.md")
        self.assert_sign_update("ed25519", "0.2.39")
        self.assertNotRegex(self.events(), r"verify-sparkle-signature|hdiutil ")
        self.assert_no_publication()
        self.assert_clean_nightly()

    def test_manual_notarization_uses_default_lookup_without_release_credentials(self):
        self.kcpass.unlink()
        self.bump_main()
        self.install_sign_update()
        self.manual("--prepare-only")
        self.assert_sign_update("ed25519")
        self.assertEqual(self.events().count("notarytool submit"), 2)
        self.assertNotIn("security -i", self.events())

    def test_manual_reuse_unlocks_release_keychain_before_signing(self):
        self.stage_notarized_app()
        self.manual("--prepare-only", REBUILD="0", PLAINSAY_SPARKLE_ACCOUNT="com.plainsay.sparkle",
                    match="Reusing build/Plainsay.app")
        self.assert_sign_update("com.plainsay.sparkle")
        events = self.events()
        self.assertLess(events.index("security -i\n"), events.index("sign_update "))
        self.assertNotIn("notarytool submit dist/notarize.zip", events)
        self.assertEqual(events.count("notarytool submit"), 1)

    def test_manual_reuse_signature_failure_falls_back_quietly(self):
        self.stage_notarized_app()
        output = self.manual("--prepare-only", REBUILD="0", mode="reuse-signature-invalid")
        self.assertNotIn("codesign: fixture reuse signature failure", output)
        self.assertNotIn("Reusing build/Plainsay.app", output)
        self.assertIn("notarytool submit dist/notarize.zip", self.events())

    def test_manual_reuse_signature_timeout_stays_visible(self):
        self.stage_notarized_app()
        output = self.manual("--prepare-only", REBUILD="0", mode="hung-reuse-signature", status=124,
                             SHORTEN_RELEASE_TIMEOUT_FOR="App signature verification",
                             match="App signature verification timed out after 2 seconds")
        self.assertNotIn("codesign: fixture reuse signature failure", output)
        self.assertNotIn("notarytool submit", self.events())
        self.assert_unlocked()

    def test_empty_sparkle_account_uses_default(self):
        self.stage_notarized_app()
        self.manual("--prepare-only", REBUILD="0", PLAINSAY_SPARKLE_ACCOUNT="")
        self.assert_sign_update("ed25519")

    def test_manual_reuse_stops_if_signing_keychain_is_not_in_search_list(self):
        self.stage_notarized_app()
        self.manual(REBUILD="0", mode="keychain-not-in-search-list", status=1,
                    match="missing from the Sparkle keychain search list")
        self.assertNotRegex(self.events(), r"security -i|sign_update|notarytool submit")
        self.assert_unlocked()

    def test_manual_reuse_stops_if_signing_keychain_unlock_fails(self):
        self.stage_notarized_app()
        output = self.manual(REBUILD="0", mode="notary-unlock-fails", status=1,
                             match="Could not unlock release keychain")
        self.assertIn("Reusing build/Plainsay.app", output)
        self.assertIn("security -i\n", self.events())
        self.assertNotRegex(self.events(), r"sign_update|notarytool submit")
        self.assert_unlocked()

    def test_sparkle_signature_mismatch_stops_publication(self):
        self.stage_notarized_app()
        self.manual(REBUILD="0", mode="sparkle-signature-mismatch", status=1,
                    match="The update signature does not match")
        self.assert_sign_update("ed25519")
        self.assertNotRegex(self.events(), r"hdiutil |ssh |git push|gh release create")
        self.assertFalse((self.state / "publish.pending").exists())
        self.assert_unlocked()

    def test_nightly_requires_password_file(self):
        self.kcpass.unlink()
        self.nightly("--prepare-only", status=1, match="Could not unlock release keychain")
        self.assertNotIn("notarytool submit", self.events())
        self.assert_clean_nightly()

    def test_explicit_keychain_requires_password_file(self):
        self.kcpass.unlink()
        self.notary(status=1, match="Could not unlock release keychain", PLAINSAY_RELEASE_KEYCHAIN="")
        self.assertNotIn("notarytool submit", self.events())

    def test_notary_rejects_group_or_world_readable_password_file(self):
        for mode in (0o640, 0o604):
            with self.subTest(mode=oct(mode)):
                self.kcpass.chmod(mode)
                self.notary(status=1, match="password file is group/world readable")
        self.assertNotRegex(self.events(), r"security -i|notarytool submit")

    def test_notary_password_stays_out_of_shell_trace(self):
        output = self.notary(match='{"status": "Accepted"}')
        self.assertNotIn("fixture", output)
        self.assertIn("security -i\n", self.events())

    def test_notary_unlock_failure_stops_before_submission(self):
        output = self.nightly("--prepare-only", status=1, mode="notary-unlock-fails",
                              match="Could not unlock release keychain")
        self.assertIn("security: fixture unlock failed", output)
        self.assertNotIn("notarytool submit", self.events())
        self.assert_clean_nightly()

    def test_hung_notary_unlock_times_out_before_submission(self):
        self.nightly(status=1, mode="hung-unlock", SHORTEN_RELEASE_TIMEOUT_FOR="Release keychain unlock",
                     match="Release keychain unlock timed out after 2 seconds. See RELEASING.md")
        self.assertIn("security -i\n", self.events())
        self.assertNotIn("notarytool submit", self.events())
        self.assert_no_publication()
        self.assert_clean_nightly()

    def test_hung_notarytool_times_out_before_publication(self):
        self.nightly(status=1, mode="hung-notarytool", SHORTEN_RELEASE_TIMEOUT_FOR="notarytool",
                     match="notarytool timed out after 2 seconds. See RELEASING.md")
        self.assertIn("notarytool submit dist/notarize.zip", self.events())
        self.assertNotIn("sign_update", self.events())
        self.assert_no_publication()
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
        self.assertNotRegex(self.events(), r"release-retention backup|git push|gh release create")
        self.assert_clean_nightly()

    def test_live_feed_advanced_after_staging(self):
        self.make_tap()
        self.nightly(status=1, mode="late-feed", match="newer than the published Sparkle build 300")
        self.assertIn("rm -rf", self.events())
        self.assertNotRegex(self.events(), r"release-retention backup|git push|gh release create")
        self.assert_clean_nightly()


if __name__ == "__main__":
    name = Path(sys.argv[0]).name
    if name != SCRIPT.name:
        sys.exit(fake_tool(name, sys.argv[1:]))
    if sys.argv[1:] == ["--bundle"]:
        fake_bundle()
    else:
        unittest.main()
