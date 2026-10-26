#!/usr/bin/env bash
# Installs the Homebrew release as "Pop Mac Prod" next to a development build.
#
# The copy gets its own name and bundle id, so both can be installed side by
# side. Only one can manage windows: starting a copy quits the other one.
# Run this again after `brew upgrade pop-mac`.
set -euo pipefail

SOURCE="$(brew --prefix)/opt/pop-mac/PopMac.app"
if [[ ! -d "$SOURCE" ]]; then
    brew install krystxf/tap/pop-mac
fi

DEST="$HOME/Applications/Pop Mac Prod.app"
mkdir -p "$HOME/Applications"
rm -rf "$DEST"
cp -R "$SOURCE" "$DEST"
chmod -R u+w "$DEST"

PLIST="$DEST/Contents/Info.plist"
plutil -replace CFBundleIdentifier -string dev.krystof.popmac.prod "$PLIST"
plutil -replace CFBundleName -string "Pop Mac Prod" "$PLIST"
plutil -replace CFBundleDisplayName -string "Pop Mac Prod" "$PLIST"

codesign --force --sign - "$DEST"
echo "Installed $DEST ($("$DEST/Contents/MacOS/PopMac" --version))"
