#!/usr/bin/env bash
# Prints the "Release notes" section of a pull request description, without its
# comments, empty items, and blank lines. Prints nothing if the section is empty.
#
# Usage: release-notes.sh < <pull request description>
set -euo pipefail

# Perl removes the comments, which can span lines or share a line with a note.
tr -d '\r' \
    | awk '/^## Release notes/ { take = 1; next } /^## / { take = 0 } take' \
    | perl -0777 -pe 's/<!--.*?-->//gs' \
    | sed 's/[[:space:]]*$//' \
    | sed '/^-$/d' \
    | sed '/^$/d'
