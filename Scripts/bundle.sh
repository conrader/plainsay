#!/bin/bash
# Builds Plainsay.app.
#
# The bundle is not optional: macOS will not grant microphone, accessibility, or
# input monitoring access to a bare executable, so `swift run` produces an app
# that cannot do anything.
#
# Signing with a real identity (rather than ad-hoc) matters too — TCC keys its
# grants on the signature, so an ad-hoc build asks for all three permissions
# again every time you rebuild.
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
APP="build/Plainsay.app"
# Override with SIGN_IDENTITY=- for an unsigned ad-hoc build.
SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application: Konrad Sierzputowski (FQ5759XB2L)}"

echo "==> Building ($CONFIG)"
swift build -c "$CONFIG" --product PlainsayApp

BINARY="$(swift build -c "$CONFIG" --product PlainsayApp --show-bin-path)/PlainsayApp"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/PlainsayApp"
cp Scripts/Info.plist "$APP/Contents/Info.plist"

echo "==> Signing as: $SIGN_IDENTITY"
codesign --force \
	--sign "$SIGN_IDENTITY" \
	--identifier com.plainsay.dictation \
	--options runtime \
	--entitlements Scripts/Plainsay.entitlements \
	--timestamp=none \
	"$APP"

codesign --verify --verbose=1 "$APP"

echo
echo "Built $APP"
echo "Run it with:  open $APP"
