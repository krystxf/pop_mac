#!/usr/bin/env python3
"""Checks the relative links and images in the Markdown files.

Each link must point to a file that exists, and a link to a heading
(file.md#heading) must match a heading in that file. Links to websites are
not checked, so the check works offline.
"""

import pathlib
import re
import sys
import urllib.parse

ROOT = pathlib.Path(__file__).resolve().parent.parent
SKIPPED_DIRS = {".build", ".git", ".swiftpm", "build"}
LINK = re.compile(r"!?\[[^\]]*\]\(\s*<?([^)\s>]+)>?(?:\s+\"[^\"]*\")?\s*\)")
FENCE = re.compile(r"^\s*(```|~~~)")


def markdown_files():
    for path in sorted(ROOT.rglob("*.md")):
        if not SKIPPED_DIRS.intersection(path.relative_to(ROOT).parts):
            yield path


def lines_outside_code(path):
    """Yields (line number, line) for the lines outside fenced code blocks."""
    in_code = False
    for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if FENCE.match(line):
            in_code = not in_code
        elif not in_code:
            yield number, line


def anchors(path):
    """The anchors that GitHub makes from the headings of a Markdown file."""
    seen = {}
    result = set()
    for _, line in lines_outside_code(path):
        match = re.match(r"^#{1,6}\s+(.*?)\s*#*\s*$", line)
        if not match:
            continue
        text = re.sub(r"`|\*|_(?=\S)|(?<=\S)_", "", match.group(1)).lower()
        slug = re.sub(r"[^\w\- ]", "", text).replace(" ", "-")
        count = seen.get(slug, 0)
        seen[slug] = count + 1
        result.add(slug if count == 0 else f"{slug}-{count}")
    return result


def main():
    problems = []
    for path in markdown_files():
        for number, line in lines_outside_code(path):
            for target in LINK.findall(re.sub(r"`[^`]*`", "", line)):
                if re.match(r"^[a-z][a-z0-9+.-]*:", target, re.I):
                    continue  # A website, an email address, or another scheme.
                file_part, _, anchor = urllib.parse.unquote(target).partition("#")
                linked = (path.parent / file_part).resolve() if file_part else path
                where = f"{path.relative_to(ROOT)}:{number}"
                if not linked.exists():
                    problems.append(f"{where}: {target} does not exist")
                elif anchor and linked.suffix == ".md" and anchor.lower() not in anchors(linked):
                    problems.append(f"{where}: {target} has no heading #{anchor}")

    for problem in problems:
        print(problem)
    if problems:
        sys.exit(1)
    print(f"All relative links in {len(list(markdown_files()))} Markdown files work.")


if __name__ == "__main__":
    main()
