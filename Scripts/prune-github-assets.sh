#!/bin/bash
# Delete the versioned DMG and ZIP assets of every GitHub Release older than
# the live one, once GitHub and the Homebrew cask both serve the live version.
#
#   Scripts/prune-github-assets.sh VERSION [DMG_SHA256]
#
# DRY_RUN=1 performs every read and check and only lists the deletions.
#
# Fails closed: nothing is deleted unless the cask installs VERSION, the
# latest public release is vVERSION and its DMG digest matches the cask. Only
# assets named Plainsay-X.Y.Z.{dmg,zip} on non-draft releases whose X.Y.Z is
# lower than VERSION are touched. Safe to rerun: assets that are already gone
# are skipped.
set -euo pipefail

VERSION="${1:-}"
EXPECTED_DMG_SHA="${2:-}"
REPO=conrader/plainsay
TAP=conrader/homebrew-plainsay
SEMVER='[0-9]+\.[0-9]+\.[0-9]+'

fail() {
	echo "prune-github-assets: $*" >&2
	exit 1
}

[[ "$VERSION" =~ ^$SEMVER$ ]] || fail "usage: $0 VERSION [DMG_SHA256]"
[[ -z "$EXPECTED_DMG_SHA" || "$EXPECTED_DMG_SHA" =~ ^[a-f0-9]{64}$ ]] || fail "invalid DMG checksum"

# Integers compared component by component; 10# guards against octal parsing.
older() {
	local -a left right
	local i
	IFS=. read -ra left <<<"$1"
	IFS=. read -ra right <<<"$2"
	for i in 0 1 2; do
		if ((10#${left[i]} != 10#${right[i]})); then
			((10#${left[i]} < 10#${right[i]}))
			return
		fi
	done
	return 1
}

CASK=$(gh api -H "Accept: application/vnd.github.raw" "repos/$TAP/contents/Casks/plainsay.rb")
grep -Fxq "  version \"$VERSION\"" <<<"$CASK" || fail "the published cask does not install $VERSION"
CASK_SHA=$(sed -nE 's/^  sha256 "([a-f0-9]{64})"$/\1/p' <<<"$CASK")
[[ "$CASK_SHA" =~ ^[a-f0-9]{64}$ ]] || fail "the published cask has no single DMG checksum"
[[ -z "$EXPECTED_DMG_SHA" || "$CASK_SHA" = "$EXPECTED_DMG_SHA" ]] ||
	fail "the published cask checksum differs from the shipped DMG"

LIVE=$(gh api "repos/$REPO/releases/latest" --jq \
	'[.tag_name, (.draft | tostring), (.prerelease | tostring)] + [.assets[] | .name + "=" + (.digest // "")] | join(" ")')
read -ra LIVE_FIELDS <<<"$LIVE"
[[ "${LIVE_FIELDS[*]:0:3}" = "v$VERSION false false" ]] || fail "the latest public GitHub Release is not v$VERSION"
[[ " ${LIVE_FIELDS[*]:3} " = *" Plainsay-$VERSION.dmg=sha256:$CASK_SHA "* ]] ||
	fail "the live GitHub DMG digest does not match the cask"
[[ " ${LIVE_FIELDS[*]:3} " = *" Plainsay-$VERSION.zip="* ]] || fail "the live GitHub Release has no ZIP"

# One line per asset of every non-draft release: TAG ASSET_ID NAME.
# shellcheck disable=SC2016 # jq variable, not shell
ASSETS=$(gh api --paginate "repos/$REPO/releases?per_page=100" --jq \
	'.[] | select(.draft | not) | .tag_name as $tag | .assets[] | [$tag, (.id | tostring), .name] | join(" ")')

deleted=0
while read -r tag id name; do
	[ -n "$tag" ] || continue
	[[ "$tag" =~ ^v($SEMVER)$ ]] || continue
	version="${BASH_REMATCH[1]}"
	[[ "$id" =~ ^[0-9]+$ ]] || fail "unexpected asset id for $tag"
	[[ "$name" = "Plainsay-$version.dmg" || "$name" = "Plainsay-$version.zip" ]] || continue
	older "$version" "$VERSION" || continue
	if [ "${DRY_RUN:-0}" = 1 ]; then
		echo "    Would delete $tag/$name"
		continue
	fi
	if ! error=$(gh api -X DELETE "repos/$REPO/releases/assets/$id" 2>&1 >/dev/null); then
		[[ "$error" = *"(HTTP 404)"* ]] || fail "deleting $tag/$name: $error"
		echo "    Already gone: $tag/$name"
		continue
	fi
	echo "    Deleted $tag/$name"
	deleted=$((deleted + 1))
done <<<"$ASSETS"
echo "    Kept only v$VERSION's GitHub binaries ($deleted older assets deleted)"
