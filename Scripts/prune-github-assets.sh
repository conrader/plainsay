#!/bin/bash
# Delete the versioned DMG and ZIP assets of every GitHub Release older than
# the live one, once GitHub and the Homebrew cask both serve the live version.
#
#   Scripts/prune-github-assets.sh VERSION DMG_SHA256 ZIP_SHA256
#
# DRY_RUN=1 performs every read and check and only lists the deletions.
#
# Fails closed. Before the listing and again before every single delete it
# re-reads the cask and the latest release. Nothing is deleted unless the cask
# installs VERSION from vVERSION's own DMG with DMG_SHA256, and the latest
# release is the public, non-prerelease vVERSION whose DMG and ZIP digests
# equal the given checksums. Only assets named Plainsay-X.Y.Z.{dmg,zip} on
# public, non-prerelease releases whose X.Y.Z is lower than VERSION are
# touched. Safe to rerun: assets confirmed absent are skipped.
set -euo pipefail

VERSION="${1:-}"
DMG_SHA="${2:-}"
ZIP_SHA="${3:-}"
REPO=conrader/plainsay
TAP=conrader/homebrew-plainsay
SEMVER='[0-9]+\.[0-9]+\.[0-9]+'
# shellcheck disable=SC2016 # Ruby interpolation, not shell
CASK_URL='  url "https://github.com/conrader/plainsay/releases/download/v#{version}/Plainsay-#{version}.dmg"'

fail() {
	echo "prune-github-assets: $*" >&2
	exit 1
}

[[ $# -eq 3 && "$VERSION" =~ ^$SEMVER$ ]] || fail "usage: $0 VERSION DMG_SHA256 ZIP_SHA256"
[[ "$DMG_SHA" =~ ^[a-f0-9]{64}$ && "$ZIP_SHA" =~ ^[a-f0-9]{64}$ ]] || fail "invalid checksum"

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

# Whether $cask has exactly one line starting with PREFIX and it is LINE.
only_line() {
	[[ "$(grep -c "^$1" <<<"$cask")" = 1 ]] || return 1
	grep -Fxq "$2" <<<"$cask"
}

# The cask and GitHub Latest can be switched back by a rollback at any time,
# so this runs immediately before each delete, not once.
verify_live() {
	local cask live
	cask=$(gh api -H "Accept: application/vnd.github.raw" "repos/$TAP/contents/Casks/plainsay.rb") ||
		fail "could not read the published cask"
	only_line "  version " "  version \"$VERSION\"" || fail "the published cask does not install $VERSION"
	only_line "  url " "$CASK_URL" || fail "the published cask does not download v$VERSION's own GitHub DMG"
	only_line "  sha256 " "  sha256 \"$DMG_SHA\"" || fail "the published cask checksum differs from the shipped DMG"
	live=$(gh api "repos/$REPO/releases/latest" --jq \
		'[.tag_name, (.draft | tostring), (.prerelease | tostring)] + [.assets[] | .name + "=" + (.digest // "")] | join(" ")') ||
		fail "could not read the latest GitHub Release"
	read -ra LIVE_FIELDS <<<"$live"
	[[ "${LIVE_FIELDS[*]:0:3}" = "v$VERSION false false" ]] || fail "the latest public GitHub Release is not v$VERSION"
	[[ " ${LIVE_FIELDS[*]:3} " = *" Plainsay-$VERSION.dmg=sha256:$DMG_SHA "* ]] ||
		fail "the live GitHub DMG digest does not match the cask"
	[[ " ${LIVE_FIELDS[*]:3} " = *" Plainsay-$VERSION.zip=sha256:$ZIP_SHA "* ]] ||
		fail "the live GitHub ZIP is missing or its digest is not the shipped ZIP's"
}

# Whether asset ID still belongs to public, non-prerelease release TAG.
# Prints "absent" or "present"; fails on anything it cannot confirm.
asset_state() {
	local tag=$1 id=$2 out
	if out=$(gh api "repos/$REPO/releases/tags/$tag" --jq \
		"[(.draft or .prerelease | tostring), (any(.assets[]; .id == $id) | tostring)] | join(\" \")" 2>&1); then
		case "$out" in
		"false true") echo present ;;
		"false false") echo absent ;;
		*) echo changed ;;
		esac
	elif [[ "$out" = *"(HTTP 404)"* ]]; then
		echo absent
	else
		fail "could not read release $tag: $out"
	fi
}

verify_live

# One line per asset of every public, non-prerelease release: TAG ASSET_ID NAME.
# shellcheck disable=SC2016 # jq variable, not shell
ASSETS=$(gh api --paginate "repos/$REPO/releases?per_page=100" --jq \
	'.[] | select((.draft | not) and (.prerelease | not)) | .tag_name as $tag | .assets[] | [$tag, (.id | tostring), .name] | join(" ")')

deleted=0
while read -r tag id name; do
	[ -n "$tag" ] || continue
	[[ "$tag" =~ ^v($SEMVER)$ ]] || continue
	version="${BASH_REMATCH[1]}"
	[[ "$id" =~ ^[0-9]+$ ]] || fail "unexpected asset id for $tag"
	[[ "$name" = "Plainsay-$version.dmg" || "$name" = "Plainsay-$version.zip" ]] || continue
	older "$version" "$VERSION" || continue
	verify_live
	state=$(asset_state "$tag" "$id") || exit 1
	case "$state" in
	absent)
		echo "    Already gone: $tag/$name"
		continue ;;
	changed)
		echo "    Kept $tag/$name: the release is now a draft or prerelease"
		continue ;;
	esac
	if [ "${DRY_RUN:-0}" = 1 ]; then
		echo "    Would delete $tag/$name"
		continue
	fi
	if ! error=$(gh api -X DELETE "repos/$REPO/releases/assets/$id" 2>&1 >/dev/null); then
		[[ "$error" = *"(HTTP 404)"* ]] || fail "deleting $tag/$name: $error"
		# GitHub also answers 404 when the token may not delete an asset that
		# exists. Only an authorized read that no longer lists it proves absence.
		state=$(asset_state "$tag" "$id") || exit 1
		[ "$state" = absent ] ||
			fail "deleting $tag/$name returned HTTP 404 but the asset is still listed; check the token's permissions"
		echo "    Already gone: $tag/$name"
		continue
	fi
	echo "    Deleted $tag/$name"
	deleted=$((deleted + 1))
done <<<"$ASSETS"
echo "    Kept only v$VERSION's GitHub binaries ($deleted older assets deleted)"
