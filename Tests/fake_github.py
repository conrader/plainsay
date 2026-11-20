#!/usr/bin/env python3
"""A fake `gh` for GitHub release endpoints, backed by a JSON state file.

The state holds `releases` (tag_name, draft, prerelease, assets with id, name
and digest), the `latest` tag, the published `cask` text and optional
`delete_errors` mapping asset ids to an HTTP status, and optional
`after_list` fields merged into the state once the release listing is served,
and `corrupt_uploads`, which stores a wrong digest for uploaded assets. `--jq` filters run
through the real jq, so the scripts' filters are exercised as written.
"""

import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

REPO = "repos/conrader/plainsay"
CASK = "repos/conrader/homebrew-plainsay/contents/Casks/plainsay.rb"


def load(path):
    return json.loads(Path(path).read_text())


def save(path, state):
    Path(path).write_text(json.dumps(state, indent=1))


def emit(data, jq):
    if jq is None:
        print(json.dumps(data))
        return 0
    return subprocess.run((shutil.which("jq"), "-r", jq), input=json.dumps(data), text=True, check=False).returncode


def add_release(state, tag, files):
    """Mirror `gh release create TAG FILE...` as a draft with digests."""
    next_id = 1 + max((a["id"] for r in state["releases"] for a in r["assets"]), default=0)
    assets = [{"id": next_id + i, "name": Path(f).name,
               "digest": "sha256:" + hashlib.sha256(Path(f).read_bytes()).hexdigest()}
              for i, f in enumerate(files)]
    state["releases"].insert(0, {"tag_name": tag, "draft": True, "prerelease": False, "assets": assets})


def handles(args):
    """Whether `gh ARGS` addresses a release endpoint this fake serves."""
    return args[:1] == ["api"] and any(a.startswith(f"{REPO}/releases") for a in args)


def api(args, state_path):
    """Serve `gh api` for the release endpoints; return the exit status."""
    state = load(state_path)
    jq = args[args.index("--jq") + 1] if "--jq" in args else None
    endpoint = next(a for a in args[1:] if a.startswith("repos/"))
    if endpoint == CASK:
        print(state["cask"], end="")
        return 0
    if endpoint == f"{REPO}/releases/latest":
        return emit(next(r for r in state["releases"] if r["tag_name"] == state["latest"]), jq)
    if endpoint.startswith(f"{REPO}/releases?"):
        assert "--paginate" in args
        code = emit(state["releases"], jq)
        # Simulate a pointer change racing the listing, e.g. a rollback.
        if "after_list" in state:
            state.update(state.pop("after_list"))
            save(state_path, state)
        return code
    if endpoint.startswith(f"{REPO}/releases/tags/"):
        tag = endpoint.rsplit("/", 1)[1]
        entry = next((r for r in state["releases"] if r["tag_name"] == tag), None)
        if entry is None:
            print("gh: Not Found (HTTP 404)", file=sys.stderr)
            return 1
        return emit(entry, jq)
    prefix = f"{REPO}/releases/assets/"
    assert endpoint.startswith(prefix) and args[1:3] == ["-X", "DELETE"], args
    asset = int(endpoint[len(prefix):])
    status = state.get("delete_errors", {}).get(str(asset))
    if status == "404-gone":
        # Another client deleted the asset between the check and this DELETE.
        for release in state["releases"]:
            release["assets"] = [a for a in release["assets"] if a["id"] != asset]
        save(state_path, state)
        status = 404
    if status:
        # A 404 for an existing asset models a token that may not delete it.
        print(f"gh: Server Error (HTTP {status})", file=sys.stderr)
        return 1
    for release in state["releases"]:
        if any(a["id"] == asset for a in release["assets"]):
            release["assets"] = [a for a in release["assets"] if a["id"] != asset]
            save(state_path, state)
            return 0
    print("gh: Not Found (HTTP 404)", file=sys.stderr)
    return 1


def release(args, state_path):
    """Serve `gh release create|edit` against the same state."""
    state = load(state_path)
    tag = args[2]
    if args[1] == "create":
        files = [a for a in args[3:] if Path(a).is_file()]
        add_release(state, tag, files)
    elif args[1] == "upload":
        entry = next(r for r in state["releases"] if r["tag_name"] == tag)
        draft = entry["draft"]
        add_release(state, tag, [a for a in args[3:] if Path(a).is_file()])
        uploaded = state["releases"].pop(0)
        if state.get("corrupt_uploads"):
            for asset in uploaded["assets"]:
                asset["digest"] = "sha256:" + "0" * 64
        entry["assets"] += uploaded["assets"]
        entry["draft"] = draft
    elif args[1] == "edit":
        entry = next(r for r in state["releases"] if r["tag_name"] == tag)
        if any(a.startswith("--draft") for a in args):
            entry["draft"] = "--draft=false" not in args
        if "--latest" in args:
            state["latest"] = tag
    save(state_path, state)


if __name__ == "__main__":
    log = os.environ.get("FAKE_GITHUB_LOG")
    if log:
        with open(log, "a") as stream:
            stream.write(" ".join(["gh", *sys.argv[1:]]) + "\n")
    if sys.argv[1:2] == ["release"]:
        sys.exit(release(sys.argv[1:], os.environ["FAKE_GITHUB_STATE"]))
    sys.exit(api(sys.argv[1:], os.environ["FAKE_GITHUB_STATE"]))
