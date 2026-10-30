#!/usr/bin/env bash
# Builds PopMac.app in ./build.
#
# A stable signature keeps the Accessibility permission across rebuilds.
# The script uses SIGN_IDENTITY, or else the first "Apple Development"
# certificate in the keychain. Without one it signs ad-hoc, and macOS asks
# for the permission again after every build. A Developer ID signature also
# gets a secure timestamp, which notarization requires.
#
# VERSION and BUILD set the version. By default, they come from the latest
# release tag and the number of commits, or else from Resources/Info.plist.
set -euo pipefail

cd "$(dirname "$0")/.."
CONFIG="${CONFIG:-release}"
APP="build/PopMac.app"
# Extra flags for swift build, for example --disable-sandbox inside Homebrew.
read -r -a FLAGS <<< "${SWIFT_BUILD_FLAGS:-}"

swift build ${FLAGS[@]+"${FLAGS[@]}"} -c "$CONFIG" --product PopMac
BIN="$(swift build ${FLAGS[@]+"${FLAGS[@]}"} -c "$CONFIG" --show-bin-path)/PopMac"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/PopMac"
# SwiftPM records the deployment target as the SDK version. macOS then runs the
# app in compatibility mode, without the current design (Liquid Glass).
SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"
MIN_VERSION="$(otool -l "$APP/Contents/MacOS/PopMac" | awk '/LC_BUILD_VERSION/ { found = 1 } found && $1 == "minos" { print $2; exit }')"
vtool -set-build-version macos "$MIN_VERSION" "$SDK_VERSION" -replace -output "$APP/Contents/MacOS/PopMac" "$APP/Contents/MacOS/PopMac"
cp Resources/Info.plist "$APP/Contents/Info.plist"
VERSION="${VERSION:-$(git describe --tags --abbrev=0 --match 'v*' 2>/dev/null | sed 's/^v//' || true)}"
BUILD="${BUILD:-$(git rev-list --count HEAD 2>/dev/null || true)}"
if [[ -n "$VERSION" ]]; then
    plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
fi
if [[ -n "$BUILD" ]]; then
    plutil -replace CFBundleVersion -string "$BUILD" "$APP/Contents/Info.plist"
fi
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

IDENTITY="${SIGN_IDENTITY:-$(security find-identity -p codesigning -v 2>/dev/null | awk '/"Apple Development/ { print $2; exit }')}"
SIGN_FLAGS=(--force --deep --options runtime)
# IDENTITY is a name or a SHA-1 hash, so the keychain tells whether it is a Developer ID.
if [[ -n "$IDENTITY" ]] && security find-identity -v -p codesigning 2> /dev/null | grep -F -- "$IDENTITY" | grep -q '"Developer ID Application'; then
    SIGN_FLAGS+=(--timestamp)
fi
codesign "${SIGN_FLAGS[@]}" --sign "${IDENTITY:--}" "$APP"
echo "Signed with: ${IDENTITY:-ad-hoc}"
echo "Built $APP"
