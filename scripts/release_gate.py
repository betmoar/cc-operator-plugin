#!/usr/bin/env python3
"""Release gate: a v<x.y.z> tag must match plugin.json and CHANGELOG.md.

Run by .github/workflows/release.yml on tag push; also runnable locally
before pushing a tag:

    python3 scripts/release_gate.py v0.1.0 [--root DIR] [--notes-out FILE]

The three-way coupling this enforces (see CLAUDE.md's release row):

    tag v<x.y.z>  ==  plugin.json "version"  ==  newest CHANGELOG heading

validate_plugin's check_changelog already enforces the
version==newest-heading half on every PR; this gate re-checks it at release
time and adds the tag itself. With --notes-out, the tag version's CHANGELOG
section is written to FILE for use as the GitHub release body — so release
notes are the changelog, not a hand-written duplicate.
"""
import argparse
import json
import pathlib
import re
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from validate_plugin import CHANGELOG_HEADING_RE  # single source of truth

TAG_RE = re.compile(r"^v(\d+\.\d+\.\d+)$")

# Inline code spans and fenced blocks quote references rather than making them.
# Mirrors validate_plugin.MD_CODE_RE; kept local so this script stays runnable
# on its own, which is how the release workflow invokes it.
CODE_SPAN_RE = re.compile(r"^[ \t]*(```|~~~).*?^[ \t]*\1[ \t]*$|`+[^`\n]*`+",
                          re.DOTALL | re.MULTILINE)


def extract_section(changelog_text, version):
    """Return the CHANGELOG body between '## [version]' and the next
    '## [' heading or the trailing link-reference block.

    The section's own `[#N]` references are re-appended as link definitions.
    Without that, a section using reference-style issue links publishes with
    literal `[#27]` text and no link: the body is cut at `^\\[`, which IS the
    def block, so the defs never travel with the section that needs them.
    Measured on v0.7.0 before this fix — 9 dead references in the release body.
    Only the defs this section actually uses are carried, so the other
    versions' references do not leak into the notes.

    Callers that must not publish a broken body use `extract_section_checked`,
    which also reports the references no definition anywhere could satisfy.
    """
    return extract_section_checked(changelog_text, version)[0]


def extract_section_checked(changelog_text, version):
    """`extract_section`, plus the sorted list of `[#N]` the body uses that have
    no definition anywhere in the changelog.

    Returning them is the point: appending only the defs that exist means a
    reference with no def at all silently keeps its literal `[#N]` text, which
    is exactly the dead-link bug this function was written to fix, reproduced
    on a different input. `gate()` refuses to publish such a body.

    `check_issue_refs` catches the same thing on every PR, so in the normal flow
    this never fires. That is not a reason to skip it: release_gate.py is the
    independent second gate — runnable locally, run again on the tag — and a
    CHANGELOG edited on a release branch after the last green PR reaches `gh
    release create` without the validator ever having seen it.

    Code spans are stripped before the scan, so prose QUOTING a reference —
    `[#28]` in backticks, as this repo's own changelog does when documenting the
    inverted-ref class — is not mistaken for one. Same rule as
    `validate_plugin.MD_CODE_RE`; the two are independent by design (this file
    must run standalone), so a change to the convention needs both.
    """
    start = re.search(rf"^## \[{re.escape(version)}\][^\n]*\n",
                      changelog_text, re.MULTILINE)
    if not start:
        return "", []
    rest = changelog_text[start.end():]
    stop = re.search(r"^## \[|^\[", rest, re.MULTILINE)
    body = (rest[:stop.start()] if stop else rest).strip()

    scannable = CODE_SPAN_RE.sub("", body)
    used = set(re.findall(r"\[#(\d+)\](?![:(])", scannable))
    if not used:
        return body, []
    known = dict(re.findall(r"^\[#(\d+)\]:[ \t]*(\S+)",
                            changelog_text, re.MULTILINE))
    unresolved = sorted(used - set(known), key=int)
    defs = [f"[#{n}]: {known[n]}" for n in sorted(used & set(known), key=int)]
    notes = body + "\n\n" + "\n".join(defs) if defs else body
    return notes, unresolved


def unreleased_body(changelog_text):
    """The `## [Unreleased]` section's content, stripped. "" when absent or
    whitespace-only.

    Deliberately a SEPARATE reader from `extract_section`, not a call into it:
    that function is keyed on a version string and `CHANGELOG_HEADING_RE`
    matches `[x.y.z]` only — by design, so the newest *version* heading is found
    correctly. `[Unreleased]` is invisible to it, and making it visible would
    mean loosening the regex every other caller depends on.

    Stops at the next `## [` heading OR the trailing `^[` link-definition
    block, the same two terminators `extract_section` uses. A changelog whose
    Unreleased section is followed directly by the def block (no versions yet)
    would otherwise swallow every definition in the file and read as non-empty
    forever.
    """
    start = re.search(r"^## \[Unreleased\][^\n]*\n", changelog_text,
                      re.MULTILINE)
    if not start:
        return ""
    rest = changelog_text[start.end():]
    stop = re.search(r"^## \[|^\[", rest, re.MULTILINE)
    return (rest[:stop.start()] if stop else rest).strip()


def gate(root, tag):
    """Return (problems, notes); empty problems means the tag may ship."""
    root = pathlib.Path(root)
    problems, notes = [], ""
    m = TAG_RE.match(tag)
    if not m:
        return [f"tag {tag!r} is not v<x.y.z> — retag, e.g. v0.1.0"], notes
    ver = m.group(1)

    plugin_path = root / ".claude-plugin" / "plugin.json"
    try:
        version = json.loads(
            plugin_path.read_text(encoding="utf-8")).get("version")
    except (FileNotFoundError, json.JSONDecodeError) as e:
        problems.append(f"plugin.json unreadable: {e}")
        version = None
    if version is not None and version != ver:
        problems.append(
            f"tag {tag} does not match plugin.json version {version!r} — "
            f"bump plugin.json (and CHANGELOG) before tagging, or fix the tag")

    changelog_path = root / "CHANGELOG.md"
    if not changelog_path.is_file():
        problems.append("CHANGELOG.md: missing")
        return problems, notes
    text = changelog_path.read_text(encoding="utf-8")
    headings = CHANGELOG_HEADING_RE.findall(text)
    newest = headings[0] if headings else None
    if newest != ver:
        problems.append(
            f"newest CHANGELOG heading is '[{newest}]' but the tag is {tag} — "
            f"the '## [{ver}]' entry must be the first heading below "
            f"[Unreleased]")
    # A non-empty [Unreleased] at TAG TIME is content about to be dropped on the
    # floor (#39): the notes are the tag version's section alone, so anything
    # written above it ships in the commits and appears nowhere a reader looks.
    # v0.7.0 shipped exactly this way — five subsections describing work that
    # WAS in the tag, absent from the release page, repaired after the fact in
    # 6f92b5d at a cost of 139 changelog lines.
    #
    # Three decisions, each the opposite of the obvious one:
    #   - Checked at RELEASE time, not on every PR. The section is legitimate
    #     between releases; "reject any [Unreleased]" would fail every commit
    #     that uses the file as intended.
    #   - REFUSED, never auto-folded. Rewriting a maintainer's changelog during
    #     a tag build is a write nobody asked for, and this project already
    #     learned that lesson from the .gitignore v1->v2 migration, where a
    #     silent rewrite could destroy the user's rules.
    #   - Whitespace-only is EMPTY. A bare heading with a blank line under it is
    #     the normal resting state of this file (it is main's state today), and
    #     a gate that fires on it would be disabled within a release.
    pending = unreleased_body(text)
    if pending:
        first = next((ln for ln in pending.splitlines() if ln.strip()), "")
        problems.append(
            f"CHANGELOG [Unreleased] is not empty while tagging {tag} — its "
            f"content is published nowhere (release notes are the [{ver}] "
            f"section alone), so it would ship in the commits and vanish from "
            f"the release page. Fold it into [{ver}] or empty it deliberately, "
            f"then re-tag. First line: {first.strip()!r}")

    if newest == ver:
        notes, unresolved = extract_section_checked(text, ver)
        if not notes:
            problems.append(
                f"CHANGELOG section for [{ver}] is empty — write the release "
                f"notes there; they become the GitHub release body")
        if unresolved:
            refs = ", ".join(f"[#{n}]" for n in unresolved)
            problems.append(
                f"CHANGELOG section for [{ver}] uses {refs} with no "
                f"`[#N]: <url>` definition anywhere in the file — the published "
                f"release body would carry that literal text instead of a link. "
                f"Add the definition(s) to the link-reference block")
    return problems, notes


def main(argv=None):
    p = argparse.ArgumentParser(
        description="Gate a release tag against plugin.json and CHANGELOG.md.")
    p.add_argument("tag", help="the git tag, e.g. v0.1.0")
    p.add_argument("--root",
                   default=str(pathlib.Path(__file__).resolve().parent.parent),
                   help="repo root (default: this script's repo)")
    p.add_argument("--notes-out",
                   help="write the tag version's CHANGELOG section here")
    a = p.parse_args(argv)

    problems, notes = gate(a.root, a.tag)
    for prob in problems:
        print(f"FAIL: {prob}", file=sys.stderr)
    if problems:
        print(f"\nrelease gate: {len(problems)} problem(s); not shipping.",
              file=sys.stderr)
        return 1
    if a.notes_out:
        pathlib.Path(a.notes_out).write_text(notes + "\n", encoding="utf-8")
    print(f"release gate OK: {a.tag} == plugin.json == newest CHANGELOG heading")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
