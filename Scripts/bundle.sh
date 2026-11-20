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
BUNDLE_DIR="${PLAINSAY_BUNDLE_DIR:-build}"
SWIFTPM_SCRATCH="${PLAINSAY_SWIFTPM_SCRATCH:-.build}"
BUILT_APP="$BUNDLE_DIR/Plainsay.app"
BUILD_STAGE=""
INSTALL_STAGE=""
cleanup() {
	if [ -n "$BUILD_STAGE" ]; then rm -rf -- "$BUILD_STAGE"; fi
	if [ -n "$INSTALL_STAGE" ]; then rm -rf -- "$INSTALL_STAGE"; fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
# Override with SIGN_IDENTITY=- for an unsigned ad-hoc build.
SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application: Konrad Sierzputowski (FQ5759XB2L)}"

echo "==> Building ($CONFIG)"
swift build --scratch-path "$SWIFTPM_SCRATCH" -c "$CONFIG" --product PlainsayApp

BIN_DIR="$(swift build --scratch-path "$SWIFTPM_SCRATCH" -c "$CONFIG" --product PlainsayApp --show-bin-path)"
BINARY="$BIN_DIR/PlainsayApp"

echo "==> Assembling $BUILT_APP"
mkdir -p "$BUNDLE_DIR"
BUILD_STAGE=$(mktemp -d "$BUNDLE_DIR/.plainsay-build.XXXXXX")
APP="$BUILD_STAGE/Plainsay.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/PlainsayApp"
cp Scripts/Info.plist "$APP/Contents/Info.plist"
cp Scripts/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# `swift build` copies each target's .xcstrings into its own resource bundle
# as-is — unlike Xcode, the SwiftPM command-line build does not compile it
# into per-language .strings tables. Do that here instead, straight into
# Contents/Resources/<lang>.lproj/, which is also what makes plain SwiftUI
# `Text("literal")` calls pick up a translation via Bundle.main with no
# further wiring (see Sources/PlainsayCore/Localization.swift). Both
# catalogs merge into the same lproj folders without colliding: they use
# different table names (Localizable vs CoreLocalizable), so this is a
# real merge, not an overwrite.
echo "==> Compiling String Catalogs"
STRINGS_TMP="$BUILD_STAGE/strings"
mkdir "$STRINGS_TMP"
xcrun xcstringstool compile Sources/PlainsayApp/Resources/Localizable.xcstrings --output-directory "$STRINGS_TMP/app"
xcrun xcstringstool compile Sources/PlainsayCore/Resources/CoreLocalizable.xcstrings --output-directory "$STRINGS_TMP/core"
for lproj in "$STRINGS_TMP"/app/*.lproj "$STRINGS_TMP"/core/*.lproj; do
	[ -d "$lproj" ] || continue
	name=$(basename "$lproj")
	mkdir -p "$APP/Contents/Resources/$name"
	cp -R "$lproj/." "$APP/Contents/Resources/$name/"
done
rm -rf "$STRINGS_TMP"
cp LICENSE "$APP/Contents/Resources/Plainsay-MIT.txt"
cp THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/"
mkdir -p "$APP/Contents/Resources/ThirdPartyLicenses"
cp "$SWIFTPM_SCRATCH"/checkouts/FluidAudio/LICENSE \
	"$APP/Contents/Resources/ThirdPartyLicenses/FluidAudio-Apache-2.0.txt"
cp "$SWIFTPM_SCRATCH"/checkouts/WhisperKit/LICENSE \
	"$APP/Contents/Resources/ThirdPartyLicenses/WhisperKit-MIT.txt"
cp "$SWIFTPM_SCRATCH"/checkouts/WhisperKit/NOTICES \
	"$APP/Contents/Resources/ThirdPartyLicenses/WhisperKit-NOTICES.txt"
cp "$SWIFTPM_SCRATCH"/checkouts/Sparkle/LICENSE \
	"$APP/Contents/Resources/ThirdPartyLicenses/Sparkle-LICENSE.txt"

# Sparkle ships as a framework and SwiftPM does not embed it, so the binary
# links against something the bundle does not contain. Copy it in and point
# the loader at it, or the app dies at launch with a dyld error.
SPARKLE_SRC="$BIN_DIR/Sparkle.framework"
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
	Scripts/release-timeout.pl 120 'Sparkle component signing' \
		codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp "$inner" >/dev/null
done

Scripts/release-timeout.pl 120 'App signing' codesign --force \
	--sign "$SIGN_IDENTITY" \
	--identifier com.plainsay.dictation \
	--options runtime \
	--entitlements Scripts/Plainsay.entitlements \
	--timestamp \
	"$APP"

Scripts/release-timeout.pl 120 'App signature verification' codesign --verify --verbose=1 "$APP"

swift Scripts/swap-app.swift "$APP" "$BUILT_APP"
echo
echo "Built $BUILT_APP"

if [ "${INSTALL:-0}" = "1" ]; then
	echo "==> Installing to /Applications"
	INSTALL_STAGE=$(mktemp -d /Applications/.plainsay-install.XXXXXX)
	CANDIDATE="$INSTALL_STAGE/Plainsay.app"
	ditto "$BUILT_APP" "$CANDIDATE"
	Scripts/release-timeout.pl 120 'Installed app signature verification' \
		codesign --verify --deep --strict "$CANDIDATE"
	swift Scripts/swap-app.swift "$CANDIDATE" /Applications/Plainsay.app
	echo "Installed /Applications/Plainsay.app"
	echo "Run it with:  open /Applications/Plainsay.app"
else
	echo "Run it with:  open $BUILT_APP"
	echo "Install with: INSTALL=1 ./Scripts/bundle.sh"
fi
