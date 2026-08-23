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
set -euo pipefail

cd "$(dirname "$0")/.."

VERSION="${1:?usage: release.sh <version> [notes]}"
NOTES="${2:-}"
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

SIGN_UPDATE=".build/artifacts/sparkle/Sparkle/bin/sign_update"
[ -x "$SIGN_UPDATE" ] || { echo "sign_update missing — run 'swift build' first" >&2; exit 1; }
command -v gh >/dev/null || { echo "gh CLI missing — needed to publish the GitHub Release" >&2; exit 1; }
[ "$SIGN_IDENTITY" != "-" ] || {
	echo "release DMGs require a Developer ID identity, not ad-hoc signing" >&2
	exit 1
}
AVAILABLE_IDENTITIES=$(security find-identity -v -p codesigning)
grep -Fq "$SIGN_IDENTITY" <<<"$AVAILABLE_IDENTITIES" || {
	echo "Developer ID identity not available: $SIGN_IDENTITY" >&2
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
# The site deploy runs near the end, after the update feed is already live.
# Any reason it would refuse — a checkout behind origin, uncommitted docs —
# has to surface now, or a release aborts having shipped a new app while
# plainsay.app still describes the old one.
./Scripts/deploy-site.sh --check-only

if gh release view "v$VERSION" >/dev/null 2>&1; then
	echo "GitHub Release v$VERSION already exists — choose a new version; this script never overwrites a release" >&2
	exit 1
fi
if git ls-remote --exit-code --tags origin "refs/tags/v$VERSION" >/dev/null 2>&1; then
	echo "remote tag v$VERSION already exists without a matching release — inspect it before continuing" >&2
	exit 1
fi

# CFBundleVersion must increase monotonically; Sparkle compares it, not the
# marketing string. Derived from the version so they cannot drift apart.
BUILD=$(echo "$VERSION" | awk -F. '{ printf "%d", ($1*10000)+($2*100)+$3 }')
CURRENT_FEED_BUILD=$(curl -fsSL "$FEED_URL/appcast.xml" \
	| sed -n 's#.*<sparkle:version>\([0-9][0-9]*\)</sparkle:version>.*#\1#p' \
	| head -1)
[[ "$CURRENT_FEED_BUILD" =~ ^[0-9]+$ ]] || {
	echo "could not read the current Sparkle build from $FEED_URL/appcast.xml" >&2
	exit 1
}
[ "$BUILD" -gt "$CURRENT_FEED_BUILD" ] || {
	echo "build $BUILD must be newer than the published Sparkle build $CURRENT_FEED_BUILD" >&2
	exit 1
}

# Read rather than hardcoded a second time: this used to be a bare "15.0"
# literal here that silently stopped matching Info.plist's own
# LSMinimumSystemVersion the moment that changed (commit 1f54fe3 lowered the
# floor to Sonoma everywhere except this one line) — Sparkle filters every
# feed item whose minimumSystemVersion exceeds the running OS with no error
# surfaced anywhere, so the mismatch meant exactly the macOS 14 users that
# commit was meant to serve would silently never see another update again.
MIN_SYSTEM_VERSION=$(/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" Scripts/Info.plist)
PLIST_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Scripts/Info.plist)
PLIST_BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" Scripts/Info.plist)

[ "$PLIST_VERSION" = "$VERSION" ] || {
	echo "Info.plist is $PLIST_VERSION, not $VERSION — commit the version bump before releasing" >&2
	exit 1
}
[ "$PLIST_BUILD" = "$BUILD" ] || {
	echo "Info.plist build is $PLIST_BUILD, not $BUILD — commit the version bump before releasing" >&2
	exit 1
}

echo "==> Version $VERSION (build $BUILD)"

./Scripts/bundle.sh

# Notarise before packaging for release. Without a ticket, Gatekeeper blocks
# the app the first time anyone launches it from a download — which is every
# new user, and every user whose update arrives quarantined.
#
# The credentials live in a Keychain profile created once with:
#   xcrun notarytool store-credentials "plainsay-notary" \
#     --key <AuthKey_*.p8> --key-id <id> --issuer <uuid>
if [ "${NOTARIZE:-1}" = "1" ]; then
	echo "==> Notarising (a few minutes)"
	rm -rf dist && mkdir -p dist
	ditto -c -k --sequesterRsrc --keepParent build/Plainsay.app dist/notarize.zip
	xcrun notarytool submit dist/notarize.zip \
		--keychain-profile "plainsay-notary" --wait --timeout 20m
	xcrun stapler staple build/Plainsay.app
	# The ticket is what makes this offline-verifiable; without stapling, a
	# machine with no network sees an unnotarized app.
	xcrun stapler validate build/Plainsay.app
	spctl -a -vvv -t exec build/Plainsay.app
	rm -f dist/notarize.zip
else
	echo "==> Skipping notarisation (NOTARIZE=0) — do not ship this build"
fi

echo "==> Packaging"
mkdir -p dist
ZIP="dist/Plainsay-$VERSION.zip"
# ditto, not zip: it preserves the symlinks and extended attributes inside the
# framework, and a plain zip corrupts the signature on the way through.
ditto -c -k --sequesterRsrc --keepParent build/Plainsay.app "$ZIP"

LENGTH=$(stat -f%z "$ZIP")
echo "==> Signing $ZIP ($LENGTH bytes)"
SIGNATURE=$("$SIGN_UPDATE" "$ZIP" | sed -E 's/.*sparkle:edSignature="([^"]+)".*/\1/')
[ -n "$SIGNATURE" ] || { echo "signing produced nothing" >&2; exit 1; }

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
DMG="dist/Plainsay-$VERSION.dmg"
DMG_RW="dist/Plainsay-$VERSION-rw.dmg"
DMG_STAGING=$(mktemp -d)
DMG_MOUNT=""
cleanup_dmg_build() {
	rm -rf "$DMG_STAGING"
	if [ -n "$DMG_MOUNT" ]; then hdiutil detach "$DMG_MOUNT" -quiet 2>/dev/null || true; fi
}
trap cleanup_dmg_build EXIT

ditto build/Plainsay.app "$DMG_STAGING/Plainsay.app"
ln -s /Applications "$DMG_STAGING/Applications"
mkdir -p "$DMG_STAGING/.background"
swift Scripts/make-dmg-background.swift "$DMG_STAGING/.background" >/dev/null

rm -f "$DMG" "$DMG_RW"
# Sized generously above the staged contents — this read-write image is
# thrown away after the conversion below, so a few spare MB costs nothing.
DMG_SIZE_MB=$(( $(du -sm "$DMG_STAGING" | cut -f1) + 40 ))
hdiutil create -volname "Plainsay $VERSION" -srcfolder "$DMG_STAGING" -fs HFS+ \
	-format UDRW -size "${DMG_SIZE_MB}m" "$DMG_RW" >/dev/null

DMG_MOUNT=$(hdiutil attach "$DMG_RW" -readwrite -noverify -noautoopen | tail -1 | awk -F'\t' '{print $NF}')

osascript <<OSA
tell application "Finder"
	tell disk "Plainsay $VERSION"
		open
		set current view of container window to icon view
		set toolbar visible of container window to false
		set statusbar visible of container window to false
		set the bounds of container window to {400, 100, 1060, 500}
		set theViewOptions to icon view options of container window
		set arrangement of theViewOptions to not arranged
		set icon size of theViewOptions to 128
		set background picture of theViewOptions to file ".background:background.png"
		set position of item "Plainsay.app" of container window to {180, 195}
		set position of item "Applications" of container window to {480, 195}
		select {}
		close
		open
		update without registering applications
		delay 1
	end tell
end tell
OSA

sync
hdiutil detach "$DMG_MOUNT" -quiet
DMG_MOUNT=""

hdiutil convert "$DMG_RW" -format UDZO -ov -o "$DMG" >/dev/null
rm -f "$DMG_RW"
rm -rf "$DMG_STAGING"
trap - EXIT

if [ "${NOTARIZE:-1}" = "1" ]; then
	# The app inside is already signed and stapled, but Gatekeeper assesses the
	# DMG container independently on first mount. Sign the container before
	# notarizing it; a ticket alone is not a usable code signature and `spctl`
	# will reject an unsigned DMG even when stapler can validate its ticket.
	codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG"
	codesign --verify --verbose=2 "$DMG"
	xcrun notarytool submit "$DMG" --keychain-profile "plainsay-notary" --wait --timeout 20m >/dev/null
	xcrun stapler staple "$DMG" >/dev/null
	xcrun stapler validate "$DMG" >/dev/null
	spctl -a -vvv -t open --context context:primary-signature "$DMG"
fi

PUBDATE=$(date -u "+%a, %d %b %Y %H:%M:%S +0000")

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
ssh "$HOST" "sudo mkdir -p '$REMOTE_DIR/releases' && sudo chown -R \$(whoami) '$REMOTE_DIR'"
REMOTE_STAGE=$(ssh "$HOST" "mktemp -d '$REMOTE_DIR/.release-stage.XXXXXX'")
case "$REMOTE_STAGE" in
	"$REMOTE_DIR"/.release-stage.*) ;;
	*) echo "unexpected remote staging path: $REMOTE_STAGE" >&2; exit 1 ;;
esac

ZIP_BASENAME=$(basename "$ZIP")
DMG_BASENAME=$(basename "$DMG")
scp -q "$ZIP" "$HOST:$REMOTE_STAGE/$ZIP_BASENAME"
scp -q "$DMG" "$HOST:$REMOTE_STAGE/$DMG_BASENAME"
scp -q dist/appcast.xml "$HOST:$REMOTE_STAGE/appcast.xml"

LOCAL_ZIP_SHA=$(shasum -a 256 "$ZIP" | awk '{print $1}')
LOCAL_DMG_SHA=$(shasum -a 256 "$DMG" | awk '{print $1}')
REMOTE_ZIP_SHA=$(ssh "$HOST" "sha256sum '$REMOTE_STAGE/$ZIP_BASENAME'" | awk '{print $1}')
REMOTE_DMG_SHA=$(ssh "$HOST" "sha256sum '$REMOTE_STAGE/$DMG_BASENAME'" | awk '{print $1}')
[ "$REMOTE_ZIP_SHA" = "$LOCAL_ZIP_SHA" ] || { echo "staged zip checksum mismatch" >&2; exit 1; }
[ "$REMOTE_DMG_SHA" = "$LOCAL_DMG_SHA" ] || { echo "staged DMG checksum mismatch" >&2; exit 1; }

echo "==> Creating private GitHub Release draft v$VERSION"
RELEASE_COMMIT=$(git rev-parse HEAD)
gh release create "v$VERSION" "$ZIP" "$DMG" \
	--draft \
	--target "$RELEASE_COMMIT" \
	--title "$VERSION" \
	--notes "$BODY"

# At this point the signed assets exist in both destinations, but no public
# download has moved. Publishing is one GitHub API operation, followed by
# same-filesystem renames for the update feed.
echo "==> Publishing GitHub Release v$VERSION"
gh release edit "v$VERSION" --draft=false --latest

echo "==> Activating update feed"
ssh "$HOST" "set -e
mv '$REMOTE_STAGE/$ZIP_BASENAME' '$REMOTE_DIR/releases/$ZIP_BASENAME'
mv '$REMOTE_STAGE/$DMG_BASENAME' '$REMOTE_DIR/releases/Plainsay-latest.dmg'
mv '$REMOTE_STAGE/appcast.xml' '$REMOTE_DIR/appcast.xml'
rmdir '$REMOTE_STAGE'
sudo chown -R www-data:www-data '$REMOTE_DIR'
sudo chmod -R a+rX '$REMOTE_DIR'"

# The marketing site is a separate docroot with its own deploy. Run it only
# after the release, stable download, and update feed identify the same build.
./Scripts/deploy-site.sh

echo "==> Verifying public release channels"
PUBLISHED_DMG_SHA=$(curl -fsSL "$FEED_URL/releases/Plainsay-latest.dmg" | shasum -a 256 | awk '{print $1}')
[ "$PUBLISHED_DMG_SHA" = "$LOCAL_DMG_SHA" ] || { echo "published DMG checksum mismatch" >&2; exit 1; }
curl -fsSL "$FEED_URL/appcast.xml" | grep -Fq "<sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>" || {
	echo "published appcast does not advertise $VERSION" >&2
	exit 1
}
gh release view "v$VERSION" --json isDraft --jq '.isDraft' | grep -Fqx false || {
	echo "GitHub Release v$VERSION is not public" >&2
	exit 1
}

# The tap is the install path the README, the website, and every list
# submission tell people to use — and nothing here ever updated it, so it sat
# on whatever release last touched it by hand. A stale cask is not a broken
# one: the old asset still exists and its checksum still matches, so brew
# succeeds and quietly installs an old build. That is worse than failing,
# because the first run someone gets is the version whose bugs this release
# fixed. Last in the script for the same reason the site deploy is late — the
# cask points at a GitHub asset that has to exist and be public first.
echo "==> Updating the Homebrew tap"
TAP_DIR=$(mktemp -d)
trap 'rm -rf "$TAP_DIR"' EXIT
git clone --quiet --depth 1 "https://github.com/conrader/homebrew-plainsay.git" "$TAP_DIR"
CASK="$TAP_DIR/Casks/plainsay.rb"
[ -f "$CASK" ] || { echo "tap has no Casks/plainsay.rb — cannot update the install path" >&2; exit 1; }
/usr/bin/sed -i '' \
	-e "s|^  version \".*\"|  version \"$VERSION\"|" \
	-e "s|^  sha256 \".*\"|  sha256 \"$LOCAL_DMG_SHA\"|" \
	"$CASK"
# Checked rather than assumed: a sed that matches nothing exits 0, which would
# push an unchanged cask and report success.
grep -Fq "version \"$VERSION\"" "$CASK" || { echo "tap version was not rewritten" >&2; exit 1; }
grep -Fq "sha256 \"$LOCAL_DMG_SHA\"" "$CASK" || { echo "tap sha256 was not rewritten" >&2; exit 1; }
if [ -n "$(git -C "$TAP_DIR" status --porcelain)" ]; then
	git -C "$TAP_DIR" commit --quiet -am "Plainsay $VERSION"
	git -C "$TAP_DIR" push --quiet origin HEAD:main
fi
rm -rf "$TAP_DIR"
trap - EXIT

# Read back from GitHub rather than trusting the push: this is the command
# new users are told to run, and nothing else in this script would notice it
# pointing at the wrong build.
PUBLISHED_CASK=$(curl -fsSL "https://raw.githubusercontent.com/conrader/homebrew-plainsay/main/Casks/plainsay.rb")
grep -Fq "version \"$VERSION\"" <<<"$PUBLISHED_CASK" || {
	echo "published cask does not install $VERSION" >&2
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
