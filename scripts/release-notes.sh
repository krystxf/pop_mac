#!/usr/bin/env bash
# Prints the "Release notes" section of a pull request description, without its
# comments, empty items, and blank lines. Prints nothing if the section is empty.
#
# Usage: release-notes.sh < <pull request description>
set -euo pipefail

tr -d '\r' \
    | awk '/^## Release notes/ { take = 1; next } /^## / { take = 0 } take' \
    | sed '/<!--/,/-->/d' \
    | sed '/^-[[:space:]]*$/d' \
    | sed '/^[[:space:]]*$/d'
