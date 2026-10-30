#!/usr/bin/env bash
# Prints the version after a release tag, such as 0.6.0 after v0.5.3 for a minor bump.
#
# Usage: next-version.sh <last tag, or nothing for the first release> <major|minor|patch>
set -euo pipefail

last="${1:-v0.0.0}"
if [[ ! "$last" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Not a release tag: $last" >&2
    exit 2
fi
IFS=. read -r major minor patch <<< "${last#v}"
case "$2" in
    major) echo "$((major + 1)).0.0" ;;
    minor) echo "$major.$((minor + 1)).0" ;;
    patch) echo "$major.$minor.$((patch + 1))" ;;
    *)
        echo "Not a version part: $2" >&2
        exit 2
        ;;
esac
