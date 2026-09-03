#!/usr/bin/env python3
"""Validate the cc-operator plugin's structure and internal contracts.

`claude plugin validate` only checks the manifests' schema. This script
enforces the contracts that are otherwise prose in CONTRIBUTING.md / the build
ledger — the things that break the plugin (or its evidence guarantees) silently
when violated:

  1. plugin.json parses, is named `cc-operator`, and carries a semver version.
  2. marketplace.json exists (the documented install path fails without it),
     lists this plugin with a matching name, and sources it from "./" (the
     flattened repo-root layout).
  3. The plugin.json version is the NEWEST versioned heading in CHANGELOG.md
     (the first `## [x.y.z]` below [Unreleased]) — not merely present somewhere.
     The tag-triggered release.yml relies on this to gate `v<tag>`.
  4. The charter template (templates/OPERATOR.md) holds its build gates: it is
     <= 150 lines, its section headings appear in the fixed order, and every
     rule line carries a citation tag — operationalized as: at least as many
     `[D:...]`/`[DOC:...]` tags as `## ` section headings, and no ``## `` section
     body entirely tag-free. (The build's B2 gate, kept executable.) It must
     reference the verdict CLI by its project-resolvable path
     `.operator/bin/ops-verdict.sh` (the copy ops-init.sh installs) — a bare
     `scripts/...` path only resolves inside this repo.
  5. The ledger header templates match the proven schema byte-for-byte on the
     load-bearing line: VERDICTS-header.md's table header is exactly
     `| Gate | Criterion | Evidence | PASS/FAIL |` (grep habits + tooling
     transfer depend on it).
  6. Every agent in agents/ has valid frontmatter with a `name`, a `model`, and
     a `tools` line, and mentions NEEDS_CONTEXT (the refuse-don't-invent
     contract). The model must be a tier alias (opus/sonnet/haiku), never a
     pinned ID — pinned IDs hard-error when a version is retired; aliases
     track the recommended version. No agent references the build-specific
     `unknowns-harness` / `F1..F13` naming.
  7. hooks/hooks.json parses and registers a Stop hook whose command points at
     scripts/ops-stop-hook.sh, and a SessionStart hook pointing at
     scripts/ops-sessionstart-hook.sh — both via ${CLAUDE_PLUGIN_ROOT}. The
     SessionStart hook is load-bearing, not cosmetic: it is the only channel
     through which the agent learns its own session id (CLAUDE_SESSION_ID is
     not set in the Bash tool environment), and without that id every sentinel
     is opened unowned and blocks every concurrent session.
  8. The gate scripts exist and are syntactically valid bash (`bash -n`).
  9. Issue references in tracked markdown are internally consistent: every
     `[#N]` has a matching link definition and vice versa, and every issue URL
     resolves under plugin.json's `repository` at the number its label claims.
     Existence, state, and subject are NOT checked — that needs the network.

Run from anywhere: python3 scripts/validate_plugin.py [repo-root]
Exit 0 = all contracts hold; exit 1 = failures listed on stderr.
"""
import ast
import json
import os
import pathlib
import re
import subprocess
import sys
import tempfile

SEMVER_RE = re.compile(r"^\d+\.\d+\.\d+$")
CHANGELOG_HEADING_RE = re.compile(r"^## \[(\d+\.\d+\.\d+)\]", re.MULTILINE)
TAG_RE = re.compile(r"\[D:[^\]]+\]|\[DOC:[^\]]+\]")

PLUGIN_NAME = "cc-operator"
CHARTER_MAX_LINES = 150
# Companions to the line cap (audit F19): the cap bounds ALWAYS-ON tokens, so
# it must also bound what a line and the file may weigh, or packing defeats it.
CHARTER_MAX_LINE_CHARS = 100   # non-table lines; the file's own wrap is ~80
CHARTER_MAX_BYTES = 9000       # file is ~8.3KB today; headroom, not a target
CHARTER_SECTION_ORDER = [
    "ROLE",
    "SOLO MODE",
    "ORCHESTRATED MODE",
    "ENGAGEMENT CONTRACT",
    "EVIDENCE GATE",
    "HANDOFF",
    "RECOVERY PROTOCOL",
    "PRECEDENCE",
]
VERDICTS_HEADER = "| Gate | Criterion | Evidence | PASS/FAIL |"
# The .operator/bin install set (ops-init.sh) — every one must be named in the
# charter by its project-relative path.
CHARTER_REQUIRED_CLIS = ("ops-task.sh", "ops-verdict.sh", "ops-adopt.sh", "ops-claims.sh")
AGENT_MODEL_ALIASES = ("opus", "sonnet", "haiku")


def shell_code(path):
    """A shell file's CODE, with whole-line comments removed.

    Pins asserting "this guard exists" must search THIS, never `read_text()`:
    a raw-text search is satisfied by the guard's own comment, and deleting the
    guard while keeping the comment (the realistic regression) stays green —
    measured with BOTH gates silent (F1). Whole-line only:
    a trailing-comment stripper would need shell quoting, and `case` arms
    legitimately contain `#` — so a pinned literal must never sit in a trailing
    comment. GuardParityVacuityTest mutation-tests every pin.
    """
    return "\n".join(
        ln for ln in path.read_text(encoding="utf-8").splitlines()
        if not ln.lstrip().startswith("#"))


class _RedefinedFunction(str):
    """A function name defined more than once. Truthy-empty so `"x" not in body`
    fires on every pinned literal, and carries the count for the message."""
    def __new__(cls, fn, n):
        o = super().__new__(cls, "")
        o.fn, o.n = fn, n
        return o


def _function_body(code, fn):
    """The lines of shell function `fn`, or None if it cannot be located.

    None (never "") so the caller REPORTS an unlocatable function instead of
    silently pinning nothing. Brace-counting in our one house style; a K&R
    head or an unbalanced `{` in a string fails toward None → reported. Widen
    the locator then; do not make the caller tolerate None.

    A RE-DEFINED function returns an EMPTY body (#81's class, one level up from
    the variable pins): bash resolves the LAST definition, this locator scans
    forward and returns the FIRST, so appending a second `f() { … }` with none
    of the pinned properties left every caller pinning a dead body while the
    live one shipped unguarded — measured 2026-08-24 against check_autobar,
    which reported "all contracts hold" with the NUL read, the repo check and
    the `-z` flag all gone. An empty body fails every `in body` test, so the
    caller reports rather than passing; the redefinition itself is named by
    _report_if_redefined, which every caller invokes before its own pins.

    That reporting half shipped MISSING (#86 review): the docstring promised a
    `check_no_redefinitions` that existed nowhere in the tree, and .fn/.n were
    computed and then discarded — the exact computed-then-discarded shape this
    repo has been bitten by before. What actually fired was three unrelated,
    individually-worded false positives ("does not pass -z", "does not use
    process substitution", "no rev-parse check"), none of them true, while the
    real defect went unnamed. The sibling variable guard (_single_assignment)
    had reported its duplicate correctly since #81; this half never did.
    """
    lines = code.splitlines()
    heads = [i for i, ln in enumerate(lines)
             if re.match(rf"^\s*{re.escape(fn)}\s*\(\)\s*\{{", ln)]
    if len(heads) > 1:
        return _RedefinedFunction(fn, len(heads))
    for i, ln in enumerate(lines):
        if re.match(rf"^\s*{re.escape(fn)}\s*\(\)\s*\{{", ln):
            depth, body = 0, []
            for cur in lines[i:]:
                depth += cur.count("{") - cur.count("}")
                body.append(cur)
                if depth <= 0 and len(body) > 0 and "{" in "".join(body):
                    break
            return "\n".join(body)
    return None


def _embedded_python(body):
    """The `python3 -c '…'` program inside a shell body, parsed, or None.

    None means "could not read it" — every caller falls back to a substring
    test rather than treating unparseable as absent. A locator that fails
    toward "the guard is missing" turns a quoting change into a build failure;
    one that fails toward "present" is the vacuity this file is fighting. The
    fallback is the lesser of the two, and it is stated here so the choice is
    visible rather than inferred from behaviour.
    """
    m = re.search(r"python3\s+-c\s+'(.*?)'\s", body, re.DOTALL)
    if not m:
        return None
    try:
        return ast.parse(m.group(1))
    except SyntaxError:
        return None


def _is_bool_isinstance(node):
    """True for an `isinstance(v, bool)` call node, however it is spelled."""
    return (isinstance(node, ast.Call)
            and isinstance(node.func, ast.Name) and node.func.id == "isinstance"
            and len(node.args) == 2
            and isinstance(node.args[0], ast.Name) and node.args[0].id == "v"
            and isinstance(node.args[1], ast.Name) and node.args[1].id == "bool")


def _under_dead_guard(target, tree):
    """True when `target` sits in a branch a constant makes unreachable.

    Covers `if False and X:` / `if X and False:` / `if 0:` and the ternary
    equivalents — the dead-code family, not a general reachability analysis.
    Anything subtler than a literal constant is not a maintainer's reflex fix,
    and pretending to catch it would be the same overclaim as the substring
    test this replaces.
    """
    def const_false(n):
        return isinstance(n, ast.Constant) and not n.value

    for node in ast.walk(tree):
        tests = []
        if isinstance(node, (ast.If, ast.IfExp)):
            tests = [node.test]
        elif isinstance(node, ast.While):
            tests = [node.test]
        if not tests:
            continue
        for t in tests:
            dead = const_false(t) or (
                isinstance(t, ast.BoolOp) and isinstance(t.op, ast.And)
                and any(const_false(x) for x in t.values))
            if dead and any(n is target for n in ast.walk(node)):
                return True
    return False


def _report_if_redefined(body, rel, problems):
    """Name a redefinition and tell the caller to skip its own pins.

    True → the caller must NOT run its `"literal" not in body` checks: an
    empty body fails all of them, so each would emit a confident, wrong,
    individually-worded problem about a property that is right there in the
    live definition. One accurate message beats N misattributed ones.

    Mirrors _single_assignment's duplicate branch, which is the same defect
    one level down (a variable assigned twice vs a function defined twice) and
    has reported it correctly since #81.
    """
    if not isinstance(body, _RedefinedFunction):
        return False
    problems.append(
        f"{rel}: {body.fn}() is defined {body.n} times — bash resolves the "
        f"LAST definition and this locator reads the FIRST, so every pin here "
        f"would check a dead body while the live one ships unguarded (#81's "
        f"class, one level up). Keep exactly one definition")
    return True


def _single_assignment(code, pattern, rel, var, problems):
    """The one match for `pattern`, or None when it is absent OR re-assigned.

    #81: the validator pinned the FIRST `^VAR="…"$` and bash resolves the LAST,
    so appending one line left the checker pinning a dead assignment while the
    live value shipped unguarded — measured on ops-claims.sh's PROTECTED, which
    disarmed the guard on validate_plugin.py, tests/, .operator/bin/ and hooks/
    with `validate_plugin: all contracts hold`. A duplicate is REPORTED here so
    the caller cannot silently pin either one.
    """
    ms = re.findall(pattern, code, re.MULTILINE)
    if len(ms) > 1:
        problems.append(
            f"{rel}: {var} is assigned {len(ms)} times — bash resolves the LAST, "
            f"and every pin here reads the first, so an appended line disarms "
            f"the guard with the build green (#81). Keep exactly one assignment")
        return None
    return ms[0] if ms else None

def load_json(path, problems):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        problems.append(f"{path.name}: missing")
    except json.JSONDecodeError as e:
        problems.append(f"{path.name}: invalid JSON — {e}")
    return None


def check_manifests(root, problems):
    plugin = load_json(root / ".claude-plugin" / "plugin.json", problems)
    if plugin is not None:
        if plugin.get("name") != PLUGIN_NAME:
            problems.append(
                f"plugin.json: name is {plugin.get('name')!r}, expected "
                f"{PLUGIN_NAME!r} (drives the /{PLUGIN_NAME}:start command)")
        ver = plugin.get("version", "")
        if not SEMVER_RE.match(str(ver)):
            problems.append(f"plugin.json: version {ver!r} is not semver x.y.z")

    market = load_json(root / ".claude-plugin" / "marketplace.json", problems)
    if market is not None:
        entries = market.get("plugins", [])
        names = [e.get("name") for e in entries]
        if PLUGIN_NAME not in names:
            problems.append(
                f"marketplace.json: no plugin named {PLUGIN_NAME!r} "
                f"(found {names})")
        for e in entries:
            if e.get("name") == PLUGIN_NAME and e.get("source") != "./":
                problems.append(
                    f"marketplace.json: {PLUGIN_NAME} source is "
                    f"{e.get('source')!r}, expected './' (repo-root layout)")


def check_statusline(root, problems):
    """The statusline manifest must point at a renderer that exists.

    cc-status discovers the segment purely from `.claude-plugin/statusline.json`
    and silently skips a manifest whose `render` path does not resolve. That is
    the whole failure: no error anywhere, the segment simply never appears, and
    the bar looks exactly like a project with no open tasks. Renaming or moving
    the script is the obvious way to cause it.

    The name must also match the plugin, because that string is the key users
    toggle (`/cc-status:toggle cc-operator on`).
    """
    manifest = root / ".claude-plugin" / "statusline.json"
    if not manifest.is_file():
        problems.append(
            ".claude-plugin/statusline.json: missing — the statusline segment "
            "is only discoverable through this manifest")
        return
    data = load_json(manifest, problems)
    if data is None:
        return
    if data.get("name") != PLUGIN_NAME:
        problems.append(
            f"statusline.json: name is {data.get('name')!r}, expected "
            f"{PLUGIN_NAME!r} (the key users toggle in cc-status)")
    render = data.get("render", "")
    if not render:
        problems.append("statusline.json: no 'render' path")
    elif not (root / render).is_file():
        problems.append(
            f"statusline.json: render path {render!r} does not resolve — "
            f"cc-status skips an unresolvable renderer SILENTLY, so the segment "
            f"just never appears")
    order = data.get("order")
    if order is not None and not isinstance(order, int):
        problems.append(
            f"statusline.json: order {order!r} is not an integer")


def check_changelog(root, problems):
    plugin = root / ".claude-plugin" / "plugin.json"
    changelog = root / "CHANGELOG.md"
    if not changelog.is_file():
        problems.append("CHANGELOG.md: missing")
        return
    try:
        version = json.loads(plugin.read_text(encoding="utf-8")).get("version")
    except (FileNotFoundError, json.JSONDecodeError):
        return  # already reported by check_manifests
    headings = CHANGELOG_HEADING_RE.findall(changelog.read_text(encoding="utf-8"))
    newest = headings[0] if headings else None
    if newest != version:
        problems.append(
            f"CHANGELOG.md: newest versioned heading is '[{newest}]' but "
            f"plugin.json version is {version!r} — the '## [{version}]' entry "
            f"must be the first heading below [Unreleased]")


def check_charter(root, problems):
    charter = root / "templates" / "OPERATOR.md"
    if not charter.is_file():
        problems.append("templates/OPERATOR.md: missing")
        return
    lines = charter.read_text(encoding="utf-8").splitlines()
    if len(lines) > CHARTER_MAX_LINES:
        problems.append(
            f"templates/OPERATOR.md: {len(lines)} lines > {CHARTER_MAX_LINES} cap")
    # The line cap is a proxy for ALWAYS-ON BYTES — chars are what a session is
    # billed, and a line-count-only gate is gameable by packing prose into one
    # long line (audit F19: a 286-char line shipped through a green validator
    # at zero line cost the moment the file hit 150/150). Two companion bounds
    # make the cap honest: a per-line cap on non-table lines (tables are
    # legitimately one-row-per-line) and a total-bytes ceiling.
    for i, ln in enumerate(lines, 1):
        if len(ln) > CHARTER_MAX_LINE_CHARS and not ln.lstrip().startswith("|"):
            problems.append(
                f"templates/OPERATOR.md:{i}: {len(ln)}-char line > "
                f"{CHARTER_MAX_LINE_CHARS} — packing prose into long lines "
                f"defeats the {CHARTER_MAX_LINES}-line cap's purpose (F19); "
                f"wrap it and trim elsewhere")
    total = sum(len(ln) + 1 for ln in lines)
    if total > CHARTER_MAX_BYTES:
        problems.append(
            f"templates/OPERATOR.md: {total} bytes > {CHARTER_MAX_BYTES} "
            f"ceiling — the charter is billed in every operated session; "
            f"cut before adding (F19)")

    headings = [ln[3:].split(" (")[0].strip()
                for ln in lines if ln.startswith("## ")]
    if headings != CHARTER_SECTION_ORDER:
        problems.append(
            f"templates/OPERATOR.md: section order {headings} != "
            f"expected {CHARTER_SECTION_ORDER}")

    text = "\n".join(lines)
    # Every CLI ops-init installs into .operator/bin must be reachable from the
    # charter — that project-relative path is the only one that resolves in a
    # target project (the model's shell has no ${CLAUDE_PLUGIN_ROOT}).
    for cli in CHARTER_REQUIRED_CLIS:
        if f".operator/bin/{cli}" not in text:
            problems.append(
                f"templates/OPERATOR.md: does not reference "
                f"'.operator/bin/{cli}' — the charter must name every "
                f"project-installed CLI path (a scripts/ path does not "
                f"resolve in a target project)")

    tags = TAG_RE.findall(text)
    if len(tags) < len([h for h in headings]):
        problems.append(
            f"templates/OPERATOR.md: only {len(tags)} citation tags for "
            f"{len(headings)} sections — every rule line must carry [D:]/[DOC:]")
    # Every [DOC:spec-<key>] must resolve to a `### spec-<key>` heading in
    # docs/spec/TAGS.md (#76 step E). Orphan entries are deliberately allowed:
    # history, not rot.
    doc_keys = {t[5:-1] for t in tags if t.startswith("[DOC:")}
    tags_md = root / "docs" / "spec" / "TAGS.md"
    if doc_keys and not tags_md.is_file():
        problems.append(
            "docs/spec/TAGS.md: missing — the charter carries "
            f"{len(doc_keys)} [DOC:*] tags and this index is where they "
            f"resolve in a clone (the original spec files were never "
            f"committed); ship the index or drop the tags")
    elif doc_keys:
        headings_md = set(re.findall(r"^### (\S+)\s*$",
                                     tags_md.read_text(encoding="utf-8"),
                                     re.MULTILINE))
        for key in sorted(doc_keys - headings_md):
            problems.append(
                f"templates/OPERATOR.md: [DOC:{key}] has no `### {key}` entry "
                f"in docs/spec/TAGS.md — every DOC tag must resolve in-tree; "
                f"add the entry (what the rule anchors as shipped) or use a "
                f"[D:] tag for a self-describing decision reference")
    # no ## section (other than the title) should be entirely tag-free
    section, body = None, []
    def flush(sec, bod):
        if sec and not TAG_RE.search("\n".join(bod)):
            problems.append(
                f"templates/OPERATOR.md: section '{sec}' has no citation tag")
    for ln in lines:
        if ln.startswith("## "):
            flush(section, body)
            section, body = ln[3:], []
        else:
            body.append(ln)
    flush(section, body)


def check_ledger_schema(root, problems):
    v = root / "templates" / "VERDICTS-header.md"
    if not v.is_file():
        problems.append("templates/VERDICTS-header.md: missing")
        return
    if VERDICTS_HEADER not in v.read_text(encoding="utf-8"):
        problems.append(
            f"templates/VERDICTS-header.md: missing the exact header line "
            f"{VERDICTS_HEADER!r} (schema must byte-match the proven ledger)")


# The dispatch packet's spine, as the charter states it. HANDOUT.md re-teaches
# the packet in plain English and drifted once (F69), dropping the fields
# ops-claims verifies — the pin applies only when the file exists: deleting the
# handout is a visible act, drifting it is not. `REACH` (#57) is inserted in the
# middle is invisible to this check — which is exactly where REACH went. The
# handout kept teaching a packet with no reachability clause and the pin stayed
# green, the F69 drift repeating inside the guard written against it. Any field
# added to the charter's packet must be added here too; a spine that only pins
# the ends is a guard against reordering, not against drift.
HANDOUT_PACKET_SPINE = ("TASK / TEXT / SCENE", "REACH", "CHANGED: <paths>|none")


def _packet_block(text):
    """The fenced block that carries the dispatch packet, or None.

    Searching the WHOLE document was the bug (Copilot, PR #72): explanatory
    prose around the packet already contains 'REACH', so deleting REACH from
    the fenced packet itself left the pin green — the field could vanish from
    the contract while the word survived in a sentence about it. Measured on
    the shipped HANDOUT.md: REACH appears both inside and outside the fence.
    The packet is the artifact; the prose is commentary about it.
    """
    for block in re.findall(r"```.*?```", text, re.S):
        if "TASK / TEXT / SCENE" in block:
            return block
    return None


def check_handout_packet(root, problems):
    # The CHARTER is checked first, and unconditionally. The handout half of this
    # pin only ever asked "does the copy match the original?" — which passes
    # perfectly when the original is the thing that lost a field. Uniform drift
    # is invisible to a parity check (F30), and here the parity is between a doc
    # and the charter it teaches, so the charter needs its own assertion or the
    # pin is one deletion away from vacuous.
    for rel, note in (("templates/OPERATOR.md",
                       "the packet is the worker-boundary contract and every field "
                       "in it is load-bearing (REACH: #57; CHANGED: the input "
                       "ops-claims.sh verifies)"),
                      ("docs/HANDOUT.md",
                       "the handout must teach the charter's dispatch packet "
                       "verbatim (templates/OPERATOR.md), or ops-claims.sh gets "
                       "reports it cannot check (F69)")):
        f = root / rel
        # HANDOUT.md is optional prose; the charter is not. Deleting the handout
        # is a visible act, drifting it is not — same reasoning as before.
        if not f.is_file():
            if rel == "docs/HANDOUT.md":
                continue
            problems.append(f"{rel}: missing — the charter is not optional")
            continue
        block = _packet_block(f.read_text(encoding="utf-8"))
        if block is None:
            problems.append(
                f"{rel}: no fenced dispatch-packet block found (looked for a "
                f"``` block containing 'TASK / TEXT / SCENE') — a moved or "
                f"unfenced packet is REPORTED, never silently skipped")
            continue
        for token in HANDOUT_PACKET_SPINE:
            if token not in block:
                problems.append(
                    f"{rel}: the dispatch packet is missing {token!r} — {note}")


# The source-state stamp (U10/#22) — an unstamped row looks stamped until
# audited. Pins: markers in CODE; the row printf keeps FOUR cells with the
# stamp inside cell 3 (a fifth breaks every ledger and grep in the field);
# the value APPLIED at the row site (F30); .operator/ excluded from the dirty
# test (#21: a marker that cannot be off marks nothing); git resolved BEFORE
# lock_acquire (PLAYBOOK).
STAMP_MARKERS = ("no-vcs", "no-commit", "+dirty", "+unknown")
STAMP_ROW_FORMAT = "'| %s | %s | %s @%s | %s |'"
STAMP_DIRTY_EXCLUDE = "':(exclude).operator'"


def check_source_stamp(root, problems):
    p = root / "scripts" / "ops-verdict.sh"
    if not p.is_file():
        problems.append("scripts/ops-verdict.sh: missing")
        return
    text = p.read_text(encoding="utf-8")
    # Comments stripped for every assertion below: the header prose names each
    # marker, so a function gutted to `printf ''` would satisfy a naive scan of
    # the whole file. That is the vacuous-guard shape this check exists to avoid
    # becoming.
    code = "\n".join(
        ln for ln in text.splitlines() if not ln.lstrip().startswith("#"))
    if "source_stamp()" not in code:
        problems.append(
            "scripts/ops-verdict.sh: no source_stamp() — the verdict row must "
            "name the source state that produced it (issue #22)")
        return
    for marker in STAMP_MARKERS:
        if marker not in code:
            problems.append(
                f"scripts/ops-verdict.sh: source_stamp lost the {marker!r} "
                f"marker — every failure path must degrade to an explicit "
                f"state, never to silence")
    if STAMP_DIRTY_EXCLUDE not in code:
        problems.append(
            f"scripts/ops-verdict.sh: the dirty test must exclude "
            f"{STAMP_DIRTY_EXCLUDE} — .operator/ is untracked in most projects, "
            f"so counting it stamps every row +dirty and the marker becomes "
            f"vacuous (#21)")
    if STAMP_ROW_FORMAT not in code:
        problems.append(
            f"scripts/ops-verdict.sh: the verdict row format must be "
            f"{STAMP_ROW_FORMAT} — four cells with the stamp inside the "
            f"evidence cell; a fifth cell breaks every existing ledger")
    # "Applied" = the ROW's printf argument list carries it (an
    # assignment-line literal satisfied a substring test while shipping
    # unstamped rows - F30 inside this very check).
    row = re.search(r'ROW="\$\(printf\s+' + re.escape(STAMP_ROW_FORMAT)
                    + r'(?P<args>[^\n]*?)\)"', code)
    if not row:
        problems.append(
            "scripts/ops-verdict.sh: no `ROW=\"$(printf <4-cell format> …)\"` "
            "site found — check_source_stamp cannot verify the stamp reaches "
            "the row (not-found is a reported problem, never a silent skip)")
    elif "$SOURCE_STAMP" not in row.group("args"):
        problems.append(
            "scripts/ops-verdict.sh: the verdict row's printf does not pass "
            "\"$SOURCE_STAMP\" — the stamp is resolved and then dropped, so "
            "every row ships unstamped while source_stamp() still exists "
            "(F30: declared-but-not-applied)")
    if "SOURCE_STAMP" not in code:
        problems.append(
            "scripts/ops-verdict.sh: source_stamp() is defined but its result "
            "is never applied to the row (F30: declared-but-not-applied)")
        return
    # Resolve BEFORE lock_acquire: git status inside the lock outruns
    # LOCK_LIVE_SPINS and waiters proceed unlocked. The section split runs on
    # RAW text (the section marker is itself a comment) and not-found REPORTS -
    # a locator that skips is fail-open.
    section = text.split("# --- Verdict path ---", 1)
    if len(section) != 2:
        problems.append(
            "scripts/ops-verdict.sh: no '# --- Verdict path ---' marker — the "
            "stamp-before-lock ordering cannot be checked; restore the marker "
            "or rewrite this check, never leave it silently unenforced")
        return
    lines = [ln for ln in section[1].splitlines()
             if not ln.lstrip().startswith("#")]
    # EVERY stamp site, not the first. The pin read `next(...)` and was
    # satisfied by the earliest call, so APPENDING a second
    # `SOURCE_STAMP="$(source_stamp)"` after lock_acquire left the first one
    # in place, kept stamp_at < lock_at true, and put an unbounded git status
    # inside the critical section — the exact hazard this message names, at a
    # site the pin could not see. Measured: validator green, 193 python green,
    # 683 bash green (#86 pin audit, SN5).
    #
    # Appending is also the PLAUSIBLE mutation: a maintainer who wants a
    # fresher stamp adds a line rather than moving one. Same first-vs-last
    # shape as #81, which this file already fixed for variable assignments
    # (_single_assignment) and function definitions (_function_body) and had
    # never fixed for ORDER.
    stamps = [i for i, ln in enumerate(lines) if "source_stamp" in ln]
    lock_at = next(
        (i for i, ln in enumerate(lines) if "lock_acquire" in ln), None)
    if not stamps or lock_at is None:
        problems.append(
            "scripts/ops-verdict.sh: the source stamp must be resolved "
            "BEFORE lock_acquire on the verdict path — git work inside the "
            "critical section is the PLAYBOOK's step-3 hazard "
            f"(stamp sites found: {len(stamps)}, lock_acquire found: "
            f"{lock_at is not None})")
    elif max(stamps) > lock_at:
        late = len([i for i in stamps if i > lock_at])
        problems.append(
            f"scripts/ops-verdict.sh: {late} of {len(stamps)} source_stamp "
            "call(s) sit AFTER lock_acquire on the verdict path. git status "
            "is unbounded work and every waiter blocks on it — the PLAYBOOK's "
            "step-3 hazard. One call, before the lock; adding a second later "
            "one does not make the first correct")


# DECISIONS-header kinds: GATED (block Stop), RECORD (never block), and the
# HANDOFF-MARK marker. The deviation gate counts ONLY the gated kinds; the
# schema must advertise the split (#9, F30).
DECISIONS_GATED_KINDS = ("DEVIATION", "ESCALATION", "GATE-EXCEPTION")
DECISIONS_RECORD_KINDS = ("DECISION", "DEFERRED-VERDICT")
DECISIONS_MARKER_KIND = "HANDOFF-MARK"
# The gated kinds, in order, as the hook's case-statement literal.
DECISIONS_GATED_LITERAL = "|".join(DECISIONS_GATED_KINDS)


def check_decisions_schema(root, problems):
    d = root / "templates" / "DECISIONS-header.md"
    if not d.is_file():
        problems.append("templates/DECISIONS-header.md: missing")
        return
    text = d.read_text(encoding="utf-8")
    for k in (*DECISIONS_GATED_KINDS, *DECISIONS_RECORD_KINDS, DECISIONS_MARKER_KIND):
        if k not in text:
            problems.append(
                f"templates/DECISIONS-header.md: kind enum missing {k!r} "
                f"— the deviation gate (stage 2) parses this schema; a missing "
                f"HANDOFF-MARK makes every handoff-clear read as unpresented "
                f"(F30: pin the enum, not a copy)")
    # The gated/record split must be visible: a header that lists all kinds as
    # one undifferentiated enum invites operators to record decisions in a kind
    # the gate ignores (issue #9). The split is the schema's honest contract.
    if "gated" not in text or "record" not in text:
        problems.append(
            "templates/DECISIONS-header.md: kind enum does not distinguish gated "
            "from record kinds — the deviation gate blocks only "
            f"{DECISIONS_GATED_LITERAL!r}; DECISION/DEFERRED-VERDICT are records "
            "that never block. A reader who cannot see the split mistakes a "
            "non-gated record for a kind that should block Stop (issue #9)")
    # The deviation gate's SCAN lives in scripts/lib/partition.sh (0.10: the
    # hook and the bar source ONE implementation). The gated-kind and mark
    # literals must live there; the two consumers must SOURCE the lib, or the
    # hook silently runs without a deviation gate at all.
    lib = root / "scripts" / "lib" / "partition.sh"
    if lib.is_file():
        # audit F127: read the comment-stripped CODE — the raw view was
        # satisfied by the comment explaining the gated set, so shrinking the
        # case arm to `DEVIATION)` with the full enum surviving in prose
        # shipped green while two kinds stopped gating.
        s = shell_code(lib)
        if DECISIONS_GATED_LITERAL not in s:
            problems.append(
                f"scripts/lib/partition.sh: deviation gate does not count the "
                f"gated kinds ({DECISIONS_GATED_LITERAL!r}) — must match the "
                f"header's gated set exactly (issue #9)")
        if "HANDOFF-MARK" not in s:
            problems.append(
                "scripts/lib/partition.sh: does not reference HANDOFF-MARK — "
                "the deviation gate's clearing mark is in the enum but the "
                "shared scan never matches it, so a presented decision reads as "
                "unpresented forever (F30: the enum AND its consumers must agree)")
    # audit F126: a source STATEMENT, not a mention — `"partition.sh" in s`
    # was satisfied by a comment or an echo naming the file, so replacing the
    # source line with `echo "partition.sh unavailable"` shipped green while
    # the consumer ran without the partition at all (the autobar src_re
    # lesson, one lib over). Comment-stripped view, `.`/`source` at statement
    # head. The FILENAME is anchored at a path boundary (Copilot review on PR
    # #97): `\S*partition\.sh` was suffix-satisfiable — sourcing
    # `fakepartition.sh` matched, so renaming the sourced lib kept the
    # validator green with the shared partition gone. An optional
    # `/`-terminated prefix and a balanced optional quote are the only shapes
    # a real source statement takes.
    _part_src_re = re.compile(
        # A trailing comment is tolerated (audit F142) but needs WHITESPACE in
        # front of it (Copilot review on PR #105): `\s*(?:#.*)?` let
        # `partition.sh#x` pass, and bash sources a file named `partition.sh#x`.
        r'^\s*(?:\.|source)\s+("?)(?:\S*/)?partition\.sh\1(?:\s+#.*)?\s*$',
        re.MULTILINE)
    for name in ("ops-stop-hook.sh", "statusline.sh"):
        p = root / "scripts" / name
        if not p.is_file():
            continue  # missing-file is already reported by check_scripts
        if not _part_src_re.search(shell_code(p)):
            problems.append(
                f"scripts/{name}: does not SOURCE lib/partition.sh (a mention "
                f"is not a source) — the shared partition (sentinel ownership, "
                f"deviation gate) is the one contract this bar/hook pair must "
                f"not fork")
    # The verdict CLI WRITES HANDOFF-MARK; the readers above only READ it. A
    # writer that never emits the marker strands every presented decision as
    # unpresented (F30 writer half — distinct from the reader drift above).
    # audit F127: pin the EMIT, not a mention. The raw-text search was
    # satisfied by comments AND by the marker's appearance inside a die
    # message (check_owner_name quotes it), so typo-ing the printf's
    # HANDOFF-MARK shipped green while the writer stranded every presented
    # decision as unpresented. Require a printf line that carries the marker,
    # in the comment-stripped view.
    vp = root / "scripts" / "ops-verdict.sh"
    if vp.is_file():
        _vcode = shell_code(vp)
        if not re.search(r"printf[^\n]*HANDOFF-MARK", _vcode):
            problems.append(
                "scripts/ops-verdict.sh: does not reference HANDOFF-MARK — no "
                "printf emits the deviation gate's clearing mark; it is in the "
                "enum but this writer never emits it, so a presented decision "
                "reads as unpresented forever (F30: the enum AND its consumers "
                "must agree)")
        else:
            # …and the marker must land in the KIND CELL, which is the cell the
            # readers `case` on (audit F144). "a printf carries the literal" is
            # weaker than it looks: check_owner_name's die message quotes
            # HANDOFF-MARK too, so typo-ing the emit to `HANDOFF-MARKX` — after
            # which every presented decision reads as unpresented forever, the
            # exact defect F127 was written for — kept this check green
            # (measured 2026-09-02). Parse the emitted ROW instead: split the
            # printf's format on `|` and require the third cell to be exactly
            # the marker the readers match. A typo, a renamed kind, or a marker
            # that drifts into the wrong cell all fail; reflowing the row's
            # other cells stays free.
            _rows = [_m for _m in re.findall(r"printf\s+'([^']*\|[^']*)'", _vcode)
                     if "HANDOFF-MARK" in _m]
            _cells = [[_c.strip() for _c in _r.split("|")] for _r in _rows]
            if not any(len(_c) > 2 and _c[2] == DECISIONS_MARKER_KIND
                       for _c in _cells):
                problems.append(
                    f"scripts/ops-verdict.sh: no printf emits "
                    f"{DECISIONS_MARKER_KIND!r} as the row's KIND cell (cell 3 "
                    f"of the `|`-delimited format) — the readers "
                    f"(lib/partition.sh, statusline.sh) `case` on that cell, so "
                    f"a marker that is misspelled, renamed, or sitting in "
                    f"another cell clears nothing and every presented decision "
                    f"blocks Stop forever. Found kind cells: "
                    f"{[_c[2] for _c in _cells if len(_c) > 2]} (audit F144)")


def check_agents(root, problems):
    agents_dir = root / "agents"
    files = sorted(agents_dir.glob("*.md")) if agents_dir.is_dir() else []
    if not files:
        problems.append("agents/: no agent files found")
    for f in files:
        text = f.read_text(encoding="utf-8")
        fm = re.match(r"\A---\n(.*?)\n---\n", text, re.DOTALL)
        if not fm:
            problems.append(f"agents/{f.name}: no frontmatter block")
            continue
        front = fm.group(1)
        for key in ("name", "model", "tools"):
            if not re.search(rf"^{key}:\s*\S", front, re.MULTILINE):
                problems.append(f"agents/{f.name}: frontmatter missing '{key}:'")
        m = re.search(r"^model:\s*(\S+)\s*$", front, re.MULTILINE)
        if m and m.group(1) not in AGENT_MODEL_ALIASES:
            problems.append(
                f"agents/{f.name}: model {m.group(1)!r} is a pinned ID — use "
                f"a tier alias {AGENT_MODEL_ALIASES} (pinned IDs hard-error "
                f"when the version is retired)")
        if "NEEDS_CONTEXT" not in text:
            problems.append(
                f"agents/{f.name}: no NEEDS_CONTEXT (refuse-don't-invent "
                f"contract) mentioned")
        if re.search(r"unknowns-harness|\bF1[0-3]?\b", text):
            problems.append(
                f"agents/{f.name}: contains build-specific naming "
                f"(unknowns-harness / F1..F13) — should be project-agnostic")


def check_render_templates(root, problems):
    """ops-render.sh splices a resolved model id into each template's `model:`
    frontmatter line. A template lacking that line produces an agent silently
    bound to the default backend — the splice lands nowhere. Require at least a
    default.tmpl carrying a model: line whenever the renderer ships.

    Templates live in agents/_templates/*.tmpl. They are deliberately NOT .md so
    check_agents' `*.md` glob skips them (they are inputs to the renderer, not
    agents themselves): a .tmpl with a NAME/MODEL placeholder would trip the
    alias rule for no reason.
    """
    render = root / "scripts" / "ops-render.sh"
    if not render.is_file():
        return  # the renderer is optional; no templates to check
    tpl_dir = root / "agents" / "_templates"
    if not tpl_dir.is_dir() or not any(tpl_dir.glob("*.tmpl")):
        problems.append(
            "agents/_templates/: ops-render.sh ships but no *.tmpl found — the "
            f"renderer needs at least {tpl_dir}/default.tmpl to splice into")
        return
    for t in sorted(tpl_dir.glob("*.tmpl")):
        text = t.read_text(encoding="utf-8")
        if not re.search(r"^model:\s*\S", text, re.MULTILINE):
            problems.append(
                f"agents/_templates/{t.name}: no `model:` frontmatter line — "
                f"ops-render.sh splices the resolved id into it; a template "
                f"without one produces an agent bound to the default backend")

    # No CR in any splice SOURCE: the awk anchors on /^---$/, which `---\r`
    # never matches, skipping every substitution (F29). Both sources checked —
    # render_to tries the plugin-root agent file FIRST (the likelier splice).
    crlf_sources = sorted(tpl_dir.glob("*.tmpl")) + \
        sorted((root / "agents").glob("op-*.md"))
    for s in crlf_sources:
        if b"\r" in s.read_bytes():
            rel = s.relative_to(root)
            problems.append(
                f"{rel}: contains CR — ops-render.sh splices `model:` into "
                f"this file's frontmatter and its awk anchors on /^---$/, "
                f"which `---\\r` does not match (F29). Save it LF-only.")


def check_hook(root, problems):
    """The Stop/SessionStart hook commands must RUN the script they name.

    Audited 2026-08-25, two escapes, both green: prefixing the command with
    `true # ` satisfied both substring tests while running nothing (the whole
    evidence gate disarmed by three characters), and APPENDING a second entry
    to the hooks array was invisible because the check read index [0] and never
    looked at what else was there. So: match the WHOLE command against the one
    form we ship, and require the array to hold exactly that one entry.
    """
    hp = root / "hooks" / "hooks.json"
    hook = load_json(hp, problems)
    if hook is None:
        return
    for event, script in (("Stop", "ops-stop-hook.sh"),
                          ("SessionStart", "ops-sessionstart-hook.sh")):
        groups = hook.get("hooks", {}).get(event)
        if not isinstance(groups, list) or not groups:
            problems.append(f"hooks/hooks.json: no {event} hook command found")
            continue
        # EVERY matcher group, not just [0]. The first fix here read
        # `[event][0]["hooks"]` and counted the INNER list, so appending a
        # SECOND matcher group registered an unreviewed hook one level up with
        # the build green (Copilot, PR #87) — the same index-zero blindness the
        # fix was written against, one level out.
        entries = []
        for gi, group in enumerate(groups):
            inner = group.get("hooks") if isinstance(group, dict) else None
            if not isinstance(inner, list):
                problems.append(
                    f"hooks/hooks.json: {event} matcher group {gi} has no "
                    f"`hooks` list — a malformed group runs nothing and the "
                    f"gate is off")
                continue
            entries.extend(inner)
        if not entries:
            problems.append(f"hooks/hooks.json: no {event} hook command found")
            continue
        # ANCHORED, not substring: the command line is shell, so any text that
        # merely CONTAINS the path can still run something else — or nothing.
        expected = 'bash "${CLAUDE_PLUGIN_ROOT}/scripts/' + script + '"'
        cmd = entries[0].get("command") if isinstance(entries[0], dict) else None
        # A JSON-valid non-string (null, 42, a list) reached `.strip()` and
        # raised AttributeError, aborting the whole validator instead of
        # reporting a contract failure — a malformed manifest must produce the
        # normal actionable output, not a traceback.
        if not isinstance(cmd, str):
            problems.append(
                f"hooks/hooks.json: {event} command is {cmd!r}, not a string — "
                f"the harness has nothing to run and the gate is off")
        elif cmd.strip() != expected:
            problems.append(
                f"hooks/hooks.json: {event} command must be exactly "
                f"{expected!r}, got {cmd!r}. This is matched WHOLE on purpose: "
                f"the old substring test was satisfied by `true # ` + the same "
                f"path, which names the script, resolves the plugin root, and "
                f"runs nothing — the evidence gate silently off with the build "
                f"green (audited 2026-08-25)")
        # `type` decides whether the harness runs the command at all: an entry
        # carrying the exact expected string under a non-command type passes
        # every string test and executes nothing.
        etype = entries[0].get("type") if isinstance(entries[0], dict) else None
        if etype != "command":
            problems.append(
                f"hooks/hooks.json: {event} hook type is {etype!r}, not "
                f"'command' — the harness does not execute it, so the expected "
                f"command string above is decoration")
        if len(entries) != 1:
            problems.append(
                f"hooks/hooks.json: {event} has {len(entries)} hook entries "
                f"across {len(groups)} matcher group(s); exactly 1 is expected. "
                f"Only entry [0] is checked, so any other runs unreviewed — and "
                f"for Stop, an appended `exit 0` decides the gate's verdict "
                f"after ours")


def check_permission_guards(root, problems):
    r"""No NEW permission test may enter a gate script unreviewed (#21, F48 #5).

    THE CLASS. A guard whose correctness depends on a condition that cannot
    occur in the environment it runs in. It reads as protection, it is inert,
    and nothing fails loudly to say so — the F30 declared-but-not-applied shape,
    reached through the ENVIRONMENT rather than through a copy-paste.

    `[ -r ]`, `[ -w ]`, `[ -x ]` answer "would the mode bits allow this", not
    "can I actually do this", and uid 0 bypasses the bits entirely. Measured:
    root's `[ -x ]` on a chmod-000 directory is TRUE, and `ls`/`cd`/`touch`
    inside it all succeed — so there is no capability probe that distinguishes
    the state either. A permission test is therefore never a complete guard on
    its own; it is at best a best-effort half that must be paired with one that
    holds on every uid (`-d` is a TYPE test and does).

    WHY AN ALLOWLIST RATHER THAN A BAN. Both surviving sites are load-bearing:
    `-x` and `-w` catch the real off-root wedges (#19, #27) and are documented
    inert for uid 0 at the call site. Banning them outright would delete working
    guards to satisfy a rule. What must not happen is a NEW one arriving without
    that reasoning, which is exactly what happened when #27's fix added the `-w`
    half — the class went from one instance to two while #21 still said one.

    So: pin the count and the file. A new permission test anywhere in scripts/
    fails the build with the question it has to answer.
    """
    # site -> why it is allowed to exist. Comments are stripped before counting,
    # so the header prose in that same file does not inflate the number.
    ALLOWED = {}
    # Both bracket spellings AND `test`: `test -w "$PWD"` has identical
    # semantics and walked past the bracket-only regex (audited 2026-08-25).
    pat = re.compile(r"(?:\[\[?\s+!?\s*-[rwx]\s|\btest\s+!?\s*-[rwx]\s)")
    # scripts/lib/*.sh too: partition.sh and autobar.sh are sourced BY the gate,
    # so a permission test there is a permission test in the gate. The docstring
    # said "anywhere in scripts/", which is how a maintainer reads it; the glob
    # said otherwise, and the audit put an unreviewed `[ -w ]` in both libs with
    # the build green.
    for path in sorted((root / "scripts").glob("*.sh")) + sorted((root / "scripts" / "lib").glob("*.sh")):
        code = [ln for ln in path.read_text(encoding="utf-8").splitlines()
                if not ln.lstrip().startswith("#")]
        # OCCURRENCES, not lines: a line-based count depends on formatting —
        # a guard whose condition wraps across lines would double-count, and a
        # reflow would flip the pin. Measured both ways while writing this.
        n = sum(len(pat.findall(ln)) for ln in code)
        rel = path.relative_to(root).as_posix()
        # Keyed by the RELATIVE path, not the bare name: a `lib/x.sh` and an
        # `x.sh` would otherwise share one allowlist entry and one message.
        allowed = ALLOWED.get(rel, 0)
        if n > allowed:
            problems.append(
                f"{rel}: {n} permission test(s) `[ -r/-w/-x ]` or `test -r/-w/-x` in "
                f"code, allowlist permits {allowed} (#21). A permission test is "
                f"INERT for uid 0 — root bypasses mode bits, and no capability "
                f"probe distinguishes the state (measured). If this new one is a "
                f"complete guard it is wrong; if it is a best-effort half, pair "
                f"it with a test that holds on every uid (`-d` is a type test), "
                f"document the inertness at the call site, and raise the count "
                f"here with that reasoning")
        elif n < allowed:
            problems.append(
                f"{rel}: {n} permission test(s), allowlist expects "
                f"{allowed} — a guard was REMOVED. If deliberate, lower the count "
                f"in check_permission_guards; if not, #19/#27 have regressed")


def check_scripts(root, problems):
    for name in ("ops-init.sh", "ops-verdict.sh", "ops-task.sh",
                 "ops-adopt.sh", "ops-claims.sh", "ops-backlog.sh",
                 "ops-stop-hook.sh", "ops-sessionstart-hook.sh",
                 "statusline.sh", "ops-tiers.sh",
                 "ops-render.sh"):
        p = root / "scripts" / name
        if not p.is_file():
            problems.append(f"scripts/{name}: missing")
            continue
        r = subprocess.run(["bash", "-n", str(p)], capture_output=True, text=True)
        if r.returncode != 0:
            problems.append(f"scripts/{name}: bash syntax error — {r.stderr.strip()}")


def check_reader_bounds(root, problems):
    """
    Every reader of a sentinel/fragment must bound its reads in BYTES —
    `read -r` is bounded by LINES, and one newline-less line gets slurped
    whole (measured 13-33s on a 256MB file; the 32.6s one ran while holding
    the ledger lock, whose budget is 30s). NUL probes must carry a chunk cap.
    """
    # 0.10: the deviation scans moved to scripts/lib/partition.sh (hook) and a
    # tail-window variant (statusline); the counts below are per-file as shipped.
    readers = {
        "ops-verdict.sh": 1,     # the --reconcile fragment loop
        "lib/partition.sh": 1,   # the deviation scan (its NUL probe counts below)
        # The statusline segment renders on a ~300ms timer, the hottest reader
        # in the plugin (a 64MB newline-less sentinel: 0.014s bounded vs 6.20s
        # unbounded — a permanently wedged bar, not a slow one).
        "statusline.sh": 3,      # dev[N] scan + NUL probe + payload field reads
        # The tier-config resolver reads a file under .operator/ (untrusted — a
        # merge or checkout can produce it): a newline-less multi-MB tiers.env
        # is one "line" to an unbounded read.
        "ops-tiers.sh": 1,       # the load_file config loop
        "ops-render.sh": 1,      # the load_file config loop
        # The #103 sweep reads VERDICTS.md (hand-editable, untrusted): one
        # bounded row loop, in a function declaring `local LC_ALL=C` (Copilot
        # review on PR #105 — the first cut read at top level in the caller's
        # locale, so the byte cap was a character cap).
        "ops-reverify.sh": 1,
    }
    # The byte cap's legal range. A bound is only a bound if the number is one
    # a reader can actually be held to: the whole point is that no single read
    # pulls a multi-MB newline-less file into memory. 1MiB is the largest form
    # shipped (ops-verdict.sh's --reconcile row loop, which reads ledger rows);
    # anything above it is a bound in syntax only. Audited 2026-08-25: the old
    # check counted OCCURRENCES of `read -r -n \d+` and never read N, so
    # retyping 512 to 268435456 kept the build green with the statusline's
    # hottest reader effectively unbounded again.
    _MAX_READ_BOUND = 1048576
    for name, expected in readers.items():
        p = root / "scripts" / name
        if not p.is_file():
            continue  # missing-file is already reported by check_scripts
        text = p.read_text(encoding="utf-8")
        # count read-loops over a file, ignoring the stdin payload slurp
        # CODE lines only — the scripts discuss `read -r` at length in their
        # comments, and a checker that fires on its own documentation is worse
        # than no checker: it trains the next maintainer to ignore the build.
        code = [ln for ln in text.splitlines() if not ln.lstrip().startswith("#")]
        # A bounded read counts only when it is an actual read COMMAND with an
        # in-range cap. Audited 2026-08-25, three escapes, all green: an
        # inflated N (268435456 "is" a bound), a `read -r -n 512` inside a
        # string literal in an unrelated helper (the counter asked only whether
        # the text existed), and retyping the loop to `read -r -d $'\n'` so the
        # unbounded scan's `-d` exemption skipped it while the counter stayed
        # satisfied by any text anywhere in the file.
        #
        # The `IFS=` prefix is the discriminator, and it is not a trick: every
        # shipped reader in this plugin writes `IFS= read` or `IFS='|' read`,
        # because a reader of untrusted content MUST disable word-splitting.
        # So the property that makes a read real is the same one that makes it
        # correct, while prose about a read ("use `read -r -n 512` here") never
        # carries it.
        bounded = 0
        # A byte cap is only a byte cap in the C locale. bash `read -n N`
        # counts CHARACTERS outside it, so in UTF-8 a 512-"char" read is up to
        # 2048 bytes and every cap here is 4x looser than it reads — measured
        # on bash 3.2.57 and 5.2.15 (512 chars of "é" = 1024 bytes). Reported
        # once per file: LC_ALL=C must be in scope somewhere, which is the
        # `local LC_ALL=C` idiom partition.sh already uses (Copilot, PR #87).
        if any(re.search(r"\bIFS=\S*\s+read -r -n \d+", ln) for ln in code) \
           and not any("LC_ALL=C" in ln for ln in code):
            problems.append(
                f"scripts/{name}: byte-bounded reads with no `LC_ALL=C` in the "
                f"file — bash counts CHARACTERS outside the C locale, so the "
                f"caps are up to 4x looser than they read on multibyte input. "
                f"Declare `local LC_ALL=C` in the reading function (the idiom "
                f"scripts/lib/partition.sh uses), never globally")
        for ln in code:
            for m in re.finditer(r"\bIFS=\S*\s+read -r -n (\d+)\b", ln):
                n = int(m.group(1))
                if n > _MAX_READ_BOUND:
                    problems.append(
                        f"scripts/{name}: `read -r -n {n}` is not a bound — the cap "
                        f"must be <={_MAX_READ_BOUND} bytes, or one newline-less file is "
                        f"still read whole (the symptom the bound exists to stop: "
                        f"6.20s on a 64MB sentinel against a ~300ms render budget)")
                    continue
                bounded += 1
        unbounded = [
            ln.strip() for ln in code
            if re.search(r"\bread -r\b", ln)
            and not re.search(r"\bread -r -n \d+", ln)
            # The stdin payload slurp is bounded by the payload — but ONLY in
            # its bare `-d ''` form. `read -r -d $'\n'` is a line-delimited
            # read wearing the exemption's clothes: same unbounded behaviour as
            # plain `read -r`, and it was the audit's cleanest escape.
            and not re.search(r"read -r -d ''", ln)
        ]
        if unbounded:
            problems.append(
                f"scripts/{name}: {len(unbounded)} unbounded `read -r` loop(s) — "
                f"use `read -r -n N` (a line cap is not a byte cap; see "
                f"docs/PLAYBOOK.md 'adding a reader of a file'): "
                f"{unbounded[0][:70]}")
        if bounded < expected:
            problems.append(
                f"scripts/{name}: expected >={expected} byte-bounded read(s) "
                f"(`IFS=… read -r -n N`, N<={_MAX_READ_BOUND}), found {bounded} — a reader "
                f"lost its bound. Prose about a read does not count: the audit "
                f"satisfied the old counter with a string literal in a helper")
        # A NUL probe must carry a chunk cap: uncapped, it walks a newline-less
        # multi-MB file end-to-end before detecting the late NUL (66s vs 0.11s
        # on 64MB). Matched on the read FORM, not a variable name — a rename
        # must not carry the probe out of sight.
        nul_probes = [
            i for i, ln in enumerate(code)
            if re.search(r"read -r -d '' -n \d+ \w+", ln)
        ]
        for i in nul_probes:
            # Cap VALUE parsed and bounded (not substring-matched), within the
            # probe block. Legal scales differ: config probes cap at 40 chunks,
            # DECISIONS scans at 4096; ceiling 8192 catches the effectively-
            # uncapped.
            window = "\n".join(code[i:i + 4])
            cap = re.search(r"-le (\d+)\b", window)
            if not cap or int(cap.group(1)) > 8192:
                got = cap.group(1) if cap else "none"
                problems.append(
                    f"scripts/{name}: NUL probe at code line {i + 1} has no "
                    f"chunk cap (a counter with `-le N`, N<=8192; got {got}) — "
                    f"an uncapped `read -d ''` loop walks a multi-MB file "
                    f"end-to-end and stalls the reader (see ops-stop-hook.sh "
                    f"sentinel_owner for the canonical bounded form)")


# The #89 metacharacter arm, in FULL — matching the canonical shell text
# `*'$'* | *'`'* | *"'"* | *'"'* | *\\*)`. All five alternatives are required
# (Copilot review on PR #97): a `$`-only pin accepted an arm that dropped the
# backtick/quote/backslash rejections, and any one surviving metacharacter
# rebuilds the unclearable foreign-owner shape. The site-specific polarity
# (die / printf-degrade / continue) is appended at each use.
_METACHAR_ARM = (
    r"\*'\$'\*\s*\|\s*"
    r"\*'`'\*\s*\|\s*"
    r"\*\"'\"\*\s*\|\s*"
    r"\*'\"'\*\s*\|\s*"
    r"\*\\\\\*\)"
)


def check_guard_parity(root, problems):
    """The gate CLIs (and the shared partition lib) must agree on what a name
    may contain. `check_bare_name` (filename safety) and `check_owner_name`
    (owner-vs-session-id) are deliberately separate — conflating them wedged
    every pre-0.4 task whose id contained a space."""
    clis = ("ops-task.sh", "ops-verdict.sh", "ops-adopt.sh")
    for name in clis:
        p = root / "scripts" / name
        if not p.is_file():
            continue
        text = shell_code(p)
        for fn in ("check_bare_name", "check_owner_name"):
            if f"{fn}()" not in text:
                problems.append(
                    f"scripts/{name}: missing {fn}() — all three CLIs must "
                    f"carry both guards (see docs/PLAYBOOK.md)")
        # the leading-dot rule: a dotfile sentinel is invisible to the hook's glob
        if ".*)" not in text:
            problems.append(
                f"scripts/{name}: no leading-dot rejection — a dotfile sentinel "
                f"is invisible to the Stop hook's glob, so the gate never sees it")
        # The `__` separator rule, scoped to check_bare_name's body: `*__*`
        # appears in real reader code, so a file-wide search is satisfied by a
        # reader, not the guard (F30).
        body = _function_body(text, "check_bare_name")
        if body is None:
            problems.append(
                f"scripts/{name}: cannot locate check_bare_name()'s body — the "
                f"`__`-separator pin has nothing to check. Reshaping the guard "
                f"must update this locator, not silently skip it")
        elif _report_if_redefined(body, f"scripts/{name}", problems):
            pass
        elif "*__*" not in body:
            problems.append(
                f"scripts/{name}: check_bare_name() does not reject '__' — it "
                f"separates owner from task in the sentinel name, so an owner or "
                f"task-id containing it makes every reader's first-`__` split "
                f"parse a name our own writers could never have built (PR #77 "
                f"review; the arm must match ops-task.sh's copy)")
        # audit F128: presence is not effect. The pins above prove the guard
        # EXISTS and its arms are spelled; nothing proved an arm still DIES —
        # `.*) :;;` kept every presence pin green while the guard waved the
        # dotfile through. Pin the arm's action, per writer CLI.
        if body and not isinstance(body, _RedefinedFunction):
            if not re.search(r"\.\*\)\s*die\b", body):
                problems.append(
                    f"scripts/{name}: check_bare_name()'s `.*)` arm does not "
                    f"invoke die — a neutered arm accepts a dotfile sentinel, "
                    f"which is invisible to the Stop hook's glob, with every "
                    f"presence pin green (audit F128: pin the effect, not the "
                    f"arm's existence)")
        obody = _function_body(text, "check_owner_name")
        if obody is None:
            problems.append(
                f"scripts/{name}: cannot locate check_owner_name()'s body — "
                f"the F128 arm-effect pins have nothing to check. Reshaping "
                f"the guard must update this locator, not silently skip it")
        elif _report_if_redefined(obody, f"scripts/{name}", problems):
            pass
        else:
            # the whitespace arm: an owner that can never equal a real session
            # id makes its task permanently unblockable.
            if not re.search(r"\*\[\[:space:\]\]\*\)\s*die\b", obody):
                problems.append(
                    f"scripts/{name}: check_owner_name() has no "
                    f"`*[[:space:]]*)` arm invoking die — a whitespace owner "
                    f"can never match a real session id, so its task is "
                    f"permanently non-blocking (audit F128)")
            # the #89 metacharacter arm: a literal `$S` reads as a FOREIGN
            # session at every reader, so its HANDOFF-MARK clears nothing.
            # ALL FIVE alternatives, not just `$` (Copilot review on PR #97):
            # a uniform edit dropping backtick/quote/backslash while keeping
            # `*'$'*` stayed green, and any one surviving metacharacter
            # rebuilds the same foreign-owner shape.
            if not re.search(_METACHAR_ARM + r"\s*die\b", obody):
                problems.append(
                    f"scripts/{name}: check_owner_name() has no complete "
                    f"`*'$'* | *'`'* | *\"'\"* | *'\"'* | *\\\\*` "
                    f"metacharacter arm invoking die (#89) — every one of the "
                    f"five must be refused; an unexpanded shell variable "
                    f"passed as --owner reads as a valid foreign session, "
                    f"strictly worse than not running the command (audit F128)")
        # EXECUTE both guards (audit F144, the F140 shape applied to the name
        # guards). Every pin above is a substring test on the body, and the
        # pin-auditor measured the escape they cannot see: a dead `?*) :` arm
        # inserted BEFORE the intact `.*) die` arm. `case` takes the FIRST
        # matching arm and `?*` matches every non-empty string, so all four
        # rejections stop happening while `.*)`, `*__*`, the metacharacter set
        # and their `die`s are all still spelled out on the page — "all
        # contracts hold" (measured 2026-09-02 on ops-task.sh). Behaviour, not
        # spelling: run the shipped functions in a child bash against one probe
        # per rule. A dead arm, an early `return`, a wrapping `if false` all
        # fail here; none of them can fail a substring test.
        _bb = re.search(r'^check_bare_name\(\)\s*\{.*?^\}', text, re.M | re.S)
        _ob = re.search(r'^check_owner_name\(\)\s*\{.*?^\}', text, re.M | re.S)
        if not _bb or not _ob:
            problems.append(
                f"scripts/{name}: cannot extract check_bare_name()/"
                f"check_owner_name() for the executable probe (audit F144) — "
                f"reshaping either must update this extractor, not silently "
                f"skip the only pin that tests the guards' EFFECT")
        else:
            # Our own die/NL, so the probe tests the guard's arms and not the
            # rest of the CLI. die's exit code is what "refused" means here —
            # EXACTLY 9, never merely non-zero. `!= 0` was the first cut and it
            # was vacuous in the same way as the pins it replaced (PR review of
            # e8e0179): renaming the arms' `die` to an undefined `refuse` makes
            # bash exit 127, which read as "refused" while the CLI itself would
            # die on `command not found` at every call — "all contracts hold"
            # (measured). rc 127 means the harness is INCOMPLETE, not that the
            # guard works, and the two must never be conflated. Matches the
            # F140 claims probe, which has compared exact codes from the start.
            #
            # ops-verdict.sh factors the `|`/newline arms out into check_cell
            # and calls it from check_bare_name, so the harness carries that
            # helper too when the CLI defines one. Carried by SHAPE, not by
            # name-list: a helper this extractor omitted would make every probe
            # exit 127, which is now its own reported finding.
            _DIE = 9
            _pre = ("die() { exit 9; }\nNL=\"$(printf '\\nx')\"; NL=\"${NL%x}\"\n")
            _helpers = "".join(
                _h.group(0) + "\n" for _fn in ("check_cell",)
                for _h in [re.search(rf'^{_fn}\(\)\s*\{{.*?^\}}', text, re.M | re.S)]
                if _h)
            _harness = _pre + _helpers + _bb.group(0) + "\n" + _ob.group(0) + "\n"
            # (value, must-be-refused, the rule it proves)
            _bare = (("a/b", "'/' would let a later rm -f escape .operator/"),
                     (".hidden", "a dotfile sentinel is invisible to the hook's glob"),
                     ("a|b", "'|' breaks the 4-cell ledger row"),
                     ("a\nb", "a newline breaks the 4-cell ledger row"),
                     ("a__b", "'__' is the owner/task separator"))
            for _call, _probes in (
                    ('check_bare_name t "$1"', _bare),
                    ('check_owner_name "$1"',
                     (("a b", "a padded owner is permanently foreign"),
                      ("$S", "an unexpanded variable reads as a foreign session (#89)"),
                      ("`x`", "a backtick owner is an unexpanded substitution (#89)"),
                      ("a'b", "a quote is an unexpanded-variable tell (#89)"),
                      ('a"b', "a quote is an unexpanded-variable tell (#89)"),
                      ("a\\b", "a backslash is an unexpanded-variable tell (#89)")))):
                _fn = _call.split("(")[0].split()[0]
                for _v, _why in _probes:
                    _r = _run_probe(["bash", "-c", _harness + _call, "_", _v],
                                    problems, f"scripts/{name}: {_fn}()")
                    if _r is None:
                        break  # already reported; do not also claim ACCEPTS
                    if _r.returncode == 0:
                        problems.append(
                            f"scripts/{name}: {_fn}() ACCEPTS {_v!r} when "
                            f"executed — {_why}. The pinned arms may all be "
                            f"present while the guard refuses nothing: a `?*)` "
                            f"arm before them takes every match first, and no "
                            f"substring test can see that (audit F144)")
                    elif _r.returncode != _DIE:
                        problems.append(
                            f"scripts/{name}: {_fn}() exited {_r.returncode} on "
                            f"{_v!r}, not via die ({_DIE}) — {(_r.stderr or '').strip()[:90]!r}. "
                            f"A non-die failure is the harness or the arm being "
                            f"BROKEN, not the guard refusing: rc 127 (an arm "
                            f"calling a command that does not exist) would count "
                            f"as a refusal under a bare `!= 0` test while the "
                            f"real CLI dies at every call (audit F144)")
            # The controls: a guard that refuses EVERYTHING passes every
            # rejection probe above while wedging the CLI for real ids. Both
            # halves, since check_owner_name delegates to check_bare_name.
            for _fn, _v in (("check_bare_name t", "task-1"),
                            ("check_owner_name", "b3f1c2d4-5a6b-7c8d")):
                _r = _run_probe(["bash", "-c", _harness + _fn + ' "$1"', "_", _v],
                                problems, f"scripts/{name}: {_fn.split()[0]}()")
                if _r is None:
                    continue
                if _r.returncode != 0:
                    problems.append(
                        f"scripts/{name}: {_fn.split()[0]}() REFUSES the "
                        f"ordinary name {_v!r} (rc {_r.returncode}) — a guard "
                        f"that refuses everything passes every rejection test "
                        f"and makes the CLI unusable (audit F144 control)")
    # the readers' parser (lib/partition.sh since 0.10) must reject what the
    # writers reject, or a hand-written sentinel reads as a valid foreign owner
    # and the gate opens
    lib = root / "scripts" / "lib" / "partition.sh"
    if lib.is_file():
        text = shell_code(lib)
        if "[[:space:]]" not in text:
            problems.append(
                "scripts/lib/partition.sh: sentinel_owner does not reject "
                "[[:space:]] "
                "whitespace owners — an owner that can never match a real "
                "session id makes its task permanently non-blocking")
    # The #89 metacharacter arm at the READER and MIGRATION sites (Copilot
    # review on PR #97: the F128 arm-effect pins covered only the three
    # writers' check_owner_name, but the arm belongs at all SIX sites — a
    # reader that accepts what the writers refuse reads a planted `$S__task`
    # as a valid FOREIGN owner, and the measured result was Stop rc 0 on a
    # real open task, reached through the migration path no writer guard can
    # see). Readers DEGRADE to unowned (fails closed: `printf '\n'`), the
    # migration REFUSES the rename (`continue`) — pin each site's own
    # polarity, never `die`.
    for name, fn in (("lib/partition.sh", "sentinel_owner_of_name"),
                     ("ops-verdict.sh", "sentinel_owner_of_name")):
        p = root / "scripts" / name
        if not p.is_file():
            continue
        rbody = _function_body(shell_code(p), fn)
        if rbody is None:
            problems.append(
                f"scripts/{name}: cannot locate {fn}()'s body — the #89 "
                f"reader-arm pin has nothing to check. Reshaping the parser "
                f"must update this locator, not silently skip it")
        elif _report_if_redefined(rbody, f"scripts/{name}", problems):
            # audit F143: this branch used to `pass` with a comment claiming
            # another site reports the redefinition — none did for the lib, so
            # a second sentinel_owner_of_name() with no reject set shipped
            # "all contracts hold" (bash resolves the LAST definition).
            pass
        elif not re.search(_METACHAR_ARM + r"\s*printf\s+'\\n'", rbody):
            problems.append(
                f"scripts/{name}: {fn}() has no complete metacharacter arm "
                f"(all five of `$` backtick `'` `\"` `\\`) degrading to "
                f"unowned (#89) — a reader accepting what the writers refuse "
                f"reads a planted `$S__task` as a valid foreign owner and the "
                f"gate opens (audit F128, reader half)")
    ss = root / "scripts" / "ops-sessionstart-hook.sh"
    if ss.is_file():
        sscode = shell_code(ss)
        if not re.search(_METACHAR_ARM + r"\s*continue\b", sscode):
            problems.append(
                "scripts/ops-sessionstart-hook.sh: the legacy-sentinel "
                "migration has no complete metacharacter arm (all five of "
                "`$` backtick `'` `\"` `\\`) refusing the rename (#89) — a "
                "body reading `session_id: $S` migrates to `$S__task`, which "
                "both parsers then read as a valid foreign owner (audit "
                "F128, migration half)")
    # audit F136 (2026-09-02): the CLIs resolve a task id to its sentinel with
    # the glob `*__<id>`, and `*` spans a `__` — so a planted `A__B__C`
    # matched id `C` at every CLI while the hook (first-`__` split) called the
    # same file MALFORMED: ops-task reported a never-opened task "already
    # open" (rc 0), ops-adopt RENAMED the malformed file into a well-formed
    # one. Each lookup now filters on the TASK HALF of the match; the filter
    # is a guard like any other, and one site without it is the drift that
    # ships green (F30), so every site is pinned by its own literal.
    _task_half_re = re.compile(
        r'_n="\$\{_f##\*/\}";\s*\[\s*"\$\{_n#\*__\}"\s*=\s*"\$_t"\s*\]\s*\|\|\s*continue')
    for name, fn in (("ops-task.sh", "sentinel_for"),
                     ("ops-verdict.sh", "sentinel_path"),
                     ("ops-adopt.sh", "sentinel_path")):
        p = root / "scripts" / name
        if not p.is_file():
            continue
        lbody = _function_body(shell_code(p), fn)
        if lbody is None:
            problems.append(
                f"scripts/{name}: cannot locate {fn}()'s body — the F136 "
                f"task-half pin has nothing to check. Reshaping the lookup "
                f"must update this locator, not silently skip it")
        elif _report_if_redefined(lbody, f"scripts/{name}", problems):
            pass
        elif not _task_half_re.search(lbody):
            problems.append(
                f"scripts/{name}: {fn}() resolves `*__<id>` without checking "
                f"the task half of the match (`_n=\"${{_f##*/}}\"; "
                f"[ \"${{_n#*__}}\" = \"$_t\" ] || continue`) — the glob's `*` "
                f"spans a `__`, so a planted A__B__C resolves as task C here "
                f"while the Stop hook calls it MALFORMED (audit F136)")
    tp = root / "scripts" / "ops-task.sh"
    if tp.is_file() and not re.search(
            r'_dn="\$\{_dup##\*/\}";\s*\[\s*"\$\{_dn#\*__\}"\s*=\s*"\$ID"\s*\]\s*\|\|\s*continue',
            shell_code(tp)):
        problems.append(
            "scripts/ops-task.sh: the post-rename duplicate loop resolves "
            "`*__$ID` without checking the task half of the match "
            "(`_dn=\"${_dup##*/}\"; [ \"${_dn#*__}\" = \"$ID\" ] || continue`) — "
            "a planted A__B__$ID reads as a racing duplicate and the opener "
            "dies AFTER creating the sentinel (audit F136, the fourth site)")
    # The -L symlink rejection: the opener plus every sentinel reader (`-f`
    # follows a planted symlink; F65/F66). The Stop hook's pending/ enumeration
    # lives in lib/partition.sh since 0.10, so its obligation moved there.
    for name in ("ops-task.sh", "ops-verdict.sh", "ops-adopt.sh",
                 "statusline.sh", "lib/partition.sh"):
        p = root / "scripts" / name
        if not p.is_file():
            continue
        code = [ln for ln in p.read_text(encoding="utf-8").splitlines()
                if not ln.lstrip().startswith("#")]
        if not any(re.search(r"(!\s+-L|-L\s+\S)", ln) for ln in code):
            problems.append(
                f"scripts/{name}: no symlink (-L) rejection — `-f` follows a "
                f"planted symlink in pending/, laundering an entry our CLIs "
                f"never wrote into a trusted sentinel (F65/F66; the guard "
                f"must live at every reader, see docs/PLAYBOOK.md)")
    # F2: an -L test must guard the verdicts.d fragment path at the write and
    # both read sites — a planted symlink there launders every row for that
    # owner into an arbitrary file, exit 0 silent (F65 class).
    p = root / "scripts" / "ops-verdict.sh"
    if p.is_file():
        text = p.read_text(encoding="utf-8")
        code = [ln for ln in text.splitlines() if not ln.lstrip().startswith("#")]
        # FRAGDIR is the verdicts.d path variable; the reads hold it in $frag.
        guarded = sum(1 for ln in code
                      if "-L" in ln and ("FRAGDIR" in ln or "frag" in ln))
        if guarded < 3:
            problems.append(
                "scripts/ops-verdict.sh: verdicts.d/ is missing the F2 -L "
                "symlink guard — expected an -L test on a FRAGDIR/verdicts.d "
                "fragment path at the append_fragment write and both read "
                "sites (--reconcile + retro_gate), found "
                f"{guarded}/3. A planted symlink at verdicts.d/<owner>.md "
                f"launders every verdict row into an arbitrary file, exit 0, "
                f"silent (F65 class; F2)")
    # F17: the two fragment scanners must use the SAME read bound — uniform
    # drift between copy-paste neighbors silently drops long rows (#9 class).
    p = root / "scripts" / "ops-verdict.sh"
    if p.is_file():
        code = [ln for ln in p.read_text(encoding="utf-8").splitlines()
                if not ln.lstrip().startswith("#")]
        # Locate the two verdicts.d/ fragment read loops. Each is a
        # `read -r -n N row|line` loop whose body is drained by `done < "$frag"`
        # (sentinel_owner's pending/ read drains `done < "$f"`, so it never
        # matches). The reconcile loop iterates `row`; retro_gate iterates
        # `line`. Walk forward from each candidate read to its redirect.
        frag_reads = []
        for i, ln in enumerate(code):
            m = re.search(r"read -r -n (\d+) (row|line)\b", ln)
            if not m:
                continue
            var = m.group(2)
            if any(re.search(r'done < "\$frag"', code[j]) for j in range(i, min(i + 40, len(code)))):
                frag_reads.append((var, int(m.group(1))))
        by_var = {v: b for v, b in frag_reads}
        if "row" in by_var and "line" in by_var:
            if by_var["row"] != by_var["line"]:
                problems.append(
                    "scripts/ops-verdict.sh: the --reconcile and retro_gate "
                    "fragment scanners disagree on the `read -r -n` bound "
                    f"({by_var['row']} vs {by_var['line']}) — a long evidence "
                    f"cell (>512B) splits into chunks at one site but not the "
                    f"other, silently dropping honest rows from the ledger on "
                    f"reconcile (issue-#9 class; F17)")
        elif "line" not in by_var:
            problems.append(
                "scripts/ops-verdict.sh: cannot locate retro_gate's fragment "
                "scan — F17 parity pin could not be applied (report, not skip)")
        if "row" not in by_var:
            # #114: the elif above reported only the retro_gate half. A missing
            # --reconcile `row` scanner said NOTHING — the parity pin applied to
            # half a comparison, and half a comparison is satisfied by deleting
            # the other half.
            problems.append(
                "scripts/ops-verdict.sh: cannot locate --reconcile's fragment "
                "scan — the F17 parity pin cannot be applied to a comparison "
                "with a missing side (report, not skip; #114)")

    # F14: the hooks' json_get() must coerce JSON booleans to "true"/"false" —
    # a bare print(v) renders Python True/False and every `= "true"` test
    # silently fails. Pinned in the body, not a whole-file substring (F30).
    for name in ("ops-sessionstart-hook.sh", "ops-stop-hook.sh"):
        p = root / "scripts" / name
        if not p.is_file():
            continue
        text = p.read_text(encoding="utf-8")
        # Extract the json_get() body: from its definition to the closing brace
        # on its own line. Strip comment lines so a comment-only marker does
        # not satisfy the pin.
        body = ""
        m = re.search(r"json_get\(\)", text)
        if m:
            tail = text[m.start():]
            bl = []
            for ln in tail.splitlines():
                bl.append(ln)
                if ln.strip() == "}" and len(bl) > 1:
                    break
            body = "\n".join(ln for ln in bl if not ln.lstrip().startswith("#"))
        # The WHOLE condition line, not the substring. `"isinstance(v, bool)"
        # in body` was satisfied by `if False and isinstance(v, bool):` — the
        # literal present, the coercion unreachable. Measured: validator green,
        # 193 python green, 683 bash green (#86 pin audit, GN8). This checker's
        # own comment already claimed "a comment-only marker does not satisfy",
        # and the comment-stripping above delivers exactly that — it defended
        # the COMMENT form of the mention while the DEAD-CODE form walked past,
        # inside the guard written against mentions.
        # Parse it, do not pattern-match it. A blacklist of dead spellings is
        # the same defect one level up: `if False and …` blocked, `if 1 == 2
        # and …` through, and a pin that suggests coverage it lacks is exactly
        # what this fix is for. Two live forms are legitimate — the hooks write
        # `if isinstance(v, bool):`, a compact json_get writes the ternary — so
        # the test is whether the coercion can REACH a print, not how it is
        # spelled. ast.literal_eval-style constant folding is not needed: a
        # literally-false guard is a Constant node, and anything cleverer than
        # that is not a maintainer's reflex fix.
        live = False
        prog = _embedded_python(body)
        if prog is None:
            live = "isinstance(v, bool)" in body   # unparseable: fall back
        else:
            for node in ast.walk(prog):
                if not _is_bool_isinstance(node):
                    continue
                if not _under_dead_guard(node, prog):
                    live = True
                    break
        if not live:
            problems.append(
                f"scripts/{name}: json_get() has no REACHABLE "
                f"isinstance(v, bool) coercion — a JSON boolean renders "
                f"Python True/False and a downstream '= \"true\"' test silently "
                f"never matches (F14; the three hooks' json_get helpers must "
                f"agree). The body is PARSED, not grepped: a comment, or a "
                f"branch a constant makes unreachable (`if False and …`), "
                f"leaves the literal present and the coercion dead")



def check_autobar(root, problems):
    """The auto-arm rule (#85): the invariants that fail SILENTLY.

    Each pin here exists because the regression it catches leaves every other
    gate green and the armer merely stops working — or, worse, wedges a
    session that can then never stop.
    """
    p = root / "scripts" / "lib" / "autobar.sh"
    if not p.is_file():
        problems.append(
            "scripts/lib/autobar.sh is missing — the auto-arm rule is the only "
            "thing making the evidence gate non-optional (#85); ops-stop-hook.sh "
            "sources it and would fail to launch without it")
        return
    code = shell_code(p)

    # (a) NUL-safe read. `$(git status --porcelain -z)` DELETES the NULs
    # (measured, bash 3.2.57: three entries counted as 0) so the armer silently
    # never fires. The `< <(…)` form is the fix and the thing that must not be
    # "simplified" back into a command substitution or a pipe (a pipe puts the
    # loop in a subshell and loses the count).
    body = _function_body(code, "autobar_count_changed")
    if body is None:
        problems.append(
            "scripts/lib/autobar.sh: cannot locate autobar_count_changed()'s "
            "body — the NUL-safety pin has nothing to check. Reshaping it must "
            "update this locator, not silently skip the pin")
    elif _report_if_redefined(body, "scripts/lib/autobar.sh", problems):
        pass
    else:
        if "-z" not in body:
            problems.append(
                "scripts/lib/autobar.sh: autobar_count_changed does not pass "
                "`-z` to git status — the default output QUOTES a path with a "
                "space and prints a rename as `old -> new` on one line, so the "
                "count is wrong in both directions")
        # audit F132: -uall is as load-bearing as -z and had no pin. Without
        # it porcelain reports an untracked DIRECTORY as one record, so a
        # session scaffolding N new files under one new dir counts 1 and the
        # armer never fires on exactly the multi-file shape being gated.
        if "-uall" not in body:
            problems.append(
                "scripts/lib/autobar.sh: autobar_count_changed does not pass "
                "`-uall` to git status — porcelain's default collapses an "
                "untracked directory into ONE record, so N new files under a "
                "new dir count 1 and the >=2-paths threshold never trips on "
                "the common shape of the very thing being gated (audit F132)")
        if "< <(" not in body:
            problems.append(
                "scripts/lib/autobar.sh: autobar_count_changed does not read "
                "through process substitution `< <(…)`. Command substitution "
                "DELETES NUL bytes (measured, bash 3.2.57: a three-entry -z "
                "porcelain counted 0, silently) and a pipe puts the loop in a "
                "subshell that loses the count — either way the armer never fires")
        if "rev-parse" not in body:
            problems.append(
                "scripts/lib/autobar.sh: autobar_count_changed has no separate "
                "`git rev-parse` repo check — process substitution carries no "
                "exit status, so without it `not a repo` and `clean repo` both "
                "arrive as zero records and unmeasured reads as clean")
        # EXECUTE the counter (audit F144, the F140 shape). Every pin above is
        # a substring test on the body, and shell_code() strips only WHOLE-line
        # comments — so moving a flag into a trailing comment keeps the literal
        # in the body while removing it from the command. Measured 2026-09-02:
        # `status --porcelain -z -- # -uall ':(exclude).operator'` shipped "all
        # contracts hold" with `-uall` pinned, the pathspec commented out, and
        # the counter reading the WHOLE tree. Run it against a real repo
        # instead: N files under one new dir must count N (that is -uall), and
        # a change under .operator/ must count 0 (that is the pathspec, which
        # had no pin at all — a counter that sees its own sentinel writes arms
        # on its own bookkeeping).
        _fn = re.search(r'^autobar_count_changed\(\)\s*\{.*?^\}', code, re.M | re.S)
        if not _fn:
            problems.append(
                "scripts/lib/autobar.sh: cannot extract autobar_count_changed() "
                "for the executable probe (audit F144) — reshaping it must "
                "update this extractor, not silently skip the only pin that "
                "tests the counter's EFFECT")
        else:
            with tempfile.TemporaryDirectory() as _td:
                # The scratch repo must be ISOLATED from the developer's git
                # configuration, or the probe measures their machine instead of
                # this code. Measured (PR review of e8e0179): a global
                # `core.excludesFile` listing `newdir/` made the counter report
                # 0 and the validator FAIL against a correct autobar.sh — a
                # false positive on a build gate, which trains the maintainer
                # to ignore it. GIT_CONFIG_GLOBAL/SYSTEM=/dev/null is the
                # documented off switch; the identity vars avoid needing
                # `git config` at all (no commit is made, but a future edit
                # might), and GIT_CEILING keeps a stray walk inside the tempdir.
                _env = dict(os.environ,
                            GIT_CONFIG_GLOBAL=os.devnull,
                            GIT_CONFIG_SYSTEM=os.devnull,
                            GIT_CONFIG_NOSYSTEM="1",
                            GIT_CEILING_DIRECTORIES=_td,
                            GIT_AUTHOR_NAME="p", GIT_AUTHOR_EMAIL="p@t",
                            GIT_COMMITTER_NAME="p", GIT_COMMITTER_EMAIL="p@t")
                _probe = (
                    'set -e\n'
                    f'cd "{_td}"\n'
                    'git init -q . 2>/dev/null\n'
                    'mkdir -p newdir .operator\n'
                    'printf x > newdir/a; printf x > newdir/b; printf x > newdir/c\n'
                    'printf x > .operator/ignored\n'
                    + _fn.group(0) + '\n'
                    f'autobar_count_changed "{_td}"\n'
                    'echo "$autobar_paths $autobar_measured"\n')
                _r = _run_probe(["bash", "-c", _probe], problems,
                                "scripts/lib/autobar.sh: autobar_count_changed()",
                                env=_env)
                _got = (_r.stdout or "").strip().split() if _r else []
                if _r is None:
                    pass  # _run_probe already reported why; do not double-report
                elif _r.returncode != 0 or len(_got) != 2:
                    problems.append(
                        f"scripts/lib/autobar.sh: autobar_count_changed() could "
                        f"not be executed (rc {_r.returncode}: "
                        f"{(_r.stderr or _r.stdout or '').strip()[:160]!r}) — the "
                        f"F144 behaviour probe cannot report, so treat it as a "
                        f"failure rather than a skip")
                elif _got[1] != "1":
                    problems.append(
                        "scripts/lib/autobar.sh: autobar_count_changed() left "
                        "autobar_measured=0 on a real git repo — the armer reads "
                        "unmeasured as 'clean' and never fires (audit F144)")
                elif _got[0] != "3":
                    problems.append(
                        f"scripts/lib/autobar.sh: autobar_count_changed() counted "
                        f"{_got[0]} for 3 new files under ONE new directory plus "
                        f"one .operator/ write (expected 3) — either `-uall` is "
                        f"not reaching git (porcelain collapses the dir to one "
                        f"record, so the >=2 threshold never trips on the shape "
                        f"being gated) or the `':(exclude).operator'` pathspec is "
                        f"not (the counter then arms on its own sentinel writes). "
                        f"A flag moved into a TRAILING comment keeps every "
                        f"substring pin green and still fails here (audit F144)")

    # (b) the infinite-block guard. Recording a verdict does not un-change the
    # files, so an arm with no session marker re-fires at every Stop forever.
    for fn in ("autobar_already_armed", "autobar_mark_armed"):
        if f"{fn}()" not in code:
            problems.append(
                f"scripts/lib/autobar.sh: missing {fn}() — without the "
                f"once-per-session marker the armer re-arms after every verdict "
                f"(recording one does not un-change the files) and the session "
                f"can NEVER stop, which is worse than stopping unaudited")
    decide = _function_body(code, "autobar_decide")
    if decide is None:
        problems.append(
            "scripts/lib/autobar.sh: cannot locate autobar_decide()'s body — "
            "the already-armed and suppression pins have nothing to check")
    elif _report_if_redefined(decide, "scripts/lib/autobar.sh", problems):
        pass
    else:
        if "autobar_already_armed" not in decide:
            problems.append(
                "scripts/lib/autobar.sh: autobar_decide never calls "
                "autobar_already_armed — the marker exists but nothing reads "
                "it, so every Stop re-arms (the wedge in (b))")
        # (c) the suppression rule is GONE and must stay gone — this pin is
        # INVERTED from the one that shipped with #85, and the inversion is the
        # point. Two suppression signals were tried; both made ONE stale
        # artifact (an append-only fragment, then an abandoned sentinel from a
        # crashed or /clear'd session) darken the armer for the rest of the
        # project's life. Splitting "working" from "died" needs a liveness
        # oracle the filesystem does not carry: a sentinel holds no pid, a pid
        # would be dead anyway (ops-task.sh exits at CLI return while the owning
        # session runs), a session is a harness token with no OS handle, and
        # bash 3.2's whole-second mtime cannot separate stale from concurrent.
        # Re-adding suppression is the reflex fix when a shared worktree arms an
        # innocent session — and it trades a bounded, self-clearing false
        # positive for a permanent silent disarm. Do not.
        if "autobar_foreign_activity" in decide:
            problems.append(
                "scripts/lib/autobar.sh: autobar_decide calls "
                "autobar_foreign_activity — foreign-presence suppression was "
                "REMOVED (#85 follow-up) and must not come back. An OPEN "
                "foreign sentinel means 'working OR died' and nothing here can "
                "tell those apart, so one abandoned sentinel disarmed the gate "
                "permanently. The shared-worktree false positive it was meant "
                "to prevent is bounded (one arm per session, cleared by one "
                "--defer) and announced on the blocking channel; the disarm was "
                "neither. Reopen only with a liveness signal the kernel can "
                "answer for a SESSION")

    # The lib must actually be SOURCED by the hook. The pin matches the source
    # STATEMENT, not the bare filename: `"autobar.sh" in hcode` was satisfied by
    # any mention, so replacing the source line with `echo 'autobar.sh disabled'`
    # shipped 0 problems (#86 review) while the hook died at runtime — set -u
    # aborts on autobar_arm one line later, and exit 1 is not exit 2, so the
    # Stop is ALLOWED and the deviation gate below it never runs either.
    hook = root / "scripts" / "ops-stop-hook.sh"
    if hook.is_file():
        hcode = shell_code(hook)
        # A source STATEMENT: `.` or `source`, then a path whose FILENAME is
        # autobar.sh. Deliberately not pinned to "$_libdir/…" — the shape is
        # the hook's business, and a pin that only matches today's spelling
        # turns a harmless refactor into a build failure. What it must NOT
        # match is a bare mention (an echo, a comment, a message string) or a
        # different file wearing the name as a SUFFIX — `\S*autobar\.sh` let
        # `fakeautobar.sh` satisfy the pin (Copilot review on PR #97, same
        # class as the partition src_re one function over): the filename sits
        # at a path boundary, prefix optional and `/`-terminated.
        src_re = re.compile(
            r'^\s*(?:\.|source)\s+("?)(?:\S*/)?autobar\.sh\1(?:\s+#.*)?\s*$',
            re.MULTILINE)
        if not src_re.search(hcode):
            problems.append(
                "scripts/ops-stop-hook.sh: does not SOURCE lib/autobar.sh (a "
                "mention is not a source) — the auto-arm rule exists but "
                "nothing runs it, so the evidence gate is opt-in again (#85). "
                "At runtime set -u aborts the hook on autobar_arm, and exit 1 "
                "is not exit 2, so Stop is allowed and the deviation gate never "
                "runs — with every other gate green")
        else:
            # Order still pinned, but NOT for the reason this check shipped
            # with: autobar.sh called sentinel_owner_of_name only until e839490
            # deleted the suppression rule, and `grep -c` in autobar.sh is now
            # 0. The libs share no symbol today. What remains is the hook's own
            # shape — autobar_decide runs before scan_pending so an armed
            # sentinel is picked up by the SAME mine-pending branch in the same
            # fire, which is the seam #85 was built on. Keep the order; do not
            # restate the deleted dependency as its reason.
            ai, pi = hcode.find("autobar.sh"), hcode.find("partition.sh")
            if pi == -1 or ai < pi:
                problems.append(
                    "scripts/ops-stop-hook.sh: lib/autobar.sh is sourced before "
                    "lib/partition.sh. They share no symbol (autobar stopped "
                    "calling sentinel_owner_of_name at e839490), but the hook "
                    "arms before scan_pending so the armed sentinel is read by "
                    "the existing mine-pending branch in the same fire. Source "
                    "partition.sh first and keep that seam intact")

    # The markers must be wiped at SessionStart: a stale one for a reused id
    # disarms a future session permanently.
    ss = root / "scripts" / "ops-sessionstart-hook.sh"
    if ss.is_file() and ".autobar" not in shell_code(ss):
        problems.append(
            "scripts/ops-sessionstart-hook.sh: does not wipe .operator/.autobar/ "
            "— a marker left by a session that no longer exists keeps a future "
            "session reusing that id from ever arming (#85)")


def check_claims(root, problems):
    r"""ops-claims.sh protected-set parity (F30 lesson + F-A2).

    The C3 gate-trespass check ("the builder cannot edit its own grader") only
    means anything if the protected set is BOTH declared AND applied. F30 proved
    that four-way copy parity is insufficient: uniform drift reads as "in parity"
    while four files are identically broken. So, like the tier-namespace check,
    the literal is pinned to a canonical value AND its application at a call site
    is required. Drop a protected path from the literal, or neuter the call site
    (comment it out / rename the matcher), and the build fails.

    `statusline.sh` is in the set per the F66 amendment: it is a full sentinel
    reader bound by gate semantics, so a worker weakening its parser re-opens a
    laundering path invisibly — and no prior glob covered it.

    `backlog/` is in the set per B7 (backlog-charter spec): an implementer that
    can edit backlog/tasks/*.md can edit the acceptance criteria it is judged
    against — the F48 vacuous-guard class relocated to the plan layer, harder to
    spot than a weakened validator. The whole directory (no notes carve-out);
    the escape needs a parser for the neighbour's grammar, which B5 forbids.
    """
    p = root / "scripts" / "ops-claims.sh"
    if not p.is_file():
        return  # missing-file is already reported by check_scripts
    text = p.read_text(encoding="utf-8")
    # The canonical protected set — must byte-match the PROTECTED= literal in
    # ops-claims.sh. A divergence here is two different ideas of "the grader".
    literal = _single_assignment(text, r'^PROTECTED="(.*)"$',
                                 "scripts/ops-claims.sh", "PROTECTED", problems)
    canonical = ("scripts/validate_plugin.py tests/ .operator/bin/ hooks/ "
                 "scripts/ops-*.sh scripts/statusline.sh backlog/")
    if not literal:
        problems.append(
            "scripts/ops-claims.sh: PROTECTED literal not found — the "
            "gate-trespass protected set must be a single declared literal "
            "(F-A2: the builder cannot edit its own grader)")
    elif literal != canonical:
        problems.append(
            f"scripts/ops-claims.sh: PROTECTED literal drifted — expected "
            f"{canonical!r}, got {literal!r}. A divergence is two "
            f"different ideas of 'the grader' (drop a path and the gate no "
            f"longer protects it; F30: pin the literal, not a copy)")
    # The literal must be APPLIED — a `matches_protected` call inside a real
    # check, not just declared. A comment-only or renamed matcher passes a
    # grep on the literal while guarding nothing (the F30 call-site half).
    # CODE lines only: the script discusses the protected set at length in
    # comments, and a checker firing on its own docs trains ignore.
    code = [ln for ln in text.splitlines() if not ln.lstrip().startswith("#")]
    if not any("matches_protected" in ln and "$p" in ln for ln in code):
        problems.append(
            "scripts/ops-claims.sh: matches_protected is not applied to the "
            "touched paths — the PROTECTED literal is declared but not used; "
            "a gate-trespass check that never runs guards nothing (F30: pin "
            "the literal AND its application)")
    # audit F129: the call site alone is not the matcher — a matches_protected
    # gutted to `return 1` keeps the literal pinned AND the call site green
    # while every protected path stops matching. Pin the body's two matching
    # branches: the trailing-/ prefix branch and the glob application.
    mbody = _function_body(shell_code(p), "matches_protected")
    if mbody is None:
        problems.append(
            "scripts/ops-claims.sh: cannot locate matches_protected()'s body — "
            "the F129 matcher-effect pins have nothing to check. Reshaping the "
            "matcher must update this locator, not silently skip it")
    elif _report_if_redefined(mbody, "scripts/ops-claims.sh", problems):
        pass
    else:
        if "*/)" not in mbody:
            problems.append(
                "scripts/ops-claims.sh: matches_protected() has no `*/)` "
                "directory branch — a trailing-/ token (tests/, hooks/, "
                ".operator/bin/, backlog/) stops matching by prefix, so every "
                "protected DIRECTORY silently leaves the set (audit F129)")
        if "[[ $p == $pat ]]" not in mbody:
            problems.append(
                "scripts/ops-claims.sh: matches_protected() does not apply "
                "`[[ $p == $pat ]]` — the glob/exact tokens "
                "(scripts/ops-*.sh, scripts/validate_plugin.py) never match, "
                "so the matcher is declared, called, and inert (audit F129)")
    # audit F140 (2026-09-02): EXECUTE the matcher. The two literal pins above
    # are substring tests on the body, and an early `return 1` — the exact
    # escape F129's own comment names — left both literals in place while the
    # matcher matched nothing: "all contracts hold" (pin-auditor, re-run by
    # hand). Behaviour, not spelling: run the shipped PROTECTED line and the
    # shipped function in a child bash against one probe per token and two
    # unprotected paths. A dead branch, an early return, a wrapping `if false`
    # all fail here and none of them can fail a substring test.
    _ccode = shell_code(p)
    _pros = re.findall(r'^PROTECTED="[^"\n]*"$', _ccode, re.M)
    _fn = re.search(r'^matches_protected\(\)\s*\{.*?^\}', _ccode, re.M | re.S)
    if not _pros or not _fn:
        problems.append(
            "scripts/ops-claims.sh: cannot extract PROTECTED= and "
            "matches_protected() for the executable probe (audit F140) — "
            "reshaping either must update this extractor, not silently skip it")
    else:
        _script = _pros[-1] + "\n" + _fn.group(0) + '\nmatches_protected "$1"\n'
        for _path, _want in (("tests/t.sh", 0), ("hooks/hooks.json", 0),
                             (".operator/bin/ops-verdict.sh", 0),
                             ("scripts/ops-task.sh", 0),
                             ("scripts/validate_plugin.py", 0),
                             ("scripts/statusline.sh", 0), ("backlog/x.md", 0),
                             ("src/app.py", 1), ("scripts/other.sh", 1)):
            _r = _run_probe(["bash", "-c", _script, "_", _path], problems,
                            "scripts/ops-claims.sh: matches_protected()")
            if _r is None:
                break  # reported by _run_probe; the remaining probes would too
            if _r.returncode != _want:
                problems.append(
                    f"scripts/ops-claims.sh: matches_protected() "
                    f"{'does not MATCH' if _want == 0 else 'MATCHES'} "
                    f"'{_path}' when executed (rc {_r.returncode}, expected "
                    f"{_want}) — the pinned literals may be present while the "
                    f"behaviour is gone (an early return, a dead branch), and "
                    f"then the gate-trespass check guards nothing (audit F140)")
    # statusline.sh must be in the literal — it is the F66 amendment and the
    # one a prior glob missed. Match the token, not the whole literal, so a
    # reordering stays free but dropping it fires.
    if "statusline.sh" not in (literal or ""):
        problems.append(
            "scripts/ops-claims.sh: PROTECTED omits scripts/statusline.sh — "
            "it is a full sentinel reader (F66); leaving it out re-opens a "
            "parser-weakening laundering path")


def _run_probe(argv, problems, what, env=None):
    """Run an executable pin's probe. Returns the CompletedProcess, or None
    after REPORTING why it could not run.

    Three hazards, each measured on this file's own probes (PR review of
    e8e0179) rather than imagined:

    * **No timeout hangs the build forever.** The probes exec code extracted
      from repo files, and a guard containing a bare `read` blocks on inherited
      stdin: `validate_plugin.py` never returned (measured — killed at 20s).
      A build gate that hangs is worse than one that fails, because CI reports
      nothing at all. Hence `timeout=` AND `stdin=DEVNULL`, which turns a
      stdin-reading guard into an instant EOF instead of a wedge.
    * **A missing interpreter raises instead of reporting.** `subprocess.run`
      throws FileNotFoundError when the binary is absent; the node probe took
      down the whole validator with a traceback on a machine without node
      (measured). Every check in this file reports; none may crash.
    * A timeout is itself a finding, not a skip — same polarity as the rest.
    """
    try:
        return subprocess.run(argv, capture_output=True, text=True,
                              stdin=subprocess.DEVNULL, timeout=30, env=env)
    except FileNotFoundError:
        problems.append(
            f"{what}: cannot run the behaviour probe — {argv[0]!r} is not "
            f"installed, so this pin proves nothing on this machine. Reported "
            f"rather than skipped: a silent skip is how a gutted guard ships "
            f"green (audit F144)")
    except subprocess.TimeoutExpired:
        problems.append(
            f"{what}: the behaviour probe TIMED OUT after 30s — the extracted "
            f"code blocks (a bare `read` inherits stdin, a loop never exits). "
            f"That is a defect in what was extracted, and a build gate that "
            f"hangs reports nothing at all (audit F144)")
    return None


def _tool_loops(code):
    """Every `for [_]tool in <words>; do … done` as (head, body) pairs.

    Non-greedy `(.*?)\\n\\s*done` is WRONG here and the reason this helper
    exists: a decoy `for _tool in $_OPS_TOOLS; do :; done` immediately followed
    by a real loop over a hardcoded list makes the decoy's head pair with the
    REAL loop's body, because the decoy's own inline `done` sits on the same
    line as its `do` and the pattern scans past it to the next line-leading
    `done`. The compliant-looking pair that falls out satisfies every check
    (measured 2026-09-02 while writing the F144 pin — it reported "all
    contracts hold" on the mutation it was written to catch).

    So: walk `do`/`done` word tokens and match them like brackets, which is
    what bash does. Same house rule as check_compressor's brace-depth pass —
    when the question is "which body belongs to this head", counting is the
    only honest answer a regex cannot give.

    Counting words is not lexing, and the gap bit (PR review of e8e0179): a
    bare "do" in ENGLISH — `echo "nothing to do here"` — reads as a nested
    loop opening, so the matcher needs one extra `done` and swallows the NEXT
    loop whole. An install loop that copies nothing, sitting above any
    unrelated loop with a `cp` in it, shipped "all contracts hold" (measured
    against the real ops-init.sh). The second detection arm could not save it
    either: the swallowed loop's head is not a tool-loop head, so it was never
    a candidate of its own.

    The fix is a boundary, not a lexer: a loop body cannot extend past the
    start of a LATER top-level loop head, so the scan stops there. Any `for`
    or `while` at the start of a line, at the same indentation or shallower,
    ends the search — a real nested loop is indented deeper, and the shapes
    this pin cares about are all top-level. Overshooting now truncates the
    body (fail CLOSED: the `cp` is not found, the pin fires) instead of
    extending it (fail OPEN: someone else's `cp` satisfies the check).
    """
    # Comments and string bodies are MASKED before the word scan, offsets
    # preserved (PR review of e8e0179, second half). The scan matches the bare
    # WORDS `do`/`done`, and English contains both: `echo "install not done
    # yet"` closed the loop early and truncated the body mid-string, which
    # fails toward a false FAIL on correct code — and the truncated text still
    # contained the word "install", so the body check matched PROSE rather
    # than a command. Same masking discipline as _mask_code in release_gate.py
    # and shell_code() one layer up: blank the contents, keep the offsets, so
    # a match position still indexes the original text.
    code = re.sub(r'#[^\n]*', lambda m: " " * len(m.group(0)), code)
    code = re.sub(r'"[^"\n]*"|\'[^\'\n]*\'',
                  lambda m: m.group(0)[0] + " " * (len(m.group(0)) - 2) + m.group(0)[-1],
                  code)
    _WORD = re.compile(r'(?<![\w-])(do|done)(?![\w-])')
    out = []
    for _h in re.finditer(r'for\s+_?tool\s+in\s+([^\n;]*?)\s*;?\s*\bdo\b', code):
        # The head's own indentation: a later loop at this level or shallower
        # is a SIBLING, and this body ends before it.
        _line0 = code.rfind("\n", 0, _h.start()) + 1
        _indent = len(code[_line0:_h.start()]) - len(code[_line0:_h.start()].lstrip())
        _next = None
        for _s in re.finditer(r'^([ \t]*)(?:for|while)\b', code[_h.end():], re.M):
            if len(_s.group(1)) <= _indent:
                _next = _h.end() + _s.start()
                break
        _limit = _next if _next is not None else len(code)
        depth, i, end = 1, _h.end(), None
        for _t in _WORD.finditer(code, i, _limit):
            depth += 1 if _t.group(1) == "do" else -1
            if depth == 0:
                end = _t.start()
                break
        out.append((_h.group(1), code[i:end] if end is not None else code[i:_limit]))
    return out


def check_install_set_parity(root, problems):
    r"""The .operator/bin install set has ONE declaration (#76 step 3):
    scripts/ops-install-set.sh, sourced by both writers — ops-init.sh (the
    authoritative install) and ops-sessionstart-hook.sh (the upgrade path).
    Until 0.9.0 each writer carried its own copy and this check pinned them
    equal (CR4: a fifth CLI added to one and not the other shipped green).
    One declaration removes the drift; what this check now holds:

    (1) the manifest exists, is a plain single `_OPS_TOOLS="…"` assignment this
        regex can read, and names ops-verdict.sh (the gate's single writer —
        an empty or garbled set is a broken install, not a smaller one);
    (2) each writer SOURCES the manifest (`. "$…/ops-install-set.sh"`) and
        iterates `$_OPS_TOOLS` in its copy loop — a writer that re-grew an
        inline list beside the source line is the drift coming back with the
        check green (F30: declared-but-not-applied);
    (3) no writer declares its own `_OPS_TOOLS="…"` literal any more.

    Every failure is REPORTED, never skipped — the earlier version compared
    `if a and b` and went quiet when one side was unreadable (measured
    2026-08-12 while fixing #34).
    """
    manifest = root / "scripts" / "ops-install-set.sh"
    if not manifest.is_file():
        problems.append(
            "scripts/ops-install-set.sh: missing — the single install-set "
            "declaration both writers source (#76 step 3); without it ops-init "
            "dies and the SessionStart upgrade path skips every session")
        return
    # _single_assignment, not re.search: bash resolves the LAST assignment and a
    # first-match pin let one appended line install 1 of 5 CLIs, build green (#81).
    _tools = _single_assignment(manifest.read_text(encoding="utf-8"),
                                r'^_OPS_TOOLS="([^"]+)"\s*$',
                                "scripts/ops-install-set.sh", "_OPS_TOOLS", problems)
    m = _tools
    if not m:
        problems.append(
            "scripts/ops-install-set.sh: no plain `_OPS_TOOLS=\"…\"` assignment "
            "found — both writers source this file expecting that variable; a "
            "reshape (array, computed value) must update this locator AND both "
            "writers, not silence the pin")
        return
    tools = m.split()
    if "ops-verdict.sh" not in tools:
        problems.append(
            f"scripts/ops-install-set.sh: install set {tools} omits "
            f"ops-verdict.sh — the single writer to VERDICTS.md is the one CLI "
            f"the charter cannot function without; an install set without it is "
            f"corruption, not configuration")
    for name in ("ops-init.sh", "ops-sessionstart-hook.sh"):
        p = root / "scripts" / name
        if not p.is_file():
            continue  # missing writer is check_scripts' finding
        code = shell_code(p)
        if not re.search(r'\.\s+"\$[A-Za-z_{}]+[^"]*/ops-install-set\.sh"', code):
            problems.append(
                f"scripts/{name}: does not source ops-install-set.sh — the "
                f"install set must come from the one shared declaration, or the "
                f"two writers drift again (CR4)")
        # audit F130: anchored through `; do` — the unanchored form accepted
        # `for tool in $_OPS_TOOLS statusline.sh; do`, a second word-list
        # grafted onto the manifest's, which is the inline-list drift wearing
        # the manifest as a prefix. Nothing may sit between the variable and
        # the loop body.
        if not re.search(r'for\s+_?tool\s+in\s+\$_OPS_TOOLS\s*;\s*do', code):
            problems.append(
                f"scripts/{name}: copy loop does not iterate $_OPS_TOOLS "
                f"alone (`for tool in $_OPS_TOOLS; do`) — extra words after "
                f"the variable, or an inline list beside the source line, is "
                f"the drift coming back with this check green (F30: "
                f"declared-but-not-applied; audit F130)")
        # The manifest loop must be the one that COPIES (audit F144). F130
        # anchored the loop's HEAD, and a head can be satisfied by a decoy: a
        # `for _tool in $_OPS_TOOLS; do :; done` placed beside a second loop
        # over a hardcoded list passed every pin while the installer shipped
        # whatever that literal list named (measured 2026-09-02). Require a
        # loop whose head matches AND whose body copies — and require it to be
        # the ONLY iteration over a tool list, so a literal-list loop anywhere
        # in the writer is reported rather than hidden behind a compliant one.
        _loops = _tool_loops(code)
        if not _loops:
            # `if _loops:` was the wrong polarity (PR review of e8e0179): the
            # head regex only matches an iteration variable literally named
            # `tool`/`_tool`, so renaming it made _tool_loops return [] and
            # BOTH arms below silently never ran. The F130 pin above still
            # fires on the shapes measured, so this was not an open gate — but
            # a check that goes quiet when its own shape assumption fails is
            # the exact silence this file exists to refuse, and it reported
            # nothing to say why. No candidate loop is a finding.
            problems.append(
                f"scripts/{name}: no `for tool in $_OPS_TOOLS; do … done` loop "
                f"could be located at all — the install loop is the thing this "
                f"check is about, so its absence (renamed iteration variable, "
                f"a reshape this locator cannot read) is reported, never "
                f"treated as nothing to check (audit F144)")
        else:
            if not any(re.fullmatch(r'\s*\$_OPS_TOOLS\s*', _head)
                       and re.search(r'\b(cp|install)\b', _body)
                       for _head, _body in _loops):
                problems.append(
                    f"scripts/{name}: no `for tool in $_OPS_TOOLS; do` loop "
                    f"whose BODY copies (cp/install) — the manifest is iterated "
                    f"but installs nothing, so an empty-bodied decoy loop can "
                    f"satisfy every head-anchored pin while a second loop over "
                    f"a hardcoded list does the real install (audit F144)")
            for _head, _body in _loops:
                if not re.fullmatch(r'\s*\$_OPS_TOOLS\s*', _head) \
                        and re.search(r'\b(cp|install)\b', _body):
                    problems.append(
                        f"scripts/{name}: a copy loop iterates {_head.strip()!r} "
                        f"rather than $_OPS_TOOLS — the install set has ONE "
                        f"declaration (#76 step 3); a second list beside the "
                        f"manifest loop is the CR4 drift, and it installs a "
                        f"different set than the one both writers agreed on "
                        f"(audit F144)")
        if re.search(r'^_OPS_TOOLS="[^"]+"', code, re.MULTILINE):
            problems.append(
                f"scripts/{name}: declares its own _OPS_TOOLS literal — the "
                f"declaration lives in ops-install-set.sh alone (#76 step 3); "
                f"a second copy is the CR4 drift this file exists to end")


def check_gitignore_parity(root, problems):
    r"""
    The .operator/.gitignore v2 body is written in TWO places (ops-init's
    _gi_write and the SessionStart v1 migration) — drift means the two paths
    silently ignore different sets. The body must match; the backup must be
    reachable (exit-status-tested, non-regular .v1.bak refused); the hook
    re-stamps only after replacement and reports the refusal.
    """
    MARK = "# cc-operator gitignore v2 (allowlist)"
    IGNORE_ALL = "*"
    # `handoff-*.md` is evidence (the HANDOFF section's artifact), not machine
    # state (#28).
    ALLOW = ("!.gitignore", "!.gitattributes", "!VERDICTS.md", "!DECISIONS.md",
             "!tiers.env", "!verdicts.d/", "!verdicts.d/*.md",
             "!handoff-*.md")
    sets = {}
    for name in ("ops-init.sh", "ops-sessionstart-hook.sh"):
        p = root / "scripts" / name
        if not p.is_file():
            problems.append(f"scripts/{name}: missing — cannot check gitignore parity")
            continue
        text = p.read_text(encoding="utf-8")
        if MARK not in text:
            problems.append(
                f"scripts/{name}: does not carry the v2 gitignore marker "
                f"{MARK!r} — both writers must emit it AND grep for it, or a v1 "
                f"blocklist is never migrated (it would be appended to instead, "
                f"and the two schemes contradict)")
        # Emitting the marker and DETECTING it are two claims; assert the
        # detection grep separately (either spelling: init greps the variable,
        # the standalone hook greps the literal).
        #
        # DETECTION vs CONFIRMATION (#102). Since the atomic rewrite the hook
        # greps for this marker TWICE: once on the LIVE file to decide "is this
        # still v1?", and once on `$_gi.v2.tmp` to confirm the new body landed
        # before the mv. A pattern matching either is satisfied by the
        # confirmation grep alone, so a mutation deleting only DETECTION —
        # after which a v1 blocklist is never migrated at all — shipped green
        # (measured during the 0.11.4 remediation; the weakness was recorded in
        # this check's own test before it was closed).
        #
        # The TARGET is the asymmetry a non-vacuous pin can key on: detection
        # reads the live path, confirmation reads the temp. Requiring at least
        # one marker grep against a NON-temp target pins the detection read
        # specifically, and stays agnostic about which path VARIABLE each
        # writer uses. It is NOT agnostic about quoting: the regex captures a
        # double-quoted target only, which both writers use today. That is the
        # right polarity — a single-quoted or bare target is simply not
        # captured, `any()` over nothing is False, and the pin FIRES. Loud,
        # not vacuous (PR #104 review asked; measured by reading the regex).
        #
        # `.tmp`-exclusion alone was still satisfiable (audit F144): retarget
        # detection to `"$_gi.v1.bak"` — not a temp, so it passed — and a v1
        # file is never migrated, because the backup does not exist until the
        # migration this read is supposed to trigger has already run. It is
        # unconditionally absent, so `grep` always fails, `! grep` is always
        # true, and the branch inverts to "always migrate" on a v2 file
        # (measured 2026-09-02, "all contracts hold"). Naming DERIVATIVE
        # suffixes one at a time is the enumeration F140/F141 argue against, so
        # invert the test: the target must BE the live path — a bare variable
        # expansion, or a literal ending in `/.gitignore`. Everything derived
        # from it (`$_gi.v2.tmp`, `$_gi.v1.bak`, any future suffix) is not.
        elif not any(re.fullmatch(r"\$\{?\w+\}?", _target)
                     or _target.endswith("/.gitignore")
                     for _target in re.findall(
                r"grep\s+-qF\s+(?:\"\$_GI_MARK\"|'" + re.escape(MARK) +
                r"')\s+\"([^\"]+)\"", text)):
            problems.append(
                f"scripts/{name}: emits the v2 marker but never greps for it on "
                f"the LIVE .gitignore — without that read the writer cannot tell "
                f"a v1 file from a v2 one, so an existing v1 blocklist is never "
                f"migrated (it is appended to, and the two schemes contradict). "
                f"A grep against the `.v2.tmp` path is the post-write "
                f"CONFIRMATION, a different claim: it proves the new body "
                f"landed, never that the old one needed replacing (#102)")
        # Allow lines are line-anchored: a '!VERDICTS.md' inside prose is not a
        # heredoc body line, and would make this check vacuous.
        lines = {ln.strip() for ln in text.splitlines()}
        # The bare `*` line: without it the file is a blocklist wearing an
        # allowlist's marker, and every ephemera dir ships tracked.
        if IGNORE_ALL not in lines:
            problems.append(
                f"scripts/{name}: the v2 gitignore body has no bare `*` line — "
                f"without it the allowlist inverts to a blocklist and machine "
                f"state (bin/, pending/, .lock/, .compress-spill/) becomes "
                f"TRACKED by default, the exact failure v2 ended")
        sets[name] = tuple(a for a in ALLOW if a in lines)
    a, b = sets.get("ops-init.sh"), sets.get("ops-sessionstart-hook.sh")
    for name, got in sets.items():
        missing = [x for x in ALLOW if x not in got]
        if missing:
            problems.append(
                f"scripts/{name}: v2 gitignore body is missing allow line(s) "
                f"{missing} — an ignored ledger is evidence that silently never "
                f"reaches the teammate reading the repo")
    if a is not None and b is not None and a != b:
        problems.append(
            f"gitignore allowlist drift: ops-init.sh admits {list(a)} but "
            f"ops-sessionstart-hook.sh admits {list(b)} — the two writers must "
            f"stay equal (F30; a project's tracked set must not depend on which "
            f"path migrated it)")

    # MIGRATION SAFETY, both writers: the v2 write must be REACHABLE ONLY
    # through a tested backup (the old unconditional write destroyed user rules
    # while the notice promised recoverability). Pinned as "the copy is tested,
    # and the body-writer is inside the success branch" - exactly the shape that shipped.
    for name, writer in (("ops-init.sh", "_gi_write"),
                         ("ops-sessionstart-hook.sh", "cat > \"$_gi\"")):
        p = root / "scripts" / name
        if not p.is_file():
            continue
        text = p.read_text(encoding="utf-8")
        if ".gitignore.v1.bak" not in text and ".v1.bak" not in text:
            continue  # no migration path in this writer
        # The copy's exit status must be TESTED (`if ! cp`/`elif ! cp`), not
        # discarded. A bare `cp "$x" "$x.v1.bak" 2>/dev/null` line is the bug.
        tested = re.search(r"(?:if|elif)\s+!\s+cp\s", text)
        if not tested:
            problems.append(
                f"scripts/{name}: the v1→v2 gitignore migration copies the "
                f"user's file to .v1.bak without testing whether the copy "
                f"SUCCEEDED — a failed backup then falls through to an "
                f"unconditional overwrite, destroying rules the notice promises "
                f"are recoverable (measured 2026-08-12). Guard the write behind "
                f"the copy: `elif ! cp … ; then <refuse>; else <write>; fi`")
        # …and a non-regular entry at the backup path must be refused, not
        # copied INTO (cp lands the file inside a directory of that name, so the
        # advertised recovery path then points at a directory).
        if not re.search(r"\[\s*!\s*-f\s+\"\$[_A-Za-z0-9{}/.]*\.v1\.bak\"|"
                         r"\[\s*!\s*-f\s+\"\$OPDIR/\.gitignore\.v1\.bak\"", text):
            problems.append(
                f"scripts/{name}: the migration does not refuse a non-regular "
                f"entry at .gitignore.v1.bak — `cp` copies INTO a directory of "
                f"that name, so the recovery path the notice names is not the "
                f"backup (measured 2026-08-12)")

    # THE THIRD STATE, hook only (audit 2026-08-31): backup SUCCEEDED and the
    # overwrite failed. F119 made `cat`'s exit status the probe but left the
    # flag set at two — migrated / backup-failed — and `_gi_backup_failed` is
    # scoped to the elif branches ABOVE the write, so this outcome fell through
    # both notices and the hook reported nothing (measured: rc 0, no gitignore
    # line in additionalContext, over a partial write whose marker makes every
    # LATER session skip the migration). ops-init.sh needs no flag: `set -e`
    # kills it on the failed write, loudly. SET and REPORT are two claims —
    # pinning only the assignment is satisfied by a flag nothing ever reads.
    p = root / "scripts" / "ops-sessionstart-hook.sh"
    if p.is_file():
        text = p.read_text(encoding="utf-8")
        if ".v1.bak" in text:
            if not re.search(r"_gi_write_failed=1", text):
                problems.append(
                    "scripts/ops-sessionstart-hook.sh: the gitignore migration "
                    "has no flag for a SUCCEEDED backup with a FAILED write — "
                    "that third outcome falls through both the MIGRATED and the "
                    "REFUSED notice, so the hook reports nothing while the file "
                    "may be a truncated allowlist whose marker makes every later "
                    "session skip the migration (measured 2026-08-31)")
            elif not re.search(r'\[\s*"\$_gi_write_failed"\s*=\s*1\s*\]', text):
                problems.append(
                    "scripts/ops-sessionstart-hook.sh: _gi_write_failed is set "
                    "but never REPORTED — a flag nothing reads is the silence "
                    "this state was found in. Setting it and telling the "
                    "session about it are two claims")
        # THE WRITE IS ATOMIC, pinned on its own (PR #104 review). The
        # confirmation pin below used to be gated on `".v2.tmp" in text`, so a
        # mutation that removed the temp ENTIRELY — `cat > "$_gi"` straight
        # onto the live file, the pre-0.11.4 F119 shape — removed the thing
        # being checked and the check with it. It still fired, but only because
        # the user-facing NOTICE happened to mention `.gitignore.v2.tmp`; with
        # that one prose line reworded too, the validator reported "all
        # contracts hold" over a non-atomic write (measured, two-place
        # mutation). A pin whose trigger is a substring of the code it guards
        # is one edit from vacuous. This one keys on the mechanism itself: the
        # same-dir `mv -f` from the temp onto the live path is what makes the
        # live file always either the intact v1 or the complete v2.
        if not re.search(r'mv\s+-f\s+"\$_gi\.v2\.tmp"\s+"\$_gi"', text):
            problems.append(
                "scripts/ops-sessionstart-hook.sh: the v2 gitignore write is "
                "not ATOMIC — no `mv -f \"$_gi.v2.tmp\" \"$_gi\"` swaps a complete "
                "temp onto the live path. Writing the heredoc straight onto "
                ".gitignore means a `cat` that dies mid-write (ENOSPC, EIO) "
                "leaves a truncated allowlist whose marker makes every LATER "
                "session skip the migration, and the next retry copies THAT "
                "over the good .v1.bak (F119; the 0.11.4 fix)")
        # …and the other half of #102's asymmetry: the CONFIRMATION grep must
        # keep probing the TEMP. F119 made it the completeness probe (`[ -s ]`
        # was true for a partial write), and the atomic rewrite made the temp
        # the thing there is to probe. Pinned by target for the same reason the
        # detection pin is: the two greps carry identical text and only their
        # argument tells them apart, so one pattern cannot stand for both.
        # UNCONDITIONAL — the `".v2.tmp" in text` gate is gone (see above).
        if not re.search(
                r"grep\s+-qF\s+'" + re.escape(MARK) + r"'\s+\"[^\"]*\.v2\.tmp\"",
                text):
            problems.append(
                "scripts/ops-sessionstart-hook.sh: the v2 gitignore write is "
                "not confirmed by grepping the marker in the `.v2.tmp` temp "
                "before the mv — without it a heredoc that died mid-write "
                "(ENOSPC, EIO) is moved over the live file, and the partial "
                "body's marker makes every LATER session skip the migration "
                "(F119). Detecting a v1 file and confirming the v2 write are "
                "two claims (#102)")

    # audit F137 (2026-09-02): ops-init's write is atomic for the same reason
    # (the PR #97 review made BOTH writers temp+mv) and had no pin of its own —
    # reverting it to the heredoc-onto-the-live-file shape reported "all
    # contracts hold" on a scratch copy of 0.11.5. Same-shape pin, init's paths.
    p = root / "scripts" / "ops-init.sh"
    if p.is_file() and not re.search(
            r'mv\s+-f\s+"\$OPDIR/\.gitignore\.v2\.tmp"\s+"\$OPDIR/\.gitignore"',
            shell_code(p)):
        problems.append(
            "scripts/ops-init.sh: the v2 gitignore write is not ATOMIC — no "
            "`mv -f \"$OPDIR/.gitignore.v2.tmp\" \"$OPDIR/.gitignore\"` swaps a "
            "complete temp onto the live path. Under set -e a cat dying "
            "mid-write leaves a truncated, marker-less .gitignore, and the "
            "re-run's migration backs THAT up over the good .v1.bak (F119's "
            "class; the hook's copy is pinned above — audit F137)")


#: The lock block's load-bearing content, pinned as CANONICAL rather than
#: compared between the two copies. Audited 2026-08-25: parity alone is F30's
#: shape — this check compared ops-verdict.sh against ops-adopt.sh and nothing
#: else, so retyping `read -r -n 128` to `read -r -n 999999999` in BOTH copies
#: left them trivially "in parity" with the ledger's mutual exclusion reading
#: an unbounded holder record. That is the exact lesson this check's own
#: docstring cites, committed inside the check that teaches it.
#:
#: Each entry is (regex, what breaks when it goes). Keep them behavioural: the
#: byte-for-byte comparison below already catches reflow, so anything here
#: should be a property the ledger's correctness rests on.
CANONICAL_LOCK = (
    (r"IFS= read -r -n 128 LOCK_HOLDER_REC",
     "the holder record read must stay byte-bounded — a newline-less "
     ".lock/holder is read whole while the 30s lock budget runs"),
    (r"IFS= read -r -n 128 FALLBACK_REC",
     "the fallback holder read must stay byte-bounded, same reason"),
    (r"while ! mkdir \"\$LOCKDIR\" 2>/dev/null; do",
     "mkdir is the atomic primitive (no flock on macOS); a test-then-create "
     "is a race, not a lock"),
    (r"kill -0 \"\$pid\" 2>/dev/null",
     "liveness is decided by kill -0, not by an age heuristic — a slow "
     "writer must not be judged dead"),
    (r"mkdir \"\$LOCKDIR\.reclaim\" 2>/dev/null",
     "the reclaim itself is guarded by an atomic mkdir, or two waiters "
     "reclaim the same dead holder's lock simultaneously"),
)


def check_lock_parity(root, problems):
    """ops-verdict.sh and ops-adopt.sh must carry the SAME lock implementation,
    and it must be the RIGHT one.

    Both contend on `.operator/.lock`: a divergence is two different ideas of
    mutual exclusion, invisible until it corrupts the ledger. Byte-for-byte on
    the marked block, normalizing only the tool name in messages — plus a
    canonical-content pin, because two copies that drift TOGETHER are trivially
    in parity (F30, measured against this very check 2026-08-25).
    """
    blocks = {}
    for name in ("ops-verdict.sh", "ops-adopt.sh"):
        p = root / "scripts" / name
        if not p.is_file():
            return  # missing-file is already reported by check_scripts
        text = p.read_text(encoding="utf-8")
        start = text.find("# >>> LOCK BLOCK")
        end = text.find("# <<< LOCK BLOCK")
        if start < 0 or end < 0:
            problems.append(
                f"scripts/{name}: no `# >>> LOCK BLOCK` … `# <<< LOCK BLOCK` "
                f"markers — the shared lock must stay delimited so its parity "
                f"with the other CLI can be checked (see docs/PLAYBOOK.md)")
            return
        tool = name[:-3]  # ops-verdict.sh -> ops-verdict
        blocks[name] = text[start:end].replace(f"{tool}:", "TOOL:")
    a, b = blocks["ops-verdict.sh"], blocks["ops-adopt.sh"]
    if a != b:
        a_lines, b_lines = a.splitlines(), b.splitlines()
        detail = "differing line counts"
        for i, (x, y) in enumerate(zip(a_lines, b_lines), 1):
            if x != y:
                detail = f"first difference at block line {i}: {x.strip()[:60]!r} vs {y.strip()[:60]!r}"
                break
        problems.append(
            f"scripts/ops-verdict.sh vs ops-adopt.sh: lock implementations have "
            f"drifted — they contend on the same lock and must be identical "
            f"({detail})")
    # The content pin runs per COPY, not on the comparison: uniform drift is
    # the realistic failure here (these blocks are maintained by copy-paste,
    # so a fix applied to one is applied to both), and it is exactly what a
    # parity test cannot see.
    for name, block in blocks.items():
        # CODE only. The content pin searched the RAW block, so commenting out
        # the real `while ! mkdir` and leaving the identical text in a comment
        # satisfied it in both copies while the lock was a test-then-create race
        # (Copilot, PR #87) — MENTION-not-ACTION, inside the pin added to close
        # MENTION-not-ACTION. Parity above still reads the raw block: a comment
        # that differs between the copies is a real divergence to report.
        code = "\n".join(ln for ln in block.splitlines()
                         if not ln.lstrip().startswith("#"))
        for pat, why in CANONICAL_LOCK:
            if not re.search(pat, code):
                problems.append(
                    f"scripts/{name}: the lock block no longer contains "
                    f"/{pat}/ — {why}. Parity with the other CLI is not enough: "
                    f"identically-broken copies are trivially in parity (F30)")


CANONICAL_ROOT = (
    (r'\[ -d "\$_walk/\.operator" \]',
     "the walk must look for .operator/, which is what makes a directory a "
     "project — anything else resolves a different tree than the Stop hook"),
    (r'cd "\$_walk"',
     "it must CD, not merely export an absolute OPDIR: the source stamp's "
     "`git status -- ':(exclude).operator'` pathspec is REPO-relative, so an "
     "absolute-OPDIR fix leaves every row from a subdirectory falsely +dirty "
     "while every ledger path looks correct (mutation-measured)"),
    (r'\[ -e "\$_walk/\.git" \] && break',
     "the .git boundary stops the walk: a nested repo is its own project, and "
     "without this a CLI run inside a vendored repo writes into the OUTER "
     "project's ledger"),
    (r'\[ "\$_walk" = "/" \] && break',
     "the filesystem root bounds the loop"),
    (r'pwd -P',
     "-P resolves symlinks, so a planted link cannot redirect the walk"),
)


def check_root_parity(root, problems):
    """The three gate CLIs must resolve the project the SAME way, and it must be
    the right way.

    OPDIR was relative to the caller's cwd until 0.11.3, so every CLI worked
    from the project root and nowhere else — including through the absolute
    path the Stop hook prescribes (#95, measured from `apps/viewer/`). The walk
    now mirrors ops-stop-hook.sh's, and three copies maintained by copy-paste
    drift the way the lock block would.
    """
    blocks = {}
    for name in ("ops-task.sh", "ops-verdict.sh", "ops-adopt.sh"):
        p = root / "scripts" / name
        if not p.is_file():
            return  # missing-file is already reported by check_scripts
        text = p.read_text(encoding="utf-8")
        start = text.find("# >>> PROJECT ROOT BLOCK")
        end = text.find("# <<< PROJECT ROOT BLOCK")
        if start < 0 or end < 0:
            problems.append(
                f"scripts/{name}: no `# >>> PROJECT ROOT BLOCK` … "
                f"`# <<< PROJECT ROOT BLOCK` markers — the CLI resolves the "
                f"project from the caller's cwd, so it works from the project "
                f"root and nowhere else (#95; see docs/PLAYBOOK.md)")
            return
        tool = name[:-3]
        blocks[name] = text[start:end].replace(f"{tool}:", "TOOL:")
    ref_name, ref = next(iter(blocks.items()))
    for name, block in blocks.items():
        if block != ref:
            ref_lines, b_lines = ref.splitlines(), block.splitlines()
            detail = "differing line counts"
            for i, (x, y) in enumerate(zip(ref_lines, b_lines), 1):
                if x != y:
                    detail = (f"first difference at block line {i}: "
                              f"{x.strip()[:60]!r} vs {y.strip()[:60]!r}")
                    break
            problems.append(
                f"scripts/{name} vs {ref_name}: project-root resolution has "
                f"drifted — two CLIs disagreeing about which project they serve "
                f"write into different ledgers ({detail})")
    # Per-copy content pin: these blocks are maintained by copy-paste, so
    # uniform drift is the realistic failure and is exactly what parity above
    # cannot see (F30). CODE only — a commented-out walk left as text satisfied
    # the equivalent lock pin once already (Copilot, PR #87).
    for name, block in blocks.items():
        code = "\n".join(ln for ln in block.splitlines()
                         if not ln.lstrip().startswith("#"))
        for pat, why in CANONICAL_ROOT:
            if not re.search(pat, code):
                problems.append(
                    f"scripts/{name}: the project-root block no longer contains "
                    f"/{pat}/ — {why}. Parity across the three copies is not "
                    f"enough: identically-broken copies are trivially in "
                    f"parity (F30)")


def check_resolver_renderer_parity(root, problems):
    """
    ops-tiers.sh and ops-render.sh must agree on check_routable and the tier
    set — they parse the same tiers.env. Compared whitespace- and comment-
    insensitively (reflow is free, logic change is not).
    """
    src = {}
    for name in ("ops-tiers.sh", "ops-render.sh"):
        p = root / "scripts" / name
        if not p.is_file():
            return  # missing-file is already reported by check_scripts
        src[name] = p.read_text(encoding="utf-8")

    def routable_body(text):
        m = re.search(r"check_routable\(\)\s*\{(.*?)\n\}", text, re.DOTALL)
        if not m:
            return None
        # CODE only, matching check_reader_bounds' convention: one copy carries
        # a trailing `# check_routable <label> <id>` signature comment and the
        # other does not. A comment is not a semantic divergence, and a parity
        # check that fires on one trains maintainers to route around it.
        code = [ln.split("#", 1)[0] for ln in m.group(1).splitlines()]
        return " ".join(" ".join(code).split())

    bodies = {n: routable_body(t) for n, t in src.items()}
    missing = [n for n, b in bodies.items() if b is None]
    if missing:
        problems.append(
            f"scripts/{', '.join(missing)}: no `check_routable() {{ … }}` "
            f"definition found — the resolver and the renderer must refuse the "
            f"same model ids, and this check cannot compare what it cannot find")
    elif bodies["ops-tiers.sh"] != bodies["ops-render.sh"]:
        problems.append(
            "scripts/ops-tiers.sh vs ops-render.sh: check_routable has drifted "
            "— they validate the same tiers.env, so a divergence means one "
            "writes a binding the other would refuse (whitespace-insensitive "
            "comparison, so this is a real logic difference)")
    else:
        # Equality alone is satisfied by two identically gutted copies (F30):
        # pin the load-bearing reject to its content.
        #
        # ONE fragment, not three, since 0.8.3. The id-shape reject and the
        # provider-lens allowlist were both deleted from check_routable, so
        # pinning them would now pin their absence's opposite — see that
        # function's comment for why operator no longer decides which model ids
        # exist. The charset reject is the whole guard, which makes this pin
        # more load-bearing than before, not less.
        for frag, why in (
                (r"[!A-Za-z0-9._:/@[\]-]", "the charset reject"),):
            if frag not in bodies["ops-tiers.sh"]:
                problems.append(
                    f"scripts/ops-tiers.sh + ops-render.sh: check_routable no "
                    f"longer contains {why} ({frag!r}) — the two copies agree, "
                    f"but agreeing on a guard that checks nothing is how a "
                    f"parity check passes while the guard is gone")

    # (LENS_NAMESPACES deleted 0.8.3 — a copied cc-proxy fact table nothing
    # here can keep honest. A future guard needing proxy facts asks the proxy.)

    names = {}
    for name, text in src.items():
        # Same #81 guard: a second TIER_NAMES= line is what bash would use.
        _tn = _single_assignment(
            text, r"^(?:readonly\s+)?TIER_NAMES=[\"'](.*?)[\"']",
            name, "TIER_NAMES", problems)
        m = _tn
        if not m:
            problems.append(
                f"scripts/{name}: no `TIER_NAMES=\"…\"` assignment found — both "
                f"the resolver and the renderer gate seat bindings on this set; "
                f"a legal refactor (renaming, retyping) must update this regex, "
                f"not silence it")
            return
        names[name] = tuple(m.split())
    if names["ops-tiers.sh"] != names["ops-render.sh"]:
        problems.append(
            f"scripts/ops-render.sh: TIER_NAMES={list(names['ops-render.sh'])} "
            f"does not match the resolver's {list(names['ops-tiers.sh'])} in "
            f"ops-tiers.sh — the renderer's is_tier_name would gate seat "
            f"bindings on a stale namespace")


def check_workflows(root, problems):
    """
    Workflow meta pins + the model-id guard.

    `meta`/`whenToUse` must be PURE LITERALS (the harness rejects a computed
    meta at launch with every gate green); `BAD_CHARSET` must stay pinned to
    its canonical literal AND applied at a `.test(id)` site per file — copy
    parity is not enough because uniform drift is the realistic failure (F30).
    A re-declared `const ROUTABLE` fires: the id-shape catalogue was deleted
    in 0.8.3 (check_routable judges well-formedness only — the user picks the
    model, cc-proxy routes it) and the re-add is the reflex fix.
    """
    wf_dir = root / "workflows"
    files = sorted(wf_dir.glob("*.js")) if wf_dir.is_dir() else []
    if not files:
        return  # workflows/ is optional; the plugin ships review.js only at need
    # CANONICAL_ROUTABLE is gone with the 0.8.3 shape catalogue (the user picks
    # the model, cc-proxy routes it) — its re-declaration fires. BAD_CHARSET is
    # now the ONLY id guard: literal AND call site per file (F30).
    CANONICAL_BAD_CHARSET = r"/[^\w./:@[\]-]/"
    for f in files:
        rel = f"workflows/{f.name}"
        text = f.read_text(encoding="utf-8")

        # Comment-stripped view for the APPLICATION checks: a call site moved
        # into a comment must not satisfy the "is it applied" regex (F48/F57 —
        # demonstrated live by the panel against this very check). Block then
        # line comments, as check_compressor does. DECLARATION checks below run
        # on raw `text`: BAD_CHARSET's not-found branch reads the
        # raw view deliberately, so commenting the declaration out is reported
        # rather than read as absence. (The ROUTABLE check below is the mirror
        # image — it reads raw text so that PROSE about the removed guard, which
        # every workflow now carries, cannot be mistaken for a re-declaration.)
        code = re.sub(r"/\*.*?\*/", "", text, flags=re.DOTALL)
        code = "\n".join(ln for ln in code.split("\n")
                         if not ln.lstrip().startswith("//"))

        # (b) meta: first statement, PURE literal. A concatenation inside it
        # is rejected by the harness AT LAUNCH — the workflow silently never
        # runs, and no suite here launches one (plan.js shipped this once).
        # #114: the locator once required the closing brace on its OWN line
        # (`\n};`), so an inline-closed `export const meta = {…};` returned
        # None and every meta pin below skipped silently while the
        # `startswith` pin stayed green — a computed meta inside a one-line
        # block passed every check (measured). No-candidate is a FINDING.
        meta_block = re.search(r"export const meta\s*=\s*\{.*?\};", text, re.S)
        if meta_block is None:
            problems.append(
                f"{rel}: cannot locate the `export const meta = {{…}}` block "
                f"— the meta pins (pure-literal, concatenation, template "
                f"literal, structural) have nothing to check. A reshaped or "
                f"renamed meta declaration must update this locator, not "
                f"silently skip it (#114: no-candidate is a finding, never "
                f"a pass)")
        if meta_block and re.search(r'"\s*\+|\+\s*"', meta_block.group(0)):
            problems.append(
                f"workflows/{f.name}: `meta` contains a concatenation — the harness "
                f"requires a PURE LITERAL and rejects a computed meta at launch, so "
                f"the workflow would fail to run with every gate here green")
        # audit F133: a template literal (`x ${y}`) is the OTHER computed-meta
        # spelling and the concatenation pin cannot see it. Strip the contents
        # of double-quoted strings first — shipped metas legitimately quote
        # markdown code in backticks INSIDE a string — then any surviving
        # backtick is a template-literal delimiter.
        if meta_block:
            _m_nostr = re.sub(r'"(?:[^"\\\n]|\\.)*"', '""',
                              meta_block.group(0))
            if "`" in _m_nostr:
                problems.append(
                    f"workflows/{f.name}: `meta` contains a template literal "
                    f"(backtick outside a double-quoted string) — the harness "
                    f"requires a PURE LITERAL and rejects a computed meta at "
                    f"launch, same class as the concatenation (audit F133)")

        # audit F141 (2026-09-02): STRUCTURAL, not another spelling. The `+`
        # and backtick pins enumerate two ways to compute a meta out of an
        # unbounded set — `name: String("crawl").trim()` passed both AND every
        # suite (the stub runtime never parses meta) while the harness refuses
        # it at launch. Strip comments and string literals; what remains may
        # hold only keys, brackets, numbers, true/false/null — and no call.
        if meta_block:
            _m = re.sub(r"//[^\n]*", "", meta_block.group(0))
            _m = re.sub(r'"(?:[^"\\\n]|\\.)*"|\'(?:[^\'\\\n]|\\.)*\'', '""', _m)
            _bad = [t for t in re.findall(r"\b[A-Za-z_$][\w$]*\b(?!\s*:)", _m)
                    if t not in ("export", "const", "meta", "true", "false", "null")]
            if "(" in _m or _bad:
                _why = "a call `(`" if "(" in _m else f"identifier `{_bad[0]}`"
                problems.append(
                    f"workflows/{f.name}: `meta` is not a PURE literal — {_why} "
                    f"outside a string; the harness rejects any computed meta at "
                    f"launch and no suite here launches one (audit F141; the "
                    f"concatenation and template-literal pins are two spellings "
                    f"of this)")

        # no `node --check`: too lenient (exit 0 on redeclared consts);
        # real syntax errors surface at launch
        body = text.lstrip()
        if not body.startswith("export const meta ="):
            problems.append(
                f"{rel}: does not begin with `export const meta = {{…}}` as the "
                f"first statement (the harness requires a pure-literal meta block "
                f"first, or it refuses to launch the workflow)")

        # (c) a re-introduced id-shape guard is a REGRESSION — the only check
        # here that fires on a guard's PRESENCE, because the reflex re-add
        # (`const ROUTABLE = /…/` when an id misbehaves) passes every test: the
        # user picks the model, cc-proxy routes it. Whatever symptom prompted
        # the re-add, a hardcoded id catalogue in this repo is
        # not the fix — it is the bug that shipped for three releases.
        if re.search(r"const\s+ROUTABLE\s*=", text):
            problems.append(
                f"{rel}: declares `const ROUTABLE = …` — an id-shape catalogue "
                f"was REMOVED in 0.8.3 and must not come back. Operator does not "
                f"decide which model ids exist; the user chooses (tiers.env / "
                f"args.model) and cc-proxy routes. A shape list in this repo "
                f"cannot track cc-proxy's catalogue and refused 8 of 409 live "
                f"ids when it was measured. Keep BAD_CHARSET (well-formedness) "
                f"and let a bad id fail at dispatch, where the truth is")

        # (d) the charset guard: canonical literal AND proven applied — since
        # 0.8.3 the ONLY id guard. Cross-file parity is necessary but not
        # sufficient: uniform drift (edit once, copy-paste to all four) leaves
        # identically gutted copies "in parity" (F30).
        badcharset_decl = re.search(r"const\s+BAD_CHARSET\s*=\s*(/\S.*?)\s*;", text)
        if not badcharset_decl:
            problems.append(
                f"{rel}: no `const BAD_CHARSET = …` declaration found — it is "
                f"the only id guard a workflow carries; without it an id "
                f"carrying whitespace or quotes (a malformed tiers.env line, "
                f"e.g. an unquoted `MECHANICAL=claude opus`) reaches dispatch "
                f"(audit F01)")
        else:
            got = badcharset_decl.group(1).strip()
            if got != CANONICAL_BAD_CHARSET.strip():
                problems.append(
                    f"{rel}: BAD_CHARSET regex is {got!r}, expected "
                    f"{CANONICAL_BAD_CHARSET.strip()!r} — it must mirror "
                    f"ops-tiers.sh's check_routable charset [A-Za-z0-9._:/@[]-]; "
                    f"a divergent regex either lets whitespace/quotes through or "
                    f"rejects valid bracket-marked ids like `glm-5.2[1m]`")

        if not re.search(r"BAD_CHARSET\.test\s*\(", code):
            problems.append(
                f"{rel}: BAD_CHARSET is declared but never applied — the "
                f"declaration alone guards nothing; it must be checked with "
                f"`BAD_CHARSET.test(id)` in the tier-resolution loop")


# Shared invariants every workflow must carry identically. The sandbox forbids
# `import()`, so the tier-validation block is COPY-PASTED with no dedup
# possible, and byte-parity is the only thing holding the copies together —
# the same lesson check_lock_parity enforces for the bash lock. DEFAULT_TIERS
# is excluded (each workflow declares only what it uses), so it is NOT a
# parity invariant. BAD_CHARSET IS — a divergence between copies is a silent
# disagreement about which ids are well-formed. (ROUTABLE dropped 0.8.3.)
WORKFLOW_PARITY_CONSTS = ("BAD_CHARSET",)


def check_workflow_parity(root, problems):
    """Every workflow's shared regex constant (BAD_CHARSET) must be
    byte-identical across all workflows/*.js.

    The tier-resolution block is duplicated because the sandbox forbids imports
    (measured 2026-07-30). Prose ("keep them in sync") does not hold that
    coupling — check_lock_parity was written for the identical lesson in bash.
    This is its JS analogue: a divergence between two workflows' BAD_CHARSET is
    a silent disagreement about which ids are well-formed, with no crash.
    """
    wf_dir = root / "workflows"
    files = sorted(wf_dir.glob("*.js")) if wf_dir.is_dir() else []
    if len(files) < 2:
        return  # parity needs >= 2; a single workflow cannot drift against itself
    # Extract each const's RHS (the `/.../flags` literal) per file.
    seen = {}  # const_name -> {value: [filenames]}
    for f in files:
        text = f.read_text(encoding="utf-8")
        for const in WORKFLOW_PARITY_CONSTS:
            m = re.search(rf"const\s+{const}\s*=\s*(/\S.*?)\s*;", text)
            if not m:
                # a missing const is check_workflows' job, not parity's; skip
                continue
            val = m.group(1).strip()
            seen.setdefault(const, {}).setdefault(val, []).append(f.name)
    for const, by_val in seen.items():
        if len(by_val) > 1:
            detail = "; ".join(
                f"{v!r} in {', '.join(ns)}" for v, ns in by_val.items())
            problems.append(
                f"workflows/: {const} has diverged across workflows ({detail}) "
                f"— the sandbox forbids imports, so the tier-validation block "
                f"is copy-pasted; the regexes must stay byte-identical or two "
                f"workflows silently disagree on what is routable "
                f"(see check_lock_parity for the bash analogue)")


# DEFAULT_TIERS values must be HARNESS ALIASES, never vendor ids (#76 step 2):
# real bindings are the operator's (/cc-operator:tiers -> args.tiers), and a
# harness alias cannot go stale. This pin exists because
# the reflex fix, when a default routes badly, is to paste a vendor id back in
# — which quietly recreates the catalogue this lift deleted, one file at a
# time, with every other gate green.
HARNESS_ALIASES = ("opus", "sonnet", "haiku", "fable")


def check_workflow_default_tiers(root, problems):
    """Every workflow's DEFAULT_TIERS values must be harness aliases.

    Reads the object literal's string VALUES. Reports a workflow whose
    DEFAULT_TIERS cannot be located (a legal reshape must update this locator,
    not silence it) — every workflow dispatches at least one tier, so absence
    is a reshape, not a valid state.
    """
    wf_dir = root / "workflows"
    files = sorted(wf_dir.glob("*.js")) if wf_dir.is_dir() else []
    for f in files:
        rel = f"workflows/{f.name}"
        text = f.read_text(encoding="utf-8")
        code = "\n".join(ln for ln in text.splitlines()
                         if not ln.lstrip().startswith("//"))
        m = re.search(r"const\s+DEFAULT_TIERS\s*=\s*\{([^}]*)\}", code)
        if not m:
            problems.append(
                f"{rel}: no `const DEFAULT_TIERS = {{...}}` found — every "
                f"workflow declares the tiers it dispatches; a reshape must "
                f"update this locator, not silence the alias pin (#76 step 2)")
            continue
        for vm in re.finditer(r'"([^"]*)"', m.group(1)):
            val = vm.group(1)
            if val not in HARNESS_ALIASES:
                problems.append(
                    f"{rel}: DEFAULT_TIERS value {val!r} is not a harness alias "
                    f"{list(HARNESS_ALIASES)} — a vendor model id in a workflow "
                    f"default recreates the catalogue-of-another-system's-facts "
                    f"class the #76 tier lift deleted (real bindings belong in "
                    f"tiers.env, forwarded as args.tiers)")


def check_workflow_agent_types(root, problems):
    """Every `agentType: "cc-operator:X"` in workflows/*.js must name a shipped
    plugin-root agent (agents/X.md).

    A workflow agentType resolves against the PLUGIN registry — a rendered
    project-layer agent cannot be named there. crawl.js shipped dispatching
    op-scout for shards while its commit message and template claimed
    op-crawler, which could not exist as a workflow agentType (audit F22): the
    shard prompt said "read every path" while op-scout's body said "read only
    the relevant excerpts, <=20 lines". The name check is mechanical; keeping
    the BODY compatible with the dispatch prompt stays a PLAYBOOK judgment.
    """
    wf_dir = root / "workflows"
    files = sorted(wf_dir.glob("*.js")) if wf_dir.is_dir() else []
    for f in files:
        text = f.read_text(encoding="utf-8")
        # Comments stripped, exactly as check_workflows does (F57): the VALUE
        # pattern below is loose enough to match prose, and dispatch.js's own
        # comments quote `"cc-operator:op-" + seat` while explaining why it does
        # NOT concatenate. A checker that reads its own documentation as code is
        # worse than one that misses — it fires on the file that got it right.
        code = re.sub(r"/\*.*?\*/", "", text, flags=re.DOTALL)
        code = "\n".join(ln for ln in code.split("\n")
                         if not ln.lstrip().startswith("//"))
        # Match the VALUE, not the `agentType:` key — dispatch.js passes the
        # shorthand `agentType,` from a SEATS lookup, and the key form found
        # ZERO matches in exactly the file that needed it. The value form covers
        # a literal at the call site AND one in a lookup table.
        for m in re.finditer(rf'"{re.escape(PLUGIN_NAME)}:(op-[\w-]+)"', code):
            agent_name = m.group(1)
            if not (root / "agents" / f"{agent_name}.md").is_file():
                problems.append(
                    f"workflows/{f.name}: agentType "
                    f"'{PLUGIN_NAME}:{agent_name}' names no shipped agent — "
                    f"agents/{agent_name}.md does not exist; a rendered "
                    f"project-layer agent cannot be a workflow agentType (F22)")


# The frontmatter keys every slash command must carry. Matches the shape
# commands/start.md and commands/handoff.md already use. argument-hint may be
# an empty list (`argument-hint: []`), so the check accepts a value of `[]`.
COMMAND_REQUIRED_KEYS = ("description", "argument-hint", "allowed-tools")


def check_commands(root, problems):
    r"""Every commands/*.md must carry the frontmatter the harness registers it
    by (description / argument-hint / allowed-tools), and must reference scripts
    only as `${CLAUDE_PLUGIN_ROOT}/scripts/...`.

    The plugin-root rule is the same landmine the charter's EVIDENCE GATE hits:
    a bare `scripts/foo.sh` path resolves only inside THIS repo, so a target
    project running the command gets a "command not found" and the operator is
    blocked from starting/stopping — the v0.2.0 bug the charter path-check
    exists for, now applied to the command bodies that invoke those scripts.

    `commands/` is optional: the good-tree fixture and a plugin that ships only
    agents need not have one. When present, every file is checked; an empty dir
    (present but no .md) is flagged, since a command the harness cannot register
    is worse than none.
    """
    cmd_dir = root / "commands"
    files = sorted(cmd_dir.glob("*.md")) if cmd_dir.is_dir() else []
    if not cmd_dir.is_dir():
        return  # commands/ is optional
    if not files:
        problems.append(
            "commands/: present but holds no *.md — the plugin's slash "
            "commands are its entry points; an empty dir is a shipping bug")
        return
    for f in files:
        rel = f"commands/{f.name}"
        text = f.read_text(encoding="utf-8")
        fm = re.match(r"\A---\n(.*?)\n---\n", text, re.DOTALL)
        if not fm:
            problems.append(
                f"{rel}: no `---` frontmatter block — Claude Code will not "
                f"register the command without it")
            continue
        front = fm.group(1)
        for key in COMMAND_REQUIRED_KEYS:
            # `argument-hint: []` is a valid (empty) value; `\S` would reject it
            # because `]` follows whitespace. Accept an explicit empty list too.
            if not re.search(rf"^{re.escape(key)}:\s*\S", front, re.MULTILINE) \
               and not re.search(rf"^{re.escape(key)}:\s*\[\]", front, re.MULTILINE):
                problems.append(
                    f"{rel}: frontmatter missing required key '{key}'")
        # A bare `scripts/<x>` reference resolves only inside this repo. The
        # charter's path-check covers the gate CLIs; this covers any script a
        # command body invokes. `${CLAUDE_PLUGIN_ROOT}/scripts/...` is the
        # layout-independent form (the same distinction validator check 4 makes
        # for the charter, and hook check 7 makes for hooks.json).
        for hit in re.finditer(r"(?<![$/])scripts/[A-Za-z0-9._-]+", text):
            # `(?<![$/])` lets `${CLAUDE_PLUGIN_ROOT}/scripts/` and a preceding
            # `/scripts/` pass; a bare leading `scripts/` is the fault.
            problems.append(
                f"{rel}: references `{hit.group(0)}` without "
                f"${{CLAUDE_PLUGIN_ROOT}} — a bare scripts/ path resolves only "
                f"inside this repo, not in a target project (the v0.2.0 "
                f"blocked-start bug)")


def check_compressor(root, problems):
    """
    The compressor's carve-outs (spec I1/I2).

    The compressor is the only component that REWRITES what the model reads:
    drop `Read` from the allowlist and the model edits against text it never
    saw; drop a ledger path and a mid-body elision of PASS rows falsifies the
    exact artifact this plugin protects. Byte-checked, not trusted to review.
    Every pin is literal-AND-call-site (F48/F30 class) against a
    comment-stripped view.
    """
    comp = root / "scripts" / "ops-compress.mjs"
    hooks = root / "hooks" / "hooks.json"
    if not comp.exists():
        problems.append("scripts/ops-compress.mjs is missing (hooks.json wires a PostToolUse hook at that path)")
        return
    src = comp.read_text(encoding="utf-8")

    # 1. hooks.json actually wires it, via ${CLAUDE_PLUGIN_ROOT} like every other hook.
    if hooks.exists():
        import json as _json
        try:
            hj = _json.loads(hooks.read_text(encoding="utf-8")).get("hooks", {})
        except Exception:
            hj = {}
        post = hj.get("PostToolUse")
        if not post:
            problems.append("hooks/hooks.json: no PostToolUse entry — the compressor is dead code without it")
        else:
            blob = _json.dumps(post)
            if "ops-compress.mjs" not in blob:
                problems.append("hooks/hooks.json: PostToolUse does not point at ops-compress.mjs")
            if "${CLAUDE_PLUGIN_ROOT}" not in blob:
                problems.append("hooks/hooks.json: PostToolUse command lacks ${CLAUDE_PLUGIN_ROOT} (a bare path resolves only inside this repo)")

    # Strip comments (BOTH syntaxes) so a regex cannot match prose that merely
    # mentions a pattern — the inverse of F48. Not a JS lexer, but no guarded
    # pattern lives in a string, so a false strip only reddens correct code.
    code = re.sub(r"/\*.*?\*/", "", src, flags=re.DOTALL)
    # Trailing line comments too — a call site relocated into one defeats a
    # whole-line-only strip (panel 5b). Same safe-direction property.
    code = "\n".join(
        re.sub(r"//.*$", "", ln)
        for ln in code.split("\n")
        if not ln.lstrip().startswith("//")
    ).strip()

    # I1 — per-tool literal AND call site (dropping one name once left the
    # validator green; F48).
    for tool in ("Read", "Edit", "Write", "NotebookEdit"):
        if not re.search(rf'NEVER_COMPRESS\s*=\s*new Set\([^)]*"{tool}"', code):
            problems.append(f"ops-compress.mjs: `{tool}` is not in the NEVER_COMPRESS set literal (dropping it makes the tool elidable — I1; F48)")
        # `^\s*if \(` anchored: the call site must be the head of its own
        # statement. `if (false) if (NEVER_COMPRESS.has(tool)) return null;`
        # satisfied an unanchored search — the guard present, declared, and
        # unreachable (audited 2026-08-25; the DEAD BRANCH shape, which is what
        # check_workflows' AST coercion pin was added for one file over).
        # The multiline `if (false) { … }` form is caught by the nesting-depth
        # check below, which is what an anchor alone cannot see.
        if not re.search(r'^\s*if \(NEVER_COMPRESS\.has\(\s*tool\s*\)\s*\)\s*return null',
                         code, re.MULTILINE):
            problems.append("ops-compress.mjs: NEVER_COMPRESS.has(tool) is not the head of its own `if (…) return null;` statement — a neutered body skips the exclusion, and a preceding `if (false)` makes it unreachable while every literal pin stays green (F48; audited 2026-08-25)")
            break  # one missing call site is the same defect for all four

    # REACHABILITY, not presence. The anchor above rejects the one-line
    # `if (false) if (…)` and nothing else: wrapping the same call site in a
    # multiline `if (false) { … }` left every guard declared, matched, and
    # unreachable with the build green (Copilot, PR #87).
    #
    # Brace depth is the discriminator and it is cheap: all five guards are
    # STRAIGHT-LINE statements in `compress()`, at the same nesting as the
    # `const tool = payload.tool_name` line they follow. Any wrapper — dead or
    # live, `if (false)`, a `try`, a loop — puts them deeper. So: find the
    # anchor's depth, and require each guard to sit at exactly that depth.
    # Not a JS parser (there is none in the stdlib), but it answers the one
    # question a substring cannot: is this statement conditional on anything?
    ANCHOR = "const tool = payload.tool_name"
    GUARDS = (
        ("NEVER_COMPRESS.has(tool)", "the never-compress exclusion"),
        ('tool.startsWith("mcp__")', "the mcp__* exclusion"),
        ("LOSSLESS_ONLY.has(tool)", "the Agent lossless-only branch"),
        ("LEDGER_PATHS.some(", "the I2.2 ledger carve-out"),
        ("GATE_CLIS.some(", "the I2.1 gate-CLI carve-out"),
    )
    depth, anchor_depth, guard_depths = 0, None, {}
    for ln in code.split("\n"):
        here = depth
        depth += ln.count("{") - ln.count("}")
        if anchor_depth is None and ANCHOR in ln:
            anchor_depth = here
            continue
        if anchor_depth is None:
            continue
        for needle, _ in GUARDS:
            if needle in ln and needle not in guard_depths:
                guard_depths[needle] = here
    if anchor_depth is None:
        problems.append(
            f"ops-compress.mjs: cannot find `{ANCHOR}` — the reachability check "
            f"has no anchor, so it can prove nothing about the guards below it. "
            f"Update ANCHOR in check_compressor rather than dropping the check")
    else:
        for needle, what in GUARDS:
            got = guard_depths.get(needle)
            if got is None:
                continue  # its own presence pin above already reported this
            if got != anchor_depth:
                problems.append(
                    f"ops-compress.mjs: `{needle}` sits at brace depth {got}, "
                    f"but `{ANCHOR}` is at {anchor_depth} — {what} is nested "
                    f"inside something, so it is CONDITIONAL where it must be "
                    f"straight-line. A dead `if (false) {{ … }}` wrapper leaves "
                    f"every literal and call-site pin green while the guard "
                    f"never runs (Copilot, PR #87)")
    # ELIDABLE/NEVER_COMPRESS DISJOINTNESS — the allowlist decides what is
    # elided, so no never-compress name may appear in it (panel 5a).
    elidable_decl = re.search(r'ELIDABLE\s*=\s*new Set\(\s*\[([^\]]*)\]', code)
    if not elidable_decl:
        problems.append("ops-compress.mjs: no `ELIDABLE = new Set([…])` literal found (the allowlist that decides what is elided — I1)")
    else:
        elidable_names = set(re.findall(r'"([^"]+)"', elidable_decl.group(1)))
        for banned in ("Read", "Edit", "Write", "NotebookEdit"):
            if banned in elidable_names:
                problems.append(f"ops-compress.mjs: `{banned}` is in the ELIDABLE allowlist — a never-compress tool must never be elidable (I1; F48; panel 5a)")
    # A Set literal is not a Set contents: `new Set([...])` is mutable, so
    # `ELIDABLE.add("Read")` after the declaration puts a never-compress tool
    # in the allowlist while every literal pin above stays green — measured
    # 2026-08-25, and the 90-case replay suite did not see it either. Same for
    # the other three sets, and for `.delete` on NEVER_COMPRESS.
    for setname in ("ELIDABLE", "NEVER_COMPRESS", "LOSSLESS_ONLY"):
        for mut in re.finditer(rf"\b{setname}\.(add|delete|clear)\s*\(", code):
            problems.append(
                f"ops-compress.mjs: `{setname}.{mut.group(1)}(` mutates the set "
                f"AFTER its literal — every pin here reads the literal, so this "
                f"changes what is elided with the build green. Edit the literal")
    for arrname in ("LEDGER_PATHS", "GATE_CLIS"):
        # Methods, plus the two writes that are not method calls: `.length = 0`
        # empties the array and `[0] = "…"` replaces an entry, both leaving the
        # literal and the `.some()` call site green (Copilot, PR #87).
        for mut in re.finditer(
                rf"\b{arrname}\.(push|pop|splice|shift|unshift|fill|copyWithin|sort|reverse)\s*\(", code):
            problems.append(
                f"ops-compress.mjs: `{arrname}.{mut.group(1)}(` mutates the array "
                f"AFTER its literal — the I2 carve-out pins read the literal. "
                f"Edit the literal")
        for mut in re.finditer(rf"\b{arrname}\s*(?:\.length|\[[^\]]*\])\s*=(?!=)", code):
            problems.append(
                f"ops-compress.mjs: `{mut.group(0).strip()}` writes into the array "
                f"AFTER its literal — `.length = 0` empties the carve-out and an "
                f"indexed write replaces an entry, both with every literal and "
                f"`.some()` pin still green. Edit the literal")
    # mcp__ exclusion: the call site must have a return-null body, not a no-op.
    if not re.search(r'tool\.startsWith\(\s*"mcp__"\s*\)\s*\)\s*return null', code):
        problems.append("ops-compress.mjs: `mcp__*` exclusion is missing or has no `return null` body (a no-op body skips the exclusion — F48)")
    # Agent lossless-only: both the call site AND "Agent" in the literal.
    if not re.search(r'LOSSLESS_ONLY\.has\(\s*tool\s*\)', code) or \
       not re.search(r'LOSSLESS_ONLY\s*=\s*new Set\(\s*\[[^\]]*"Agent"', code):
        problems.append("ops-compress.mjs: `Agent` lossless-only is not both declared (\"Agent\" in set) AND applied (LOSSLESS_ONLY.has(tool)); F48")

    # I2.1/I2.2 — each path/CLI in its array literal AND `return null` in the
    # .some() body (a neutered body defeats a bare `.some(` check).
    for pth in (".operator/VERDICTS.md", ".operator/DECISIONS.md", ".operator/verdicts.d/"):
        if not re.search(rf'LEDGER_PATHS\s*=\s*\[[^\]]*{re.escape(pth)}', code):
            problems.append(f"ops-compress.mjs: ledger path `{pth}` is not in the LEDGER_PATHS literal (dropping it falsifies the carve-out — I2.2; F48)")
    for cli in CHARTER_REQUIRED_CLIS:
        if not re.search(rf'GATE_CLIS\s*=\s*\[[^\]]*"{cli}"', code):
            problems.append(f"ops-compress.mjs: gate CLI `{cli}` is not in the GATE_CLIS literal (I2.1; F48)")
    # The .some() bodies must carry `return null` on the same line. A bare
    # `.some(` check passes a neutered `.some(() => false)`; requiring the
    # return-null body on the line means a no-op body fails. Same-line because
    # the shipped form is a one-liner `if (X.some(...)) return null;`.
    if not re.search(r'LEDGER_PATHS\.some\(.*\)\s*\)\s*return null', code) or \
       not re.search(r'GATE_CLIS\.some\(.*\)\s*\)\s*return null', code):
        problems.append("ops-compress.mjs: the I2 carve-out .some() call sites are missing `return null` bodies (neutered bodies skip the carve-out — F48)")

    # 3. I3/I4/I5 structural markers: the pinned defaults must be present and
    # exact. "A test against a tilde is not a test" applies to the guard too.
    for k, v in (("MAX_CHARS", "8000"), ("HEAD_BYTES", "6144"), ("TAIL_BYTES", "4096"),
                 ("MIN_SHRINK", "64"), ("SCRUB_MIN", "1024"), ("LINE_CHARS", "400"),
                 ("SALVAGE_LINES", "12")):
        # audit F134: search the comment-stripped view — the raw `src` was
        # satisfied by a comment quoting the old value while the code shipped
        # a different number, so the pin taught a default the file no longer
        # had.
        if not re.search(rf"{k}:\s*{v}\b", code):
            problems.append(f"ops-compress.mjs: pinned default {k}={v} is missing or changed in the CODE — the replay test asserts these exact numbers (a comment quoting the old value does not count; audit F134)")
    # audit F120 guardrail: scrub's two ANSI regexes must anchor on a literal
    # `\x1b` escape. The 0.10.0 debloat stripped the raw ESC bytes out of the
    # literals, and without the anchor the OSC pattern's now-empty head
    # matched from the first bare `]` to the terminator — a 3KB test log came
    # back as one character, no marker, no spill: the scrub became a
    # destroyer. Pin exactly what the fixed regexes contain: `\x1b\]` (OSC)
    # and `\x1b\[` (CSI), at their `.replace(/` call sites.
    if r".replace(/\x1b\]" not in code:
        problems.append(
            "ops-compress.mjs: scrub's OSC regex does not open with a literal "
            r"`\x1b\]` — without the ESC anchor it matches from the first "
            "bare `]` to the terminator and destroys the output it was meant "
            "to clean (audit F120)")
    if r".replace(/\x1b\[" not in code:
        problems.append(
            "ops-compress.mjs: scrub's CSI regex does not open with a literal "
            r"`\x1b\[` — without the ESC anchor it eats bracketed text that "
            "was never an escape sequence, destroying output instead of "
            "cleaning it (audit F120)")
    # EXECUTE scrub (audit F144). Both pins above are substring tests, and the
    # anchored literal can sit somewhere that never runs: an unanchored regex
    # in the live `.replace()` chain plus a correctly-anchored copy inside an
    # `if (false)` block passed both while every `]`-bearing output was
    # destroyed again — F120 restored, validator green (measured 2026-09-02).
    # Import the shipped module and run the real thing on the real defect
    # input. `import`, not a subprocess of the hook: scrub is not exported, so
    # drive it through compress()'s Bash path with elision disabled, which is
    # how the hook reaches it too.
    # Both inputs must clear SCRUB_MIN (scrub runs at all) and the ANSI one
    # must shrink past MIN_SHRINK (compress keeps the result rather than
    # returning null for an unprofitable rewrite) — so the colour codes are
    # repeated, not decorative. `identity` is the F120 assertion and takes the
    # null path legitimately: a plain input scrub does not change cannot shrink,
    # so compress returns null and the fallback compares the input to itself.
    # That is the correct reading of "lossless", and it fails loudly the moment
    # scrub starts eating `]`.
    _probe = r'''
import {compress} from %s;
// Lines must be DISTINCT: scrub deliberately collapses a run of >=4 identical
// lines to `[repeated N×]`, so a `.repeat()` input measures that feature and
// not the ANSI regexes (it read as a lossless-tier failure while the tier was
// fine — the meter check this probe owes itself).
const N = 60;
const plain = Array.from({length: N}, (_, i) =>
  `step ${i} [ok] middle [FAIL] after`).join("\n");
const ansi = Array.from({length: N}, (_, i) =>
  `\x1b[31mstep ${i}\x1b[0m [ok] \x1b[32mmid\x1b[0m [FAIL]`).join("\n");
const run = (t) => {
  const out = compress({tool_name: "Bash", tool_response: {stdout: t}},
                       {env: {CC_OPERATOR_COMPRESS_DEDUP: "0"}, cwd: %s});
  return out === null ? t : out.hookSpecificOutput.updatedToolOutput.stdout;
};
const a = run(plain), b = run(ansi);
console.log(JSON.stringify({identity: a === plain, stripped: b.indexOf("\x1b") === -1,
                            kept: b.includes("[ok]") && b.includes("[FAIL]")}));
''' % (json.dumps(str(comp.resolve())), json.dumps(str(root.resolve())))
    _r = _run_probe(["node", "--input-type=module", "-e", _probe], problems,
                    "ops-compress.mjs: scrub")
    if _r is None:
        pass  # node absent or the probe hung — _run_probe reported which
    elif _r.returncode != 0:
        problems.append(
            f"ops-compress.mjs: scrub could not be executed through compress() "
            f"(node rc {_r.returncode}: "
            f"{(_r.stderr or '').strip().splitlines()[-1:] or ['']!r}) — the "
            f"F144 behaviour probe cannot report, so treat it as a failure "
            f"rather than a skip")
    else:
        try:
            _v = json.loads(_r.stdout.strip().splitlines()[-1])
        except Exception:
            _v = None
        if _v is None:
            problems.append(
                "ops-compress.mjs: the scrub behaviour probe returned no "
                "verdict — treat as a failure, not a skip (audit F144)")
        else:
            if not _v["identity"]:
                problems.append(
                    "ops-compress.mjs: scrub is NOT lossless on ANSI-free text "
                    "— a `]`-bearing plain-text output came back changed. This "
                    "is F120 itself: an unanchored regex destroys output, and "
                    "an anchored copy parked in a dead branch keeps both "
                    "literal pins above green while it does (audit F144)")
            if not _v["stripped"]:
                problems.append(
                    "ops-compress.mjs: scrub left a raw ESC byte in the output "
                    "— the regexes are anchored but not reached (a dead branch, "
                    "a reordered chain), so the scrub tier does nothing "
                    "(audit F144)")
            if not _v["kept"]:
                problems.append(
                    "ops-compress.mjs: scrub dropped bracketed text (`[ok]` / "
                    "`[FAIL]`) while stripping real ANSI — the CSI/OSC patterns "
                    "are over-matching, which is the F120 destroyer with the "
                    "anchors merely present somewhere in the file (audit F144)")
    # Read the SALVAGE_RE literal, not the file: `not ok` also appears in the
    # comment explaining why it must be there, so a prose-level `in src` check
    # passes while the regex itself has lost the alternative. Proven: deleting
    # `|not ok` from the pattern left a substring check green (2026-08-02).
    _sal = re.search(r"const SALVAGE_RE\s*=\s*\n?\s*/(.+?)/[gimsuy]*;", src, re.S)
    if not _sal:
        problems.append("ops-compress.mjs: SALVAGE_RE literal not found — check_compressor cannot verify the salvage alternatives")
    elif "not ok" not in _sal.group(1):
        problems.append("ops-compress.mjs: SALVAGE_RE omits TAP's `not ok` — a TAP failure contains no error WORD, so a FAIL would be elided into a recorded PASS")
    # SessionStart must clear both artifact trees (I2.3 + the dedup contract).
    ss = (root / "scripts" / "ops-sessionstart-hook.sh")
    if ss.exists():
        # CODE lines only. `if d not in sst` was a raw-text test, so emptying
        # the wipe loop and leaving the two directory names in a trailing
        # comment kept it green while nothing was cleared — MENTION-not-ACTION,
        # measured 2026-08-25. The rest of this checker already reads
        # ops-compress.mjs comment-stripped; this line did not.
        sst = "\n".join(ln for ln in ss.read_text(encoding="utf-8").splitlines()
                        if not ln.lstrip().startswith("#"))
        # The word list is what the loop iterates: everything between `in` and
        # the `; do`. Sliced explicitly rather than matched loosely, because
        # the escape that shipped was `for _cdir in ; do  # was: .compress-spill
        # .compress-state` — an empty list with the names surviving in a
        # trailing comment on the SAME line, which any line-anchored regex
        # still matches.
        _wipe = re.search(r"for _cdir in (.*?);\s*do", sst)
        wordlist = _wipe.group(1) if _wipe else ""
        for d in (".compress-spill", ".compress-state"):
            if d not in wordlist:
                problems.append(f"ops-sessionstart-hook.sh: does not clear `{d}` — it is not in the `for _cdir in …; do` word list (got {wordlist.strip()[:60]!r}), so a stale dedup hash after a compact collapses output the model can no longer see")


def check_release_gates_cover_validate(root, problems):
    """
    release.yml must run every suite validate.yml runs (#38): a tag build
    publishes, so its gate must be a superset, and it was a strict subset —
    both node suites ran on every PR and on no release. Compares suite
    commands, not run blocks (they legitimately differ elsewhere).
    """
    # BOTH forges. `.forgejo/` is the one that actually publishes on this LAN
    # (FORGE.md's order: act, then lokaal, then origin), and this check had
    # never looked at it — gutting every suite from the forge release job was
    # green (audited 2026-08-25). The two files cannot be identical (`uses:`
    # must be host-qualified on Forgejo and act cannot parse that form), which
    # is exactly why nothing else pins them.
    #
    # The runners this project uses. Matched per-line so a COMMENTED-OUT step
    # cannot satisfy the check: `# run: node tests/test_workflows.mjs` contains
    # the suite name, and a raw `in rtext` accepted it (audited 2026-08-25).
    #
    # 0.11.7 moved every rung behind `gate-suite.sh <rung>`, and that move
    # silently EMPTIED this check for one commit: it matched raw suite paths,
    # validate.yml no longer contained any, so `vsuites` was empty and the
    # superset test passed vacuously against a release job running nothing.
    # Caught here rather than in the field, and it is the reason the strings
    # below are the INVOCATION and not the suite file — a wrapper is exactly
    # the kind of indirection that empties a check aimed at what it wraps.
    SUITES = tuple(f"gate-suite.sh {rung}" for rung in SUITE_RUNGS)

    _IF_FALSE = re.compile(r"^-?\s*if:\s*(false|\$\{\{\s*false\s*\}\})\s*$")

    def live(text):
        """Suite names run by a step that is neither commented out nor disabled.

        Grouped into STEPS first (a step begins at a `- ` list item), because
        `if: false` can sit anywhere inside its own step — before or after the
        `run:` it disables. A line-by-line scan gets one of those orders wrong,
        and the one it gets wrong is the one a maintainer writes.
        """
        steps, cur = [], []
        for ln in text.splitlines():
            s = ln.strip()
            if not s or s.startswith("#"):
                continue  # a comment holding a suite name is not a step
            if s.startswith("- "):
                steps.append(cur)
                cur = []
            cur.append(s)
        steps.append(cur)
        out = set()
        for step in steps:
            if any(_IF_FALSE.match(s) for s in step):
                continue  # present but skipped is not run
            for s in step:
                for suite in SUITES:
                    if suite in s:
                        out.add(suite)
        return out

    for base, label in ((".github", "GitHub"), (".forgejo", "Forgejo")):
        wf = root / base / "workflows"
        val, rel = wf / "validate.yml", wf / "release.yml"
        if not val.is_file() and not rel.is_file():
            continue  # this forge is not configured — nothing to compare
        if not val.is_file() or not rel.is_file():
            # ONE present and the other absent is reported, not skipped: that is
            # a half-configured CI, and the whole point of this check is that the
            # publishing job must not be the weaker one. Only the both-absent
            # case above is a legitimate skip (the validator's own fixtures
            # build a plugin tree without workflows).
            missing = val.name if not val.is_file() else rel.name
            problems.append(
                f"{base}/workflows: {missing} is missing while its counterpart "
                f"exists — cannot verify that a tag build gates at least as much "
                f"as a PR build")
            continue
        # A job-level (or workflow-level) `if: false` sits OUTSIDE every step,
        # so the step grouping below never sees it and every suite in a disabled
        # publishing job still counted as coverage (Copilot, PR #87). Reported
        # rather than silently subtracted: a release workflow with a disabled
        # job is a configuration to fix, not a coverage number to adjust.
        for f in (val, rel):
            for ln in f.read_text(encoding="utf-8").splitlines():
                s = ln.strip()
                if s.startswith("#") or not _IF_FALSE.match(s):
                    continue
                # A step-level `if:` is legitimate for a conditional step and
                # is handled by the grouping above; only a job- or
                # workflow-level one is invisible to it. Two forms are always
                # step-level: the list item itself (`- if: false`) and a step
                # property, which is indented past the `- `. Job keys sit at 2
                # spaces here, so a job-level `if:` sits at 4.
                if not s.startswith("-") and (len(ln) - len(ln.lstrip())) <= 4:
                    problems.append(
                        f"{base}/workflows/{f.name}: a job- or workflow-level "
                        f"`{s}` disables everything under it, and the suite scan "
                        f"cannot see that from inside a step — the file would "
                        f"report full coverage while running nothing")
        vsuites, rsuites = live(val.read_text(encoding="utf-8")), live(rel.read_text(encoding="utf-8"))
        for suite in SUITES:
            if suite in vsuites and suite not in rsuites:
                problems.append(
                    f"{base}/workflows/release.yml: runs no LIVE `{suite}` step "
                    f"while validate.yml does — the {label} tag build that "
                    f"PUBLISHES gates less than the PR build that does not (#38). "
                    f"A commented-out or `if: false` step does not count")



# The rungs gate-suite.sh knows, in the order a build runs them. ONE
# declaration: check_suite_floors reads it, and so does the SUITES tuple in
# check_release_gates_cover_validate.
SUITE_RUNGS = ("validator", "python", "shell", "workflows", "compress")
# Every rung but the validator reports a case count; the validator's contract
# is its completion marker alone, so it carries no floor.
COUNTED_RUNGS = SUITE_RUNGS[1:]

# The raw invocations gate-suite.sh replaced. One of these back in a CI file is
# not a style lapse — it is a rung whose floor and marker nothing checks, which
# is the state this whole change exists to end.
RAW_SUITE_INVOCATIONS = (
    "python3 scripts/validate_plugin.py",
    "python3 -m unittest",
    "bash tests/test-scripts.sh",
    "node tests/test_workflows.mjs",
    "node tests/test_compress.mjs",
)

_CI_FILES = (
    ".github/workflows/validate.yml",
    ".github/workflows/release.yml",
    ".forgejo/workflows/validate.yml",
    ".forgejo/workflows/release.yml",
)


def check_suite_floors(root, problems):
    """The ratchet: every suite has a floor, and every CI path runs through it.

    Until 0.11.7 the only floor in this repo was PROSE, in a comment above the
    shell-suite step in .forgejo/workflows/validate.yml, claiming 683 on macOS
    and 675 in a rootful container. Measured 2026-09-03 in a rootful container:
    820. Stale by ~145 cases, and nothing noticed, because nothing read it.
    Deleting a hundred cases shipped green through every CI path.

    Four claims, because they fail independently:

    1. tests/floors.env exists, parses, and carries a positive integer floor
       for every COUNTED rung.
    2. scripts/gate-suite.sh SOURCES that file and holds no floor literal of
       its own — the CR4 shape: a value in two places is a value in neither
       the moment they drift.
    3. Every CI file reaches every rung through `gate-suite.sh <rung>` and
       contains no raw invocation that would bypass the wrapper.
    4. The wrapper is EXECUTED against crafted logs (F140/F144): a substring
       test on a shell body is blind to control flow, and an early `exit 0` in
       gate-suite.sh would satisfy claims 1-3 while checking nothing. Three
       probes with known answers, including the accepts-the-ordinary-case
       control — rejection probes alone are satisfied by a guard that dies on
       everything.
    """
    floors_rel = "tests/floors.env"
    floors = root / floors_rel
    gs_rel = "scripts/gate-suite.sh"
    gs = root / gs_rel

    # A tree with NONE of the three parts is a plugin fixture, not a
    # half-configured repo — the same legitimate skip check_release_gates_cover_
    # validate makes for a tree with no workflows at all. Any ONE of them
    # present makes all of them required: that is where a real regression
    # lives, and skipping it is how "the checker is still plugged in" stops
    # being asked.
    has_ci = any((root / rel).is_file() for rel in _CI_FILES)
    if not (floors.is_file() or gs.is_file() or has_ci):
        return
    if not floors.is_file():
        problems.append(
            f"{floors_rel}: missing — it is the ONE declaration of every "
            f"suite's case floor, and without it gate-suite.sh has no ratchet "
            f"to hold a rung to")
        return
    if not gs.is_file():
        problems.append(
            f"{gs_rel}: missing — the CI files reach every rung through it, so "
            f"its absence is a build that runs no suite at all")
        return

    # --- claim 1: a positive integer floor per counted rung ---
    values = {}
    for ln in floors.read_text(encoding="utf-8").splitlines():
        ln = ln.strip()
        if not ln or ln.startswith("#") or "=" not in ln:
            continue
        k, _, v = ln.partition("=")
        values[k.strip()] = v.strip()
    for rung in COUNTED_RUNGS:
        key = f"FLOOR_{rung}"
        raw = values.get(key)
        if raw is None:
            problems.append(
                f"{floors_rel}: no `{key}` — gate-suite.sh refuses a rung with "
                f"no floor, so this is a rung that cannot run at all")
        elif not (raw.isdigit() and int(raw) > 0):
            problems.append(
                f"{floors_rel}: `{key}={raw}` is not a positive integer. A "
                f"floor of 0 is not a floor; it is the absence of one wearing "
                f"a number")

    # --- claim 2: one declaration, sourced, never re-stated ---
    code = shell_code(gs)
    if floors_rel not in code:
        problems.append(
            f"{gs_rel}: does not name `{floors_rel}` in code — the floors must "
            f"be SOURCED from the one declaration, not carried here")
    if not re.search(r'^\s*\.\s+"\$FLOORS"', code, re.M):
        problems.append(
            f"{gs_rel}: no `. \"$FLOORS\"` source line — naming the file "
            f"without sourcing it is a floor nothing reads (the shape the "
            f"prose comment this replaces had for months)")
    local_floor = re.search(r"^\s*FLOOR_(\w+)\s*=\s*[0-9]+", code, re.M)
    if local_floor:
        problems.append(
            f"{gs_rel}: assigns `FLOOR_{local_floor.group(1)}` to a literal in "
            f"code. The floor for a rung must come from {floors_rel} alone — "
            f"two declarations drift, and the one CI reads wins silently")

    # --- claim 3: no CI path bypasses the wrapper ---
    for rel in _CI_FILES:
        f = root / rel
        if not f.is_file():
            continue  # a forge this checkout does not configure
        text = f.read_text(encoding="utf-8")
        live = "\n".join(ln for ln in text.splitlines()
                          if not ln.strip().startswith("#"))
        for rung in SUITE_RUNGS:
            if f"gate-suite.sh {rung}" not in live:
                problems.append(
                    f"{rel}: no live `gate-suite.sh {rung}` step — that rung "
                    f"runs with no floor and no completion marker, or does not "
                    f"run at all. A commented-out step does not count")
        for raw in RAW_SUITE_INVOCATIONS:
            if raw in live:
                problems.append(
                    f"{rel}: invokes `{raw}` directly, bypassing "
                    f"{gs_rel}. Exit 0 is also what a step that ran nothing "
                    f"returns, and the floor is not consulted at all")

    # --- claim 4: EXECUTE the wrapper (F140/F144) ---
    shell_floor = values.get("FLOOR_shell")
    if not (shell_floor and shell_floor.isdigit()):
        return  # claim 1 already reported it; nothing to probe against
    at_floor = int(shell_floor)
    probes = (
        ("below the floor",
         f"== summary: {at_floor - 1} passed, 0 failed ==\n", 1),
        ("no completion marker",
         "  ok   a case\n  ok   another\n", 1),
        ("a failed case reported while exiting 0",
         f"== summary: {at_floor} passed, 2 failed ==\n", 1),
        # THE CONTROL. Without it every assertion above is satisfied by a
        # gate-suite.sh whose first line is `exit 1` — a guard that refuses
        # everything passes every rejection probe ever written.
        ("exactly at the floor, clean (the accepts-the-ordinary-case control)",
         f"== summary: {at_floor} passed, 0 failed ==\n", 0),
    )
    with tempfile.TemporaryDirectory() as td:
        for what, body, want in probes:
            log = pathlib.Path(td) / "probe.log"
            log.write_text(body, encoding="utf-8")
            r = _run_probe(["bash", str(gs), "--check", "shell", str(log)],
                           problems, f"{gs_rel} ({what})")
            if r is None:
                continue
            # EXACT code, never `rc != 0` (audit F144): an arm calling an
            # undefined command exits 127 and reads as a refusal.
            if r.returncode != want:
                problems.append(
                    f"{gs_rel}: fed a log describing {what}, the wrapper "
                    f"exited {r.returncode} and the contract is {want}. The "
                    f"body may name every guard and still not run them — this "
                    f"pin EXECUTES it for that reason")


def check_coupling_case_refs(root, problems):
    """Every `_"…"_` reference in CLAUDE.md still resolves to something.

    CLAUDE.md's coupling table points at test cases and landmine sections BY
    TITLE — its own note says a table that quietly points at the wrong case is
    worse than one that points nowhere. Nothing read CLAUDE.md, so deleting a
    referenced case shipped green and left the table pointing at nothing.

    The reference set is classified by CONTEXT, not by string: a reference
    whose preceding prose names docs/LANDMINES.md resolves against that file,
    every other one against tests/. Anchoring on the surrounding text rather
    than guessing per string is the "assert the SELECTION" rule — a checker
    that is perfectly correct about the wrong bytes reads exactly like a
    working one.

    Matching is LINE-WISE and ellipsis-aware: `…` in a reference is an elision
    the prose made, so its fragments must appear in order on ONE line. Line-wise
    is the stricter half — a whole-file substring search would let two halves
    of a title match in two unrelated files.

    A shrinking reference set is itself a finding. `if refs:` going silent when
    a head regex stops matching is a bug this repo has already shipped once
    (_tool_loops), so "no candidates" fails rather than passing quietly.
    """
    md = root / "CLAUDE.md"
    if not md.is_file():
        return  # the validator's fixture trees carry no maintainer handoff
    text = md.read_text(encoding="utf-8")

    def lines_of(paths):
        out = []
        for p in paths:
            if p.is_file():
                out += p.read_text(encoding="utf-8", errors="replace").splitlines()
        return out

    # #115: a citation resolves against SUITE FILES (a shell/node case title)
    # or a `def test_` line in the python suite — never an arbitrary string
    # literal anywhere under tests/. The first draft of this check scanned
    # every .sh/.mjs/.py line, and CouplingCaseRefsTest's own fixture reused
    # two REAL case titles as sample data, so those fixture strings satisfied
    # the production citations: renaming the real case in tests/test-scripts.sh
    # stayed GREEN. The escape was in the fixture, not the check, but the
    # check's SELECTION made the escape possible — any string literal in any
    # file under tests/ counted as a resolution. Narrowing the selection to
    # the lines that CARRY cases (suite `check "…"` / `-- Case:` lines, node
    # test titles, python `def test_` names) closes the class: a fixture
    # string in a python body is not a def line and can no longer stand in
    # for the thing under test.
    # A string-literal CONTINUATION line (the message argument of a call whose
    # head sits on the previous line — node suites write `ok(cond,\n  "msg")`)
    # is a carrier: the title lives in that literal. Matched by quote-then-
    # content-then-close-and-comma, which a keyword or identifier cannot
    # shape, so prose continuation lines in fixtures do not slip in.
    _CONTINUATION_RE = re.compile(r'^"[^"]*"\)?[;,)]*\s*$')
    def suite_lines(p):
        if not p.is_file():
            return []
        out = []
        for ln in p.read_text(encoding="utf-8", errors="replace").splitlines():
            s = ln.strip()
            if p.suffix == ".sh":
                # A case is ASSERTED on a `check "title" …` line, DECLARED on
                # an `echo "-- Case N: title"` line, or SECTIONED by a
                # `# --- title ---` marker comment (the shape CLAUDE.md's own
                # note warns about: anchors may be section titles INSIDE a
                # case block). Everything else in the suite file — fixtures
                # it builds, strings it greps for — is data about cases, not
                # a case title.
                if s.startswith("check ") or "-- Case" in s or \
                        s.startswith("# ---"):
                    out.append(ln)
            elif p.suffix == ".mjs":
                # Assertion TITLES ride the ok()/throws() message argument
                # (`ok(cond, "#92 …: the refusal spends ZERO agents")`), cases
                # are DECLARED on `console.log("-- Case: …")`, and section
                # markers are `// ── … ──` comments — the node analog of the
                # shell `# ---` marker.
                if "-- Case" in s or s.startswith("ok(") or \
                        s.startswith("await throws(") or s.startswith("throws(") \
                        or s.startswith("// ──") or s.startswith("// ---") or \
                        _CONTINUATION_RE.match(s):
                    out.append(ln)
            elif p.suffix == ".py":
                # `def test_` names and assertFires()/assert-argument lines —
                # an assertion's EXPECTED STRING is a carrier; a fixture's
                # INPUT string (a write() body) is not, and that distinction
                # is the whole fix.
                if s.startswith("def test_") or "assertFires(" in s:
                    out.append(ln)
        return out

    tests_dir = root / "tests"
    targets = {
        "tests/": lines_of([]) + sum((suite_lines(p) for p in sorted(
            tests_dir.rglob("*")) if p.suffix in {".sh", ".mjs", ".py"}), [])
        if tests_dir.is_dir() else [],
        "docs/LANDMINES.md": lines_of([root / "docs" / "LANDMINES.md"]),
    }

    def resolves(ref, lines):
        # `…` (and `...`) is an elision: the fragments must appear IN ORDER on
        # one line, which is how every case title and landmine heading is
        # written.
        frags = [f.strip() for f in re.split(r"…|\.\.\.", ref) if f.strip()]
        for ln in lines:
            pos, ok = 0, True
            for f in frags:
                i = ln.find(f, pos)
                if i < 0:
                    ok = False
                    break
                pos = i + len(f)
            if ok:
                return True
        return False

    seen, total = set(), 0
    for m in re.finditer(r'_"([^"]+)"_', text):
        # Markdown escapes are the AUTHOR's, not the case title's: CLAUDE.md
        # writes `dev\[N\] mirror` for a case named `dev[N] mirror`.
        ref = re.sub(r"\\([\[\]().*+?^$|{}\\])", r"\1", m.group(1))
        ctx = text[max(0, m.start() - 120):m.start()]
        where = "docs/LANDMINES.md" if "LANDMINES.md" in ctx else "tests/"
        key = (where, ref)
        if key in seen:
            continue
        seen.add(key)
        total += 1
        if not resolves(ref, targets[where]):
            problems.append(
                f'CLAUDE.md: the reference _"{ref}"_ resolves nowhere in '
                f'{where}. The coupling table points at it by title, so either '
                f'the case/section was renamed or deleted and the table now '
                f'points at nothing, or the reference has a typo. Fix whichever '
                f'is true — a table that quietly points at the wrong case is '
                f'worse than one that points nowhere (CLAUDE.md, its own note)')

    # NOT a style rule. If the `_"…"_` convention changes, this scan finds
    # nothing and reports a perfect result about a set it never read — the
    # exact way _tool_loops went silent. Measured 2026-09-03: 53 references.
    _MIN_REFS = 40
    if total < _MIN_REFS:
        problems.append(
            f"CLAUDE.md: only {total} `_\"…\"_` reference(s) found, expected at "
            f"least {_MIN_REFS}. Either the coupling table lost most of its "
            f"citations, or the convention changed and this check is now "
            f"scanning for something nobody writes — in which case it reports "
            f"green about a set it never read. Reported rather than skipped")

# The registry, in run order. Both main() and the test suite iterate THIS —
# a hand-copied second list is how three guardrails (reader bounds, guard
# parity, lock parity) ended up running in the build but not in the test that
# asserts a good tree is clean, which is the test most likely to be trusted.
CHECKS = (
    check_manifests,
    check_statusline,
    check_changelog,
    check_charter,
    check_ledger_schema,
    check_handout_packet,
    check_source_stamp,
    check_decisions_schema,
    check_agents,
    check_render_templates,
    check_hook,
    check_permission_guards,
    check_scripts,
    check_reader_bounds,
    check_guard_parity,
    check_autobar,
    check_claims,
    check_install_set_parity,
    check_gitignore_parity,
    check_compressor,
    check_lock_parity,
    check_root_parity,
    check_resolver_renderer_parity,
    check_workflows,
    check_workflow_parity,
    check_workflow_default_tiers,
    check_workflow_agent_types,
    check_commands,
    check_release_gates_cover_validate,
    check_suite_floors,
    check_coupling_case_refs,
)


def main(argv=None):
    root = pathlib.Path(argv[0]) if argv else pathlib.Path(
        __file__).resolve().parent.parent
    problems = []
    for check in CHECKS:
        check(root, problems)

    if problems:
        for p in problems:
            print(f"FAIL: {p}", file=sys.stderr)
        print(f"\nvalidate_plugin: {len(problems)} contract failure(s).",
              file=sys.stderr)
        return 1
    print("validate_plugin: all contracts hold.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
