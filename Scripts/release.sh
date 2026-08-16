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

SIGN_UPDATE=".build/artifacts/sparkle/Sparkle/bin/sign_update"
[ -x "$SIGN_UPDATE" ] || { echo "sign_update missing — run 'swift build' first" >&2; exit 1; }
command -v gh >/dev/null || { echo "gh CLI missing — needed to publish the GitHub Release" >&2; exit 1; }

# CFBundleVersion must increase monotonically; Sparkle compares it, not the
# marketing string. Derived from the version so they cannot drift apart.
BUILD=$(echo "$VERSION" | awk -F. '{ printf "%d", ($1*10000)+($2*100)+$3 }')

echo "==> Version $VERSION (build $BUILD)"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" Scripts/Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" Scripts/Info.plist

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
echo "==> Building DMG"
DMG="dist/Plainsay-$VERSION.dmg"
DMG_STAGING=$(mktemp -d)
trap 'rm -rf "$DMG_STAGING"' EXIT
ditto build/Plainsay.app "$DMG_STAGING/Plainsay.app"
ln -s /Applications "$DMG_STAGING/Applications"
rm -f "$DMG"
hdiutil create -volname "Plainsay $VERSION" -srcfolder "$DMG_STAGING" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$DMG_STAGING"

if [ "${NOTARIZE:-1}" = "1" ]; then
	# The app inside is already stapled, but Gatekeeper also checks the DMG
	# container itself on first mount — an unnotarized DMG still prompts a
	# warning even though the app inside would pass on its own.
	xcrun notarytool submit "$DMG" --keychain-profile "plainsay-notary" --wait --timeout 20m >/dev/null
	xcrun stapler staple "$DMG" >/dev/null
	xcrun stapler validate "$DMG" >/dev/null
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
      <sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>
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

echo "==> Publishing to $HOST"
ssh "$HOST" "sudo mkdir -p $REMOTE_DIR/releases && sudo chown -R \$(whoami) $REMOTE_DIR"
scp -q "$ZIP" "$HOST:$REMOTE_DIR/releases/"
scp -q dist/appcast.xml "$HOST:$REMOTE_DIR/appcast.xml"
ssh "$HOST" "sudo chown -R www-data:www-data $REMOTE_DIR && sudo chmod -R a+rX $REMOTE_DIR"

echo "==> Publishing GitHub Release v$VERSION"
# Plain text for the release body: GitHub's own markdown renderer is what
# displays it, not Sparkle's CDATA-wrapped HTML — reusing the HTML string
# as-is would show literal <p> tags on the Releases page. Closing tags become
# a blank line so multi-paragraph notes still read as separate paragraphs
# instead of running together into one sentence.
BODY=$(printf '%s' "${NOTES:-Bug fixes and improvements.}" | sed -E 's#</p>#\n\n#g; s#<p>##g')
if gh release view "v$VERSION" >/dev/null 2>&1; then
	echo "    v$VERSION already exists on GitHub — skipping (release.sh does not overwrite a tag)"
else
	gh release create "v$VERSION" "$ZIP" "$DMG" \
		--title "$VERSION" \
		--notes "$BODY"
fi

echo
echo "Published $VERSION"
echo "  feed:     $FEED_URL/appcast.xml"
echo "  package:  $FEED_URL/releases/Plainsay-$VERSION.zip"
echo "  download: $(gh repo view --json url --jq .url)/releases/latest"
