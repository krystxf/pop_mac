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

if ((failures > 0)); then
    echo "$failures failed"
    exit 1
fi
