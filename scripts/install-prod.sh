#!/usr/bin/env bash
# Installs the latest release as "Pop Mac Prod" next to a development build.
#
# The copy gets its own name and bundle id, so both can be installed side by
# side. Only one can manage windows: starting a copy quits the other one.
# Run this again after each release.
#
# Renaming the copy breaks its signature, so the script signs it again with
# SIGN_IDENTITY, or else the first "Developer ID Application" certificate in
# the keychain. A Developer ID signature keeps the Accessibility permission
# across updates. Without one it signs ad-hoc, and macOS asks again each time.
set -euo pipefail

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
curl -fsSL -o "$TMP/PopMac.zip" https://github.com/krystxf/pop_mac/releases/latest/download/PopMac.zip
ditto -x -k "$TMP/PopMac.zip" "$TMP"

DEST="$HOME/Applications/Pop Mac Prod.app"
mkdir -p "$HOME/Applications"
rm -rf "$DEST"
ditto "$TMP/PopMac.app" "$DEST"

PLIST="$DEST/Contents/Info.plist"
plutil -replace CFBundleIdentifier -string dev.krystof.popmac.prod "$PLIST"
plutil -replace CFBundleName -string "Pop Mac Prod" "$PLIST"
plutil -replace CFBundleDisplayName -string "Pop Mac Prod" "$PLIST"

IDENTITY="${SIGN_IDENTITY:-$(security find-identity -p codesigning -v 2>/dev/null | awk '/"Developer ID Application/ { print $2; exit }')}"
codesign --force --deep --options runtime --sign "${IDENTITY:--}" "$DEST"
echo "Signed with: ${IDENTITY:-ad-hoc}"
echo "Installed $DEST ($("$DEST/Contents/MacOS/PopMac" --version))"
