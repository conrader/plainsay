#!/bin/bash
# Release the newest tested main commit from the dedicated macOS signing host.
set -euo pipefail

case "${1:-}" in
	"") MODE=publish ;;
	--dry-run) MODE=dry-run ;;
	--prepare-only) MODE=prepare ;;
	-h|--help)
		echo "Usage: $0 [--dry-run | --prepare-only]"
		exit 0 ;;
	*) echo "Unknown option: $1" >&2; exit 2 ;;
esac
[ "$#" -le 1 ] || exit 2

umask 077
export GIT_TERMINAL_PROMPT=0 GH_PROMPT_DISABLED=1 SSH_ASKPASS_REQUIRE=never
export PATH="$PATH:/usr/libexec" # macOS PlistBuddy

cd "$(dirname "$0")/.."
ROOT=$(pwd -P)
# shellcheck source=Scripts/release-state.sh
source Scripts/release-state.sh
release_state_init

log() { printf '[%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"; }
fail() { log "ERROR: $*" >&2; exit 1; }

SCRATCH=""
WORKTREE=""
cleanup() {
	local result=$?
	trap - EXIT
	if [ "$result" -ne 0 ]; then log "Nightly release exited with status $result."; fi
	if [ -n "$SCRATCH" ]; then
		if [ -e "$PENDING" ]; then
			log "Kept worktree and release artifacts at $WORKTREE. See $PENDING."
		elif [ ! -d "$WORKTREE" ] || git -C "$ROOT" worktree remove --force "$WORKTREE"; then
			rmdir "$SCRATCH" || log "Inspect leftover scratch directory $SCRATCH."
		else
			log "Inspect leftover worktree $WORKTREE."
		fi
	fi
	release_lock || log "Inspect leftover lock $LOCK."
	exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
acquire_release_lock
check_pending_release

# Fetch only current remote tags into a private namespace, ignoring local tags.
TAG_REFS=refs/plainsay-nightly/tags
git fetch --quiet --no-tags --prune origin \
	'+refs/heads/main:refs/remotes/origin/main' "+refs/tags/v*:$TAG_REFS/v*"
SOURCE=$(git rev-parse refs/remotes/origin/main)
TAGS=$(git for-each-ref --format='%(refname:lstrip=3)' --sort=-version:refname "$TAG_REFS")
NUMBER='(0|[1-9][0-9]{0,8})'
SEMVER="$NUMBER\.$NUMBER\.$NUMBER"
LAST_TAG=""
while IFS= read -r tag; do
	if [[ "$tag" =~ ^v$SEMVER$ ]]; then LAST_TAG="$tag"; break; fi
done <<< "$TAGS"
[ -n "$LAST_TAG" ] || fail "origin has no vMAJOR.MINOR.PATCH release tag"
LAST_RELEASE=$(git rev-parse "$TAG_REFS/$LAST_TAG^{commit}")
LAST_SOURCE="$LAST_RELEASE"
if ! git merge-base --is-ancestor "$LAST_SOURCE" "$SOURCE"; then
	# An off-main release tag must add exactly one version bump to main.
	LAST_SOURCE=$(git rev-parse "$LAST_RELEASE^")
	if [ "$(git rev-list --parents -n 1 "$LAST_RELEASE")" != "$LAST_RELEASE $LAST_SOURCE" ] ||
		[ "$(git diff --name-only "$LAST_SOURCE" "$LAST_RELEASE")" != Scripts/Info.plist ] ||
		! git merge-base --is-ancestor "$LAST_SOURCE" "$SOURCE"; then
		fail "$LAST_TAG is outside main's release history"
	fi
fi

export GH_REPO=conrader/plainsay
[ "$(gh release view "$LAST_TAG" --json isDraft,isPrerelease --jq '.isDraft == false and .isPrerelease == false')" = true ] ||
	fail "$LAST_TAG has no public stable release. Inspect its publication first."
if [ "$SOURCE" = "$LAST_SOURCE" ]; then
	log "No new main commits since $LAST_TAG."
	exit 0
fi

CI=$(gh api --method GET "repos/$GH_REPO/actions/workflows/ci.yml/runs" \
	-f branch=main -f event=push -f head_sha="$SOURCE" -F per_page=1 \
	--jq '.workflow_runs[0] | if . then [.head_sha, .status, (.conclusion // "pending")] | join(" ") else "missing" end')
if [ "$CI" != "$SOURCE completed success" ]; then
	log "Deferring $SOURCE. Latest main push CI result is $CI."
	exit 0
fi

git show "$LAST_RELEASE:Scripts/Info.plist" > "$LOCK/last.plist"
git show "$SOURCE:Scripts/Info.plist" > "$LOCK/main.plist"
LAST_BUILD=$(PlistBuddy -c 'Print :CFBundleVersion' "$LOCK/last.plist")
MAIN_BUILD=$(PlistBuddy -c 'Print :CFBundleVersion' "$LOCK/main.plist")
MAIN_VERSION=$(PlistBuddy -c 'Print :CFBundleShortVersionString' "$LOCK/main.plist")
[[ "$LAST_BUILD" =~ ^$NUMBER$ && "$MAIN_BUILD" =~ ^$NUMBER$ && "$MAIN_VERSION" =~ ^$SEMVER$ ]] ||
	fail "main and $LAST_TAG must have numeric release metadata"

LAST_VERSION=${LAST_TAG#v}
HIGHEST_VERSION=$(printf '%s\n' "$LAST_VERSION" "$MAIN_VERSION" | sort -t . -k1,1nr -k2,2nr -k3,3nr | sed -n '1p')
if [ "$HIGHEST_VERSION" != "$LAST_VERSION" ]; then
	VERSION=$MAIN_VERSION
	BUILD=$MAIN_BUILD
	[ "$BUILD" -gt "$LAST_BUILD" ] || fail "main's unreleased v$VERSION needs a build newer than $LAST_TAG (build $LAST_BUILD)"
else
	IFS=. read -r major minor patch <<< "$LAST_VERSION"
	VERSION="$major.$minor.$((patch + 1))"
	BUILD=$(( (MAIN_BUILD > LAST_BUILD ? MAIN_BUILD : LAST_BUILD) + 1 ))
fi
[[ "$VERSION" =~ ^$SEMVER$ && "$BUILD" =~ ^$NUMBER$ ]] || fail "release version or build overflow"

log "$MODE: $LAST_TAG -> v$VERSION (build $BUILD), main $SOURCE, CI green."
if [ "$MODE" = dry-run ]; then exit 0; fi

[[ "$(uname -s)" = Darwin && "$(uname -m)" = arm64 ]] || fail "release requires an Apple silicon Mac"
LAST_KEY=$(PlistBuddy -c 'Print :SUPublicEDKey' "$LOCK/last.plist")
MAIN_KEY=$(PlistBuddy -c 'Print :SUPublicEDKey' "$LOCK/main.plist")
[[ -n "$LAST_KEY" && "$LAST_KEY" = "$MAIN_KEY" ]] || fail "Sparkle key rotation requires a coordinated release"
git var GIT_AUTHOR_IDENT >/dev/null
git var GIT_COMMITTER_IDENT >/dev/null

# The enclosing state and lock directories are private. Use normal modes
# for files that will end up inside the distributable app and DMG.
umask 022
SCRATCH=$(mktemp -d "$STATE/nightly.XXXXXX")
WORKTREE="$SCRATCH/source"
git worktree add --quiet --detach "$WORKTREE" "$SOURCE"
cd "$WORKTREE"
if [ "$VERSION" != "$MAIN_VERSION" ]; then
	PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" Scripts/Info.plist
	PlistBuddy -c "Set :CFBundleVersion $BUILD" Scripts/Info.plist
	git -c core.hooksPath=/dev/null -c commit.gpgSign=false commit --quiet -m "Release $VERSION" -- Scripts/Info.plist
fi

# Match the macOS CI unit suite. Do not install the locally built application.
check_nightly_main "$SOURCE"
log "Running the Swift build and tests for v$VERSION."
swift build </dev/null
swift test </dev/null
export CONFIG=release INSTALL=0 NOTARIZE=1 REBUILD=1
export PLAINSAY_RELEASE_KEYCHAIN="${PLAINSAY_RELEASE_KEYCHAIN:-$HOME/Library/Keychains/herdr-release.keychain-db}"
export DEPLOY_SITE_BRANCH=main
unset DEPLOY_SITE_SKIP_GIT_CHECK
export PLAINSAY_NIGHTLY_SOURCE="$SOURCE" PLAINSAY_NIGHTLY_LOCK_PID="$$"
NOTES="<p>Nightly update from main.</p><p><a href=\"https://github.com/$GH_REPO/compare/$LAST_TAG...v$VERSION\">Changes since $LAST_TAG</a></p>"
release_args=("$VERSION" "$NOTES")
if [ "$MODE" = prepare ]; then release_args+=(--prepare-only); fi
./Scripts/release.sh "${release_args[@]}" </dev/null
log "Nightly $MODE complete for v$VERSION."
