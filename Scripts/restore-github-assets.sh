#!/bin/bash
# Roll GitHub back to an older release whose binaries a prune deleted.
#
#   Scripts/restore-github-assets.sh VERSION DMG ZIP DMG_SHA256
#
# DMG and ZIP are the files extracted from the verified OVH rollback archive
# (its releases/Plainsay-latest.dmg and releases/Plainsay-VERSION.zip).
# DMG_SHA256 is the checksum of the cask being restored. The order is fixed:
# upload what is missing, read every digest back from GitHub, and only then
# make vVERSION the Latest release. Revert the cask after this succeeds.
# An existing asset with a different digest is never replaced.
set -euo pipefail

VERSION="${1:-}"
DMG="${2:-}"
ZIP="${3:-}"
CASK_SHA="${4:-}"
REPO=conrader/plainsay

fail() {
	echo "restore-github-assets: $*" >&2
	exit 1
}

[[ $# -eq 4 && "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "usage: $0 VERSION DMG ZIP DMG_SHA256"
[[ "$CASK_SHA" =~ ^[a-f0-9]{64}$ ]] || fail "invalid DMG checksum"
[[ -f "$DMG" && ! -L "$DMG" && -f "$ZIP" && ! -L "$ZIP" ]] || fail "DMG and ZIP must be regular files"

sha256() { shasum -a 256 "$1" | awk '{print $1}'; }
DMG_SHA=$(sha256 "$DMG")
ZIP_SHA=$(sha256 "$ZIP")
[ "$DMG_SHA" = "$CASK_SHA" ] || fail "the DMG is not the one the restored cask installs"

# NAME=DIGEST for every asset of the public, non-prerelease vVERSION.
assets() {
	gh api "repos/$REPO/releases/tags/v$VERSION" --jq \
		'if .draft or .prerelease then error("v'"$VERSION"' is not a public stable release") else .assets[] | .name + "=" + (.digest // "") end'
}

workdir=$(mktemp -d)
trap 'rm -rf -- "$workdir"' EXIT
current=$(assets) || fail "could not read release v$VERSION"
for kind in dmg zip; do
	name="Plainsay-$VERSION.$kind"
	if [ "$kind" = dmg ]; then file=$DMG sha=$DMG_SHA; else file=$ZIP sha=$ZIP_SHA; fi
	if ! awk -F= -v name="$name" '$1 == name { found = 1 } END { exit !found }' <<<"$current"; then
		# Upload under the versioned name the cask and the old pages refer to.
		cp -- "$file" "$workdir/$name"
		gh release upload "v$VERSION" "$workdir/$name"
		echo "    Uploaded $name"
	elif grep -Fqx "$name=sha256:$sha" <<<"$current"; then
		echo "    Kept $name"
	else
		fail "v$VERSION already has a $name with another or no digest; not replacing it"
	fi
done

# Read back from GitHub before switching any pointer.
current=$(assets) || fail "could not read release v$VERSION back"
grep -Fqx "Plainsay-$VERSION.dmg=sha256:$DMG_SHA" <<<"$current" || fail "GitHub DMG digest does not match after upload"
grep -Fqx "Plainsay-$VERSION.zip=sha256:$ZIP_SHA" <<<"$current" || fail "GitHub ZIP digest does not match after upload"
echo "    Verified v$VERSION's DMG and ZIP on GitHub"

gh release edit "v$VERSION" --latest
latest=$(gh api "repos/$REPO/releases/latest" --jq .tag_name)
[ "$latest" = "v$VERSION" ] || fail "GitHub Latest is $latest, not v$VERSION"
echo "    v$VERSION is Latest. Now revert the cask to sha256 $DMG_SHA."
