#!/usr/bin/env bash
# Builds PopMac.app in ./build.
#
# A stable signature keeps the Accessibility permission across rebuilds.
# The script uses SIGN_IDENTITY, or else the first "Apple Development"
# certificate in the keychain. Without one it signs ad-hoc, and macOS asks
# for the permission again after every build.
set -euo pipefail

cd "$(dirname "$0")/.."
CONFIG="${CONFIG:-release}"
APP="build/PopMac.app"

swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/PopMac"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/PopMac"
cp Resources/Info.plist "$APP/Contents/Info.plist"

IDENTITY="${SIGN_IDENTITY:-$(security find-identity -p codesigning -v 2>/dev/null | awk '/"Apple Development/ { print $2; exit }')}"
codesign --force --deep --options runtime --sign "${IDENTITY:--}" "$APP"
echo "Signed with: ${IDENTITY:-ad-hoc}"
echo "Built $APP"
