#!/usr/bin/env bash
# Prints the part of the version that a merged pull request bumps: major, minor,
# patch, or none.
#
# Usage: release-bump.sh "<labels, separated by spaces>" < <changed files, one per line>
#
# The labels release:major, release:minor, and release:patch pick the part, and
# no-release picks none. Without a label, a change to code is a patch, and a
# change to docs or workflows only is none. More than one release label is an error.
set -euo pipefail

labels=" $1 "
count=0
bump=""
for part in major minor patch; do
    if [[ "$labels" == *" release:$part "* ]]; then
        count=$((count + 1))
        bump="${bump:-$part}"
    fi
done
if [[ "$labels" == *" no-release "* ]]; then
    count=$((count + 1))
    bump="${bump:-none}"
fi
if ((count > 1)); then
    echo "Use only one of the labels release:major, release:minor, release:patch, and no-release." >&2
    exit 2
fi

if [[ -z "$bump" ]]; then
    if grep -qvE '\.md$|^docs/|^\.github/'; then
        bump="patch"
    else
        bump="none"
    fi
fi
echo "$bump"
