#!/bin/bash
# Cuts a release and publishes it to the update feed.
#
#   ./Scripts/release.sh 0.1.1 "What changed in this build"
#
# Builds, zips, signs the zip with the Sparkle EdDSA key from the Keychain,
# regenerates the appcast, and uploads both to the update host. The private
# signing key never leaves this Mac — the server only ever sees signatures.
#
# Also publishes a GitHub Release with the same notarized build attached and
# tags it, so github.com/conrader/plainsay/releases/latest always resolves to
# whatever this script last shipped, and the Releases page is the changelog —
# one call, not a second thing to remember to update.
# Remote paths are deliberately expanded by the local shell.
# shellcheck disable=SC2029
set -euo pipefail
export PATH="$PATH:/usr/libexec" # macOS PlistBuddy

cd "$(dirname "$0")/.."

VERSION="${1:?usage: release.sh <version> [notes] [--prepare-only]}"
NOTES="${2:-}"
MODE="${3:-}"
[[ "$#" -le 3 && ( -z "$MODE" || "$MODE" = --prepare-only ) ]] || {
	echo "usage: release.sh <version> [notes] [--prepare-only]" >&2
	exit 2
}
[ "${NOTARIZE:-1}" = 1 ] || {
	echo "release.sh requires notarization; use bundle.sh for a local build" >&2
	exit 1
}
NIGHTLY_SOURCE="${PLAINSAY_NIGHTLY_SOURCE:-}"
SSH_OPTIONS=()
if [ -n "$NIGHTLY_SOURCE" ]; then
	SSH_OPTIONS=(-o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=15)
	export PLAINSAY_MANAGED_DOCROOTS=1
fi
HOST="${HOST:-codex-server}"
REMOTE_DIR=/var/www/plainsay-updates
FEED_URL="https://api.plainsay.app"
# Keep the app bundle and DMG on the same Developer ID identity. bundle.sh has
# the same fallback, but variables assigned in a child script do not propagate
# back to this release process; without defining it here, `set -u` aborts when
# the finished DMG is signed.
export SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application: Konrad Sierzputowski (FQ5759XB2L)}"

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
	echo "version must be plain semver, for example 0.2.24" >&2
	exit 1
}

# shellcheck source=Scripts/release-state.sh
source Scripts/release-state.sh
release_state_init
DMG_STAGING=""
DMG_MOUNT=""
REMOTE_STAGE=""
TAP_DIR=""
cleanup() {
	local result=$?
	trap - EXIT
	if [ -n "$DMG_MOUNT" ]; then detach_dmg "$DMG_MOUNT" || true; fi
	if [ -n "$DMG_STAGING" ]; then rm -rf "$DMG_STAGING" || true; fi
	if [ -e "$PENDING" ]; then
		if [ -n "$TAP_DIR" ] && [ -z "$NIGHTLY_SOURCE" ]; then
			echo "Kept release artifacts at $PWD/dist. See $PENDING." >&2
		fi
	else
		if [ -n "$TAP_DIR" ]; then rm -rf "$TAP_DIR" || true; fi
		if [ -n "$REMOTE_STAGE" ]; then
			ssh "${SSH_OPTIONS[@]+"${SSH_OPTIONS[@]}"}" "$HOST" "rm -rf '$REMOTE_STAGE'" || \
				echo "Inspect leftover staging directory $REMOTE_STAGE" >&2
		fi
	fi
	release_lock || echo "Inspect leftover lock $LOCK." >&2
	exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
if [ -n "$NIGHTLY_SOURCE" ]; then
	# The nightly parent keeps the lock through worktree cleanup. Only its
	# direct release child can inherit it.
	if [ "${PLAINSAY_NIGHTLY_LOCK_PID:-}" != "$PPID" ] ||
		[ "$(cat "$LOCK/pid" 2>/dev/null)" != "$PPID" ]; then
		echo "Nightly publication requires the parent's release lock" >&2
		exit 1
	fi
else
	acquire_release_lock
fi
check_pending_release

SIGN_UPDATE=".build/artifacts/sparkle/Sparkle/bin/sign_update"
[ -x "$SIGN_UPDATE" ] || { echo "sign_update missing — run 'swift build' first" >&2; exit 1; }
command -v gh >/dev/null || { echo "gh CLI missing — needed to publish the GitHub Release" >&2; exit 1; }
[ "$SIGN_IDENTITY" != "-" ] || {
	echo "release DMGs require a Developer ID identity, not ad-hoc signing" >&2
	exit 1
}
validate_legal_page() {
	local page="$1"
	[ -s "$page" ] || {
		echo "$page missing or empty — add the reviewed document before releasing Cloud" >&2
		exit 1
	}
	grep -Fq "DMT Sp. z o.o." "$page" || {
		echo "$page does not identify DMT Sp. z o.o. as the operator" >&2
		exit 1
	}
	if grep -Fq "LEGAL_REVIEW_REQUIRED" "$page"; then
		echo "$page still contains LEGAL_REVIEW_REQUIRED — complete legal review before releasing Cloud" >&2
		exit 1
	fi
}

validate_legal_page docs/privacy/index.html
validate_legal_page docs/terms/index.html
[ -z "$(git status --porcelain)" ] || {
	echo "working tree is not clean — commit the exact source and legal documents before releasing" >&2
	exit 1
}
if gh release view "v$VERSION" >/dev/null 2>&1; then
	echo "GitHub Release v$VERSION already exists — choose a new version; this script never overwrites a release" >&2
	exit 1
fi
REMOTE_TAG=$(git ls-remote --tags origin "refs/tags/v$VERSION")
if [ -n "$REMOTE_TAG" ]; then
	echo "remote tag v$VERSION already exists without a matching release — inspect it before continuing" >&2
	exit 1
fi

# Sparkle compares CFBundleVersion, independently of the marketing version.
# Use the highest build in the feed even if it contains multiple items.
current_feed_build() {
	local build
	build=$(curl -fsSL --max-time 60 "$FEED_URL/appcast.xml" \
		| sed -n 's#.*<sparkle:version>\([0-9][0-9]*\)</sparkle:version>.*#\1#p' \
		| sort -nr | sed -n '1p') || return 1
	[[ "$build" =~ ^[1-9][0-9]{0,8}$ ]] || {
		echo "could not read the current Sparkle build from $FEED_URL/appcast.xml" >&2
		return 1
	}
	printf '%s\n' "$build"
}
check_feed_build() {
	local published
	published=$(current_feed_build) || return 1
	[ "$BUILD" -gt "$published" ] || {
		echo "build $BUILD must be newer than the published Sparkle build $published" >&2
		return 1
	}
}
check_release_candidate() {
	check_feed_build || return 1
	if [ -n "$NIGHTLY_SOURCE" ]; then check_nightly_main "$NIGHTLY_SOURCE"; fi
}

# Read rather than hardcoded a second time: this used to be a bare "15.0"
# literal here that silently stopped matching Info.plist's own
# LSMinimumSystemVersion the moment that changed (commit 1f54fe3 lowered the
# floor to Sonoma everywhere except this one line) — Sparkle filters every
# feed item whose minimumSystemVersion exceeds the running OS with no error
# surfaced anywhere, so the mismatch meant exactly the macOS 14 users that
# commit was meant to serve would silently never see another update again.
MIN_SYSTEM_VERSION=$(PlistBuddy -c "Print :LSMinimumSystemVersion" Scripts/Info.plist)
PLIST_VERSION=$(PlistBuddy -c "Print :CFBundleShortVersionString" Scripts/Info.plist)
BUILD=$(PlistBuddy -c "Print :CFBundleVersion" Scripts/Info.plist)

[ "$PLIST_VERSION" = "$VERSION" ] || {
	echo "Info.plist is $PLIST_VERSION, not $VERSION — commit the version bump before releasing" >&2
	exit 1
}
[[ "$BUILD" =~ ^[1-9][0-9]{0,8}$ ]] || { echo "Info.plist needs a positive integer build" >&2; exit 1; }
check_release_candidate
# Find any stale checkout or site validation errors before publication starts.
./Scripts/deploy-site.sh --check-only

if ! Scripts/release-timeout.pl 15 'Default keychain check' swift Scripts/check-release-keychain.swift ||
	! AVAILABLE_IDENTITIES=$(Scripts/release-timeout.pl 15 'Developer ID identity lookup' \
		security find-identity -v -p codesigning); then
	echo "Signing keychain is locked, unavailable, or did not respond within 15 seconds. Unlock it in the release user's login session and retry." >&2
	exit 1
fi
grep -Fq "$SIGN_IDENTITY" <<<"$AVAILABLE_IDENTITIES" || {
	echo "Developer ID identity not available: $SIGN_IDENTITY. Check the signing keychain and private key." >&2
	exit 1
}

echo "==> Version $VERSION (build $BUILD)"

# shellcheck source=Scripts/release-notary.sh
source Scripts/release-notary.sh
notarize() {
	local package="$1" result status
	result=$(release_notarytool submit "$package" \
		--wait --timeout 20m --output-format json) || return 1
	status=$(plutil -extract status raw -o - - <<< "$result") || return 1
	[ "$status" = Accepted ] || {
		echo "Apple notarization did not accept $package: $result" >&2
		return 1
	}
}

# A rerun after a late failure (the DMG step, an upload) shouldn't cost a
# rebuild and another notarization round trip. The stamp is written only after
# this exact version, build and commit was notarized, stapled and assessed —
# the tree is clean, so the commit pins the source — and the app is checked
# again before it is reused. REBUILD=1 forces a fresh build anyway.
APP_STAMP="build/Plainsay.app.release-stamp"
RELEASE_KEY="$VERSION $BUILD $(git rev-parse HEAD)"
reuse_notarized_app() {
	[ "${REBUILD:-0}" != "1" ] || return 1
	[ -d build/Plainsay.app ] && [ "$(cat "$APP_STAMP" 2>/dev/null)" = "$RELEASE_KEY" ] || return 1
	local plist=build/Plainsay.app/Contents/Info.plist
	[ "$(PlistBuddy -c "Print :CFBundleShortVersionString" "$plist" 2>/dev/null)" = "$VERSION" ] || return 1
	[ "$(PlistBuddy -c "Print :CFBundleVersion" "$plist" 2>/dev/null)" = "$BUILD" ] || return 1
	Scripts/release-timeout.pl 120 'App signature verification' \
		/bin/bash -c 'exec "$@" 2>/dev/null' _ codesign --verify --deep --strict build/Plainsay.app || return
	xcrun stapler validate build/Plainsay.app >/dev/null 2>&1 || return 1
	Scripts/release-timeout.pl 120 'App Gatekeeper assessment' spctl -a -t exec build/Plainsay.app
}

if reuse_notarized_app; then
	echo "==> Reusing build/Plainsay.app — already notarized and stapled for $VERSION at this commit (REBUILD=1 to rebuild)"
	rm -rf dist
else
	reuse_status=$?
	[ "$reuse_status" -ne 124 ] || exit "$reuse_status"
	rm -f "$APP_STAMP"
	./Scripts/bundle.sh
	Scripts/release-timeout.pl 120 'App signature verification' codesign --verify --deep --strict build/Plainsay.app
	if [ -n "$NIGHTLY_SOURCE" ]; then check_nightly_main "$NIGHTLY_SOURCE"; fi

	# Notarise before packaging for release. Without a ticket, Gatekeeper blocks
	# the app the first time anyone launches it from a download — which is every
	# new user, and every user whose update arrives quarantined.
	#
	# The credentials live in a Keychain profile created once with:
	#   xcrun notarytool store-credentials "plainsay-notary" \
	#     --keychain "${PLAINSAY_RELEASE_KEYCHAIN:-$HOME/Library/Keychains/herdr-release.keychain-db}" \
	#     --key <AuthKey_*.p8> --key-id <id> --issuer <uuid>
	echo "==> Notarising (a few minutes)"
	rm -rf dist && mkdir -p dist
	ditto -c -k --sequesterRsrc --keepParent build/Plainsay.app dist/notarize.zip
	notarize dist/notarize.zip
	xcrun stapler staple build/Plainsay.app
	# The ticket is what makes this offline-verifiable; without stapling, a
	# machine with no network sees an unnotarized app.
	xcrun stapler validate build/Plainsay.app
	Scripts/release-timeout.pl 120 'App Gatekeeper assessment' spctl -a -vvv -t exec build/Plainsay.app
	rm -f dist/notarize.zip
	echo "$RELEASE_KEY" > "$APP_STAMP"
fi

echo "==> Packaging"
mkdir -p dist
ZIP="dist/Plainsay-$VERSION.zip"
# ditto, not zip: it preserves the symlinks and extended attributes inside the
# framework, and a plain zip corrupts the signature on the way through.
ditto -c -k --sequesterRsrc --keepParent build/Plainsay.app "$ZIP"

LENGTH=$(stat -f%z "$ZIP")
echo "==> Signing $ZIP ($LENGTH bytes)"
# Sparkle uses the session search list. An app reused above skipped its unlock.
if release_keychain_configured; then
	if ! KEYCHAIN_SEARCH_LIST=$(Scripts/release-timeout.pl 15 'Keychain search list lookup' security list-keychains); then
		echo "Could not read the keychain search list for Sparkle signing." >&2
		exit 1
	fi
	if ! grep -Fxq -- "    \"$RELEASE_KEYCHAIN\"" <<<"$KEYCHAIN_SEARCH_LIST"; then
		echo "Release keychain $RELEASE_KEYCHAIN is missing from the Sparkle keychain search list." >&2
		exit 1
	fi
	unlock_release_keychain
fi
SIGNATURE=$(Scripts/release-timeout.pl 120 sign_update \
	"$SIGN_UPDATE" -p --account "${PLAINSAY_SPARKLE_ACCOUNT:-ed25519}" "$ZIP")
PUBLIC_KEY=$(PlistBuddy -c 'Print :SUPublicEDKey' build/Plainsay.app/Contents/Info.plist)
swift Scripts/verify-sparkle-signature.swift "$ZIP" "$SIGNATURE" "$PUBLIC_KEY"

# A DMG for GitHub is a nicer first download than a zip: Finder mounts it and
# shows a drag-to-Applications window, the pattern every Mac user already
# knows. Sparkle still ships the zip above — DMGs aren't what it expects.
#
# Built as a "fancy" DMG (large icons, an arrow toward /Applications, on
# Plainsay's own palette) rather than a bare folder view: create a
# read-write image, let Finder itself write the icon layout and background
# into a real .DS_Store by opening and arranging it, then convert that to
# the compressed read-only image actually shipped. Verified visually
# (screenshotted a locally-built DMG) before wiring this in — Finder's
# window bounds vs. icon-view content area have a well-known small offset
# in this recipe elsewhere, but it lines up correctly here as written.
echo "==> Building DMG"
if [ -n "$NIGHTLY_SOURCE" ]; then check_nightly_main "$NIGHTLY_SOURCE"; fi
DMG="dist/Plainsay-$VERSION.dmg"
DMG_STAGING=$(mktemp -d)
if [ -n "$NIGHTLY_SOURCE" ]; then
	# The login session owns the signing keys. Keep Finder automation out of
	# the unattended path so a TCC prompt cannot stall the release.
	ditto build/Plainsay.app "$DMG_STAGING/Plainsay.app"
	ln -s /Applications "$DMG_STAGING/Applications"
	hdiutil create -volname "Plainsay $VERSION" -srcfolder "$DMG_STAGING" -fs HFS+ \
		-format UDZO -ov "$DMG" >/dev/null
else
	DMG_RW="dist/Plainsay-$VERSION-rw.dmg"
	# Finder can keep a just-closed window's volume busy for a moment, so a single
	# detach attempt is not enough; the read-write image is scratch, so forcing
	# it as a last resort loses nothing.
	detach_dmg() {
		for _ in 1 2 3; do
			hdiutil detach "$1" -quiet 2>/dev/null && return 0
			sleep 2
		done
		hdiutil detach "$1" -force -quiet
	}
	ditto build/Plainsay.app "$DMG_STAGING/Plainsay.app"
	ln -s /Applications "$DMG_STAGING/Applications"
	mkdir -p "$DMG_STAGING/.background"
	swift Scripts/make-dmg-background.swift "$DMG_STAGING/.background" >/dev/null

	# A scratch image left mounted by an interrupted run would make this one mount
	# as "Plainsay $VERSION 1". Only our own read-write images are detached here.
	hdiutil info | awk -F'\t' '
		/^image-path/ { scratch = ($0 ~ /\/dist\/Plainsay-[0-9.]+-rw\.dmg$/) }
		scratch && $NF ~ /^\/Volumes\// { print $NF }
	' | while IFS= read -r stale; do
		echo "    detaching stale scratch volume $stale"
		detach_dmg "$stale" || true
	done

	rm -f "$DMG" "$DMG_RW"
	# Sized generously above the staged contents — this read-write image is
	# thrown away after the conversion below, so a few spare MB costs nothing.
	DMG_SIZE_MB=$(( $(du -sm "$DMG_STAGING" | cut -f1) + 40 ))
	hdiutil create -volname "Plainsay $VERSION" -srcfolder "$DMG_STAGING" -fs HFS+ \
		-format UDRW -size "${DMG_SIZE_MB}m" "$DMG_RW" >/dev/null

	# The mount point comes from hdiutil, not from the volume name we asked for:
	# if that name is already taken, the volume lands at "<name> 1".
	DMG_MOUNT=$(hdiutil attach "$DMG_RW" -readwrite -noverify -noautoopen \
		| awk -F'\t' '$NF ~ /^\/Volumes\// { mount = $NF } END { print mount }' \
		| sed 's/[[:space:]]*$//')
	[ -d "$DMG_MOUNT" ] || { echo "could not read the DMG mount point from hdiutil attach" >&2; exit 1; }
	DMG_VOLNAME=$(basename "$DMG_MOUNT")
	[ "$DMG_VOLNAME" = "Plainsay $VERSION" ] || \
		echo "    warning: volume mounted as \"$DMG_VOLNAME\" — another \"Plainsay $VERSION\" is already mounted" >&2

	# The layout is cosmetic; the app inside is what ships. If Finder cannot be
	# driven (see dmg-layout.applescript for the -1728 race it waits out), ship a
	# plain DMG rather than abort a release that is already built and notarized.
	if ! osascript Scripts/dmg-layout.applescript "$DMG_MOUNT" "$DMG_VOLNAME"; then
		echo "    warning: Finder layout failed — shipping a plain DMG without the custom window" >&2
		rm -f "$DMG_MOUNT/.DS_Store"
	fi

	sync
	detach_dmg "$DMG_MOUNT"
	DMG_MOUNT=""

	hdiutil convert "$DMG_RW" -format UDZO -ov -o "$DMG" >/dev/null
	rm -f "$DMG_RW"
fi
rm -rf "$DMG_STAGING"
DMG_STAGING=""

# The app inside is already signed and stapled, but Gatekeeper assesses the
# DMG container independently on first mount. Sign the container before
# notarizing it; a ticket alone is not a usable code signature and `spctl`
# will reject an unsigned DMG even when stapler can validate its ticket.
Scripts/release-timeout.pl 120 'DMG signing' codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG"
Scripts/release-timeout.pl 120 'DMG signature verification' codesign --verify --verbose=2 "$DMG"
notarize "$DMG"
xcrun stapler staple "$DMG" >/dev/null
xcrun stapler validate "$DMG" >/dev/null
Scripts/release-timeout.pl 120 'DMG Gatekeeper assessment' spctl -a -vvv -t open --context context:primary-signature "$DMG"

PUBDATE=$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")

cat > dist/appcast.xml <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Plainsay</title>
    <link>$FEED_URL/appcast.xml</link>
    <description>Updates for Plainsay</description>
    <language>en</language>
    <item>
      <title>$VERSION</title>
      <pubDate>$PUBDATE</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MIN_SYSTEM_VERSION</sparkle:minimumSystemVersion>
      <description><![CDATA[${NOTES:-<p>Bug fixes and improvements.</p>}]]></description>
      <enclosure
        url="$FEED_URL/releases/Plainsay-$VERSION.zip"
        length="$LENGTH"
        type="application/octet-stream"
        sparkle:edSignature="$SIGNATURE" />
    </item>
  </channel>
</rss>
XML
xmllint --nonet --noout dist/appcast.xml
if [ "$MODE" = --prepare-only ]; then
	echo "Prepared and verified $ZIP, $DMG and dist/appcast.xml."
	exit 0
fi
check_release_candidate

# Plain text for the release body: GitHub's own markdown renderer is what
# displays it, not Sparkle's CDATA-wrapped HTML — reusing the HTML string
# as-is would show literal <p> tags on the Releases page. Closing tags become
# a blank line so multi-paragraph notes still read as separate paragraphs
# instead of running together into one sentence.
BODY=$(printf '%s' "${NOTES:-Bug fixes and improvements.}" | sed -E 's#</p>#\n\n#g; s#<p>##g')

# Prepare every external artifact before changing a public URL. Uploads land
# in a unique directory on the same filesystem as the update feed, so the
# final renames cannot expose a partially transferred file.
echo "==> Staging update artifacts on $HOST"
if [ "${PLAINSAY_MANAGED_DOCROOTS:-0}" != 1 ]; then
	ssh "$HOST" "sudo -n mkdir -p '$REMOTE_DIR/releases' && sudo -n chown -R \$(whoami) '$REMOTE_DIR'"
fi
STAGE_PATH=$(ssh "${SSH_OPTIONS[@]+"${SSH_OPTIONS[@]}"}" "$HOST" "mktemp -d '$REMOTE_DIR/.release-stage.XXXXXX'")
case "$STAGE_PATH" in
	"$REMOTE_DIR"/.release-stage.[a-zA-Z0-9][a-zA-Z0-9][a-zA-Z0-9][a-zA-Z0-9][a-zA-Z0-9][a-zA-Z0-9]) ;;
	*) echo "unexpected remote staging path: $STAGE_PATH" >&2; exit 1 ;;
esac
REMOTE_STAGE=$STAGE_PATH
echo "    Remote staging directory: $REMOTE_STAGE"

ZIP_BASENAME=$(basename "$ZIP")
DMG_BASENAME=$(basename "$DMG")
if [ "${PLAINSAY_MANAGED_DOCROOTS:-0}" = 1 ]; then
	for artifact in "$ZIP" "$DMG" dist/appcast.xml; do
		ssh "${SSH_OPTIONS[@]+"${SSH_OPTIONS[@]}"}" "$HOST" \
			"cat > '$REMOTE_STAGE/${artifact##*/}'" < "$artifact"
	done
else
	scp -q "${SSH_OPTIONS[@]+"${SSH_OPTIONS[@]}"}" "$ZIP" "$DMG" dist/appcast.xml "$HOST:$REMOTE_STAGE/"
fi
verify_staged() {
	local package="$1" checksum="$2" remote_checksum
	remote_checksum=$(ssh "${SSH_OPTIONS[@]+"${SSH_OPTIONS[@]}"}" "$HOST" "sha256sum '$REMOTE_STAGE/$package'" | awk '{print $1}')
	[ "$remote_checksum" = "$checksum" ] || { echo "staged $package checksum mismatch" >&2; exit 1; }
}
LOCAL_ZIP_SHA=$(shasum -a 256 "$ZIP" | awk '{print $1}')
LOCAL_DMG_SHA=$(shasum -a 256 "$DMG" | awk '{print $1}')
LOCAL_FEED_SHA=$(shasum -a 256 dist/appcast.xml | awk '{print $1}')
verify_staged "$ZIP_BASENAME" "$LOCAL_ZIP_SHA"
verify_staged "$DMG_BASENAME" "$LOCAL_DMG_SHA"
verify_staged appcast.xml "$LOCAL_FEED_SHA"

# Prepare the cask locally while failures can still leave the public channels
# alone. Its GitHub asset becomes available when the draft is published.
TAP_DIR=$(mktemp -d "$PWD/dist/tap.XXXXXX")
git clone --quiet --depth 1 "https://github.com/conrader/homebrew-plainsay.git" "$TAP_DIR"
CASK="$TAP_DIR/Casks/plainsay.rb"
[ -f "$CASK" ] || { echo "tap has no Casks/plainsay.rb" >&2; exit 1; }
CASK_URL='  url "https://github.com/conrader/plainsay/releases/download/v#{version}/Plainsay-#{version}.dmg"'
sed -e "s|^  version .*|  version \"$VERSION\"|" \
	-e "s|^  sha256 .*|  sha256 \"$LOCAL_DMG_SHA\"|" \
	-e "s|^  url .*|$CASK_URL|" "$CASK" > "$CASK.next"
mv "$CASK.next" "$CASK"
grep -Fq "version \"$VERSION\"" "$CASK" || { echo "tap version was not rewritten" >&2; exit 1; }
grep -Fq "sha256 \"$LOCAL_DMG_SHA\"" "$CASK" || { echo "tap sha256 was not rewritten" >&2; exit 1; }
grep -Fxq "$CASK_URL" "$CASK" || {
	echo "tap URL must refer to the versioned GitHub DMG" >&2
	exit 1
}
git -C "$TAP_DIR" -c core.hooksPath=/dev/null -c commit.gpgSign=false commit --quiet -am "Plainsay $VERSION"

RELEASE_COMMIT=$(git rev-parse HEAD)
RELEASE_TARGET=(--target "$RELEASE_COMMIT")
check_release_candidate

# Back up the single-item appcast and installer before replacing either.
# A fresh private directory permits a retry after pre-publication failures.
BACKUP=$(ssh "${SSH_OPTIONS[@]+"${SSH_OPTIONS[@]}"}" "$HOST" "set -eu
umask 077
mkdir -p '$REMOTE_DIR/.release-backups'
backup=\$(mktemp -d '$REMOTE_DIR/.release-backups/v$VERSION.XXXXXX')
cp '$REMOTE_DIR/appcast.xml' \"\$backup/appcast.xml\"
cp '$REMOTE_DIR/releases/Plainsay-latest.dmg' \"\$backup/Plainsay-latest.dmg\"
printf '%s\\n' \"\$backup\"")
echo "    Previous appcast and installer: $BACKUP"

# A disconnect from here on can leave the channels at different versions.
# Install the shared marker atomically before either path mutates GitHub.
(
	umask 077
	printf 'tag=v%s\nbuild=%s\ncommit=%s\nsource=%s\nstage=%s\nbackup=%s\nzip_sha=%s\ndmg_sha=%s\nfeed_sha=%s\nlocal_checkout=%s\nlocal_tap=%s\n' \
		"$VERSION" "$BUILD" "$RELEASE_COMMIT" "${NIGHTLY_SOURCE:-$RELEASE_COMMIT}" "$REMOTE_STAGE" "$BACKUP" \
		"$LOCAL_ZIP_SHA" "$LOCAL_DMG_SHA" "$LOCAL_FEED_SHA" "$PWD" "$TAP_DIR" > "$LOCK/publish.pending"
	mv "$LOCK/publish.pending" "$PENDING"
)
if [ -n "$NIGHTLY_SOURCE" ]; then
	git push --no-follow-tags origin "$RELEASE_COMMIT:refs/tags/v$VERSION"
	RELEASE_TARGET=(--verify-tag)
fi

echo "==> Creating private GitHub Release draft v$VERSION"
gh release create "v$VERSION" "$ZIP" "$DMG" \
	--draft "${RELEASE_TARGET[@]}" --title "$VERSION" --notes "$BODY"

echo "==> Publishing GitHub Release v$VERSION"
gh release edit "v$VERSION" --draft=false --latest

echo "==> Activating update feed"
ssh "${SSH_OPTIONS[@]+"${SSH_OPTIONS[@]}"}" "$HOST" "set -eu
chmod a+r '$REMOTE_STAGE/$ZIP_BASENAME' '$REMOTE_STAGE/$DMG_BASENAME' '$REMOTE_STAGE/appcast.xml'
mv '$REMOTE_STAGE/$ZIP_BASENAME' '$REMOTE_DIR/releases/$ZIP_BASENAME'
mv '$REMOTE_STAGE/$DMG_BASENAME' '$REMOTE_DIR/releases/Plainsay-latest.dmg'
mv '$REMOTE_STAGE/appcast.xml' '$REMOTE_DIR/appcast.xml'
rmdir '$REMOTE_STAGE'"
REMOTE_STAGE=""
if [ "${PLAINSAY_MANAGED_DOCROOTS:-0}" != 1 ]; then
	ssh "$HOST" "sudo -n chown www-data:www-data '$REMOTE_DIR' '$REMOTE_DIR/releases' '$REMOTE_DIR/appcast.xml' '$REMOTE_DIR/releases/$ZIP_BASENAME' '$REMOTE_DIR/releases/Plainsay-latest.dmg'"
fi

./Scripts/deploy-site.sh

echo "==> Verifying public release channels"
PUBLISHED_DMG_SHA=$(curl -fsSL --max-time 60 "$FEED_URL/releases/Plainsay-latest.dmg" | shasum -a 256 | awk '{print $1}')
[ "$PUBLISHED_DMG_SHA" = "$LOCAL_DMG_SHA" ] || { echo "published DMG checksum mismatch" >&2; exit 1; }
PUBLISHED_ZIP_SHA=$(curl -fsSL --max-time 60 "$FEED_URL/releases/$ZIP_BASENAME" | shasum -a 256 | awk '{print $1}')
[ "$PUBLISHED_ZIP_SHA" = "$LOCAL_ZIP_SHA" ] || { echo "published zip checksum mismatch" >&2; exit 1; }
PUBLISHED_FEED_SHA=$(curl -fsSL --max-time 60 "$FEED_URL/appcast.xml" | shasum -a 256 | awk '{print $1}')
[ "$PUBLISHED_FEED_SHA" = "$LOCAL_FEED_SHA" ] || { echo "published appcast checksum mismatch" >&2; exit 1; }
gh release view "v$VERSION" --json isDraft --jq '.isDraft' | grep -Fqx false || {
	echo "GitHub Release v$VERSION is not public" >&2
	exit 1
}

echo "==> Updating the Homebrew tap"
git -C "$TAP_DIR" push --quiet origin HEAD:main

# Read back from GitHub rather than trusting the push: this is the command
# new users are told to run, and nothing else in this script would notice it
# pointing at the wrong build.
#
# Through the API, not raw.githubusercontent.com. Raw serves through a CDN
# with `cache-control: max-age=300`, so reading it immediately after pushing
# returns the *previous* cask for up to five minutes — which would fail this
# check, and with it the whole script, after the release had already shipped
# correctly. The contents API reflects the commit straight away.
PUBLISHED_CASK=$(gh api -H "Accept: application/vnd.github.raw" \
	"repos/conrader/homebrew-plainsay/contents/Casks/plainsay.rb")
grep -Fq "version \"$VERSION\"" <<<"$PUBLISHED_CASK" || {
	echo "published cask does not install $VERSION" >&2
	exit 1
}
grep -Fxq "$CASK_URL" <<<"$PUBLISHED_CASK" || {
	echo "published tap URL does not refer to the versioned GitHub DMG" >&2
	exit 1
}
grep -Fq "sha256 \"$LOCAL_DMG_SHA\"" <<<"$PUBLISHED_CASK" || {
	echo "published cask checksum does not match the shipped DMG" >&2
	exit 1
}

echo
echo "Published $VERSION"
echo "  feed:     $FEED_URL/appcast.xml"
echo "  package:  $FEED_URL/releases/Plainsay-$VERSION.zip"
echo "  download: $(gh repo view --json url --jq .url)/releases/latest"
echo "  brew:     brew install --cask conrader/plainsay/plainsay"

rm -f "$PENDING"
