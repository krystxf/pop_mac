#!/usr/bin/env bash
# Checks that every place names the same oldest supported macOS: Package.swift,
# Resources/Info.plist, the built app, and the Homebrew cask. Run it after
# scripts/bundle.sh.
set -euo pipefail
cd "$(dirname "$0")/.."

package="$(sed -nE 's/.*\.macOS\(\.v([0-9]+)\).*/\1/p' Package.swift)"
plist="$(plutil -extract LSMinimumSystemVersion raw Resources/Info.plist)"
binary="$(otool -l build/PopMac.app/Contents/MacOS/PopMac | awk '/LC_BUILD_VERSION/ { found = 1 } found && $1 == "minos" { print $2; exit }')"
cask_name="$(sed -nE 's/.*depends_on macos: :([a-z_]+).*/\1/p' packaging/homebrew/pop-mac.rb)"
case "$cask_name" in
    ventura) cask=13 ;;
    sonoma) cask=14 ;;
    sequoia) cask=15 ;;
    tahoe) cask=26 ;;
    *) cask="unknown name '$cask_name'" ;;
esac

echo "Package.swift: $package, Info.plist: $plist, app: $binary, cask: $cask ($cask_name)"
for version in "${plist%%.*}" "${binary%%.*}" "$cask"; do
    if [[ "$version" != "$package" ]]; then
        echo "The oldest supported macOS differs between these places." >&2
        exit 1
    fi
done
