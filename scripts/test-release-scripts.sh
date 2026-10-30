#!/usr/bin/env bash
# Tests release-bump.sh, next-version.sh, and release-notes.sh.
set -euo pipefail
cd "$(dirname "$0")"

failures=0
check() {
    local name="$1" expected="$2" actual="$3"
    if [[ "$actual" == "$expected" ]]; then
        echo "ok: $name"
    else
        echo "FAIL: $name"
        echo "  expected: $expected"
        echo "  actual:   $actual"
        failures=$((failures + 1))
    fi
}

code=$'Sources/PopMac/Actions.swift\nREADME.md'
docs=$'README.md\ndocs/pop-mac-drag-demo.gif\n.github/workflows/ci.yml'
check "a label picks the part" minor "$(./release-bump.sh "bug release:minor" <<< "$docs")"
check "no-release wins over code changes" none "$(./release-bump.sh "no-release" <<< "$code")"
check "code without a label is a patch" patch "$(./release-bump.sh "" <<< "$code")"
check "docs and workflows only make no release" none "$(./release-bump.sh "" <<< "$docs")"
check "two release labels fail" 2 "$(./release-bump.sh "release:major release:patch" <<< "$code" 2> /dev/null || echo $?)"

check "major" 1.0.0 "$(./next-version.sh v0.5.3 major)"
check "minor" 0.6.0 "$(./next-version.sh v0.5.3 minor)"
check "patch" 0.5.4 "$(./next-version.sh v0.5.3 patch)"
check "first release" 0.1.0 "$(./next-version.sh "" minor)"
check "a bad tag fails" 2 "$(./next-version.sh v1.2 patch 2> /dev/null || echo $?)"

body=$'## Release notes\r\n\r\n<!--\r\nA comment\r\n-->\r\n\r\n- One change\r\n- Another change\r\n\r\n## Details\r\n\r\nNot a note.'
check "notes without comments and details" $'- One change\n- Another change' "$(./release-notes.sh <<< "$body")"
check "the empty template has no notes" "" "$(./release-notes.sh < ../.github/pull_request_template.md)"
check "a description without the section has no notes" "" "$(./release-notes.sh <<< "Just text")"

check "a one-line comment keeps the notes" $'- Fix focus\n- Faster tiling' \
    "$(./release-notes.sh <<< $'## Release notes\n<!-- short -->\n- Fix focus\n- Faster tiling')"
check "a comment after a note goes" $'- Fix X\n- Fix Y' \
    "$(./release-notes.sh <<< $'## Release notes\n- Fix X <!-- internal -->\n- Fix Y')"

# plan-release.sh, with a fake gh that answers from files, in a throwaway repository.
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/data" "$tmp/repo"
cat > "$tmp/bin/gh" << 'FAKE'
#!/usr/bin/env bash
# A fake gh: api repos/R/commits/SHA/pulls, api --paginate repos/R/pulls/N/files, pr view N --repo R --json FIELD.
if [[ "$1" == api && "$2" == --paginate ]]; then
    number="${3%/files}"
    cat "$FAKE_GH_DATA/pr-${number##*/}-files"
elif [[ "$1" == api ]]; then
    sha="${2%/pulls}"
    cat "$FAKE_GH_DATA/commit-${sha##*/}" 2> /dev/null || true
else
    cat "$FAKE_GH_DATA/pr-$3-$7"
fi
FAKE
chmod +x "$tmp/bin/gh"
commit() {
    git -C "$tmp/repo" -c user.name=test -c user.email=test@example.com commit -q --allow-empty -m "$1"
    git -C "$tmp/repo" rev-parse HEAD
}
plan() {
    (cd "$tmp/repo" && PATH="$tmp/bin:$PATH" FAKE_GH_DATA="$tmp/data" GITHUB_REPOSITORY=owner/repo \
        "$OLDPWD/plan-release.sh" "$tmp/notes.md" 2> /dev/null)
}
git -C "$tmp/repo" init -q
commit "Before the last release" > /dev/null
git -C "$tmp/repo" tag v0.5.0
echo 1 > "$tmp/data/commit-$(commit "Merge #1")"
echo 2 > "$tmp/data/commit-$(commit "Merge #2")"
echo 3 > "$tmp/data/commit-$(commit "Merge #3")"
commit "A commit from no pull request" > /dev/null
printf 'release:minor' > "$tmp/data/pr-1-labels"
printf 'Sources/A.swift\n' > "$tmp/data/pr-1-files"
printf '## Release notes\n\n- Feature one\n' > "$tmp/data/pr-1-body"
printf '' > "$tmp/data/pr-2-labels"
printf 'README.md\n' > "$tmp/data/pr-2-files"
printf '' > "$tmp/data/pr-3-labels"
printf 'Sources/B.swift\n' > "$tmp/data/pr-3-files"
printf '' > "$tmp/data/pr-3-body"
printf 'Fix a crash' > "$tmp/data/pr-3-title"
check "the plan releases every pull request since the tag" 0.6.0 "$(plan)"
check "the notes have each releasing pull request" $'- Feature one\n- Fix a crash\nFrom #1, #3.' \
    "$(grep -E '^- |^From' "$tmp/notes.md")"
printf 'no-release' > "$tmp/data/pr-1-labels"
printf 'no-release' > "$tmp/data/pr-3-labels"
check "the plan makes no release when nothing releases" "" "$(plan)"

if ((failures > 0)); then
    echo "$failures failed"
    exit 1
fi
