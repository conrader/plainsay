#!/bin/bash
# Cuts a release and publishes it to the update feed.
#
#   ./Scripts/release.sh 0.1.1 "What changed in this build"
#
# Builds, zips, signs the zip with the Sparkle EdDSA key from the Keychain,
# regenerates the appcast, and uploads both to the update host. The private
# signing key never leaves this Mac — the server only ever sees signatures.
set -euo pipefail

cd "$(dirname "$0")/.."

VERSION="${1:?usage: release.sh <version> [notes]}"
NOTES="${2:-}"
HOST="${HOST:-codex-server}"
REMOTE_DIR=/var/www/plainsay-updates
FEED_URL="https://api.plainsay.app"

SIGN_UPDATE=".build/artifacts/sparkle/Sparkle/bin/sign_update"
[ -x "$SIGN_UPDATE" ] || { echo "sign_update missing — run 'swift build' first" >&2; exit 1; }

# CFBundleVersion must increase monotonically; Sparkle compares it, not the
# marketing string. Derived from the version so they cannot drift apart.
BUILD=$(echo "$VERSION" | awk -F. '{ printf "%d", ($1*10000)+($2*100)+$3 }')

echo "==> Version $VERSION (build $BUILD)"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" Scripts/Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" Scripts/Info.plist

./Scripts/bundle.sh

echo "==> Packaging"
rm -rf dist && mkdir -p dist
ZIP="dist/Plainsay-$VERSION.zip"
# ditto, not zip: it preserves the symlinks and extended attributes inside the
# framework, and a plain zip corrupts the signature on the way through.
ditto -c -k --sequesterRsrc --keepParent build/Plainsay.app "$ZIP"

LENGTH=$(stat -f%z "$ZIP")
echo "==> Signing $ZIP ($LENGTH bytes)"
SIGNATURE=$("$SIGN_UPDATE" "$ZIP" | sed -E 's/.*sparkle:edSignature="([^"]+)".*/\1/')
[ -n "$SIGNATURE" ] || { echo "signing produced nothing" >&2; exit 1; }

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

echo
echo "Published $VERSION"
echo "  feed:    $FEED_URL/appcast.xml"
echo "  package: $FEED_URL/releases/Plainsay-$VERSION.zip"
