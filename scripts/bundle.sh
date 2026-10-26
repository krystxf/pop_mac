#!/usr/bin/env bash
# Builds PopMac.app in ./build.
#
# Set SIGN_IDENTITY to a certificate name (see `security find-identity -p codesigning`)
# to keep the Accessibility permission across rebuilds. The default ad-hoc
# signature changes on every build, so macOS asks for the permission again.
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

codesign --force --deep --options runtime --sign "${SIGN_IDENTITY:--}" "$APP"
echo "Built $APP"
