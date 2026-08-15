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

# Sparkle ships as a framework and SwiftPM does not embed it, so the binary
# links against something the bundle does not contain. Copy it in and point
# the loader at it, or the app dies at launch with a dyld error.
SPARKLE_SRC="$(swift build -c "$CONFIG" --show-bin-path)/Sparkle.framework"
if [ -d "$SPARKLE_SRC" ]; then
	echo "==> Embedding Sparkle"
	mkdir -p "$APP/Contents/Frameworks"
	rsync -a --delete "$SPARKLE_SRC" "$APP/Contents/Frameworks/"
	install_name_tool -add_rpath "@executable_path/../Frameworks" \
		"$APP/Contents/MacOS/PlainsayApp" 2>/dev/null || true
else
	echo "!! Sparkle.framework not found at $SPARKLE_SRC" >&2
	exit 1
fi

# Inside out: the framework and its helpers must each be signed before the
# outer bundle, or the outer signature covers something that then changes.
echo "==> Signing as: $SIGN_IDENTITY"
for inner in \
	"$APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices"/*.xpc \
	"$APP/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate" \
	"$APP/Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app" \
	"$APP/Contents/Frameworks/Sparkle.framework"
do
	[ -e "$inner" ] || continue
	codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp=none "$inner" >/dev/null
done

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

# Installing matters more than it looks: TCC grants follow the bundle, and a
# stale copy in /Applications keeps running the old code while you test the
# new one — which is a genuinely confusing hour to spend.
if [ "${INSTALL:-0}" = "1" ]; then
	echo "==> Installing to /Applications"
	pkill -f "Plainsay.app" 2>/dev/null || true
	sleep 1
	rm -rf /Applications/Plainsay.app
	cp -R "$APP" /Applications/
	echo "Installed /Applications/Plainsay.app"
	echo "Run it with:  open /Applications/Plainsay.app"
else
	echo "Run it with:  open $APP"
	echo "Install with: INSTALL=1 ./Scripts/bundle.sh"
fi
