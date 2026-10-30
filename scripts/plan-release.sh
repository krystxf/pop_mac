#!/usr/bin/env bash
# Plans the release of every pull request merged into main since the last release tag.
#
# Prints the version of the release, or nothing when none of those pull requests
# makes one. Writes the release notes to the file given as the first argument.
# Run it in a clone of main with its tags. It needs GITHUB_REPOSITORY and gh.
#
# Releasing everything since the last tag, not only the latest pull request, means
# that a run that GitHub cancels or that fails loses nothing: the next run includes it.
set -euo pipefail

notes_file="$1"
here="$(cd "$(dirname "$0")" && pwd)"
repo="$GITHUB_REPOSITORY"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

last="$(git tag --list 'v*' --sort=-v:refname | head -n 1)"
if [[ -n "$last" ]]; then
    git rev-list --first-parent "$last..HEAD" > "$tmp/commits"
else
    git rev-list --first-parent HEAD > "$tmp/commits"
fi

: > "$tmp/prs"
# The loops read from file descriptor 3, so that gh cannot take their input.
while read -r sha <&3; do
    gh api "repos/$repo/commits/$sha/pulls" \
        --jq '.[] | select(.merged_at != null and .base.ref == "main") | .number' >> "$tmp/prs"
done 3< "$tmp/commits"
sort -n -u "$tmp/prs" > "$tmp/unique"

rank() {
    case "$1" in
        major) echo 3 ;;
        minor) echo 2 ;;
        patch) echo 1 ;;
        *) echo 0 ;;
    esac
}

best="none"
: > "$tmp/changes"
: > "$tmp/numbers"
while read -r pr <&3; do
    labels="$(gh pr view "$pr" --repo "$repo" --json labels --jq '[.labels[].name] | join(" ")')"
    # The REST API pages through every file. gh pr view returns only the first 100.
    gh api --paginate "repos/$repo/pulls/$pr/files" --jq '.[].filename' > "$tmp/files"
    bump="$("$here/release-bump.sh" "$labels" < "$tmp/files")"
    echo "Pull request #$pr: $bump" >&2
    if [[ "$bump" == none ]]; then
        continue
    fi
    if (($(rank "$bump") > $(rank "$best"))); then
        best="$bump"
    fi
    gh pr view "$pr" --repo "$repo" --json body --jq .body > "$tmp/body"
    notes="$("$here/release-notes.sh" < "$tmp/body")"
    if [[ -z "$notes" ]]; then
        notes="- $(gh pr view "$pr" --repo "$repo" --json title --jq .title)"
    fi
    printf '%s\n' "$notes" >> "$tmp/changes"
    echo "#$pr" >> "$tmp/numbers"
done 3< "$tmp/unique"

if [[ "$best" == none ]]; then
    echo "No pull request since ${last:-the start} makes a release." >&2
    exit 0
fi
version="$("$here/next-version.sh" "$last" "$best")"
echo "Releasing $version, a $best release after ${last:-nothing}." >&2

{
    echo "Install or update with Homebrew:"
    echo
    echo '```sh'
    echo 'brew install --cask krystxf/tap/pop-mac   # or: brew upgrade --cask pop-mac'
    echo '```'
    echo
    echo "## Changes"
    cat "$tmp/changes"
    echo
    echo "From $(paste -s -d ' ' "$tmp/numbers" | sed 's/ /, /g')."
    echo
    echo "## Upgrading"
    echo "Releases are signed with a Developer ID and notarized by Apple, so Pop Mac keeps its Accessibility access across upgrades."
    echo "If you installed Pop Mac with the \`pop-mac\` formula, switch to the cask once:"
    echo
    echo '```sh'
    echo 'brew uninstall pop-mac && brew install --cask krystxf/tap/pop-mac'
    echo '```'
} > "$notes_file"
echo "$version"
