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
import json
import pathlib
import re
import subprocess
import sys

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
    measured on the F1 `*.exempt` pin with BOTH gates silent. Whole-line only:
    a trailing-comment stripper would need shell quoting, and `case` arms
    legitimately contain `#` — so a pinned literal must never sit in a trailing
    comment. GuardParityVacuityTest mutation-tests every pin.
    """
    return "\n".join(
        ln for ln in path.read_text(encoding="utf-8").splitlines()
        if not ln.lstrip().startswith("#"))


def _function_body(code, fn):
    """The lines of shell function `fn`, or None if it cannot be located.

    Returns None rather than "" so a caller can REPORT an unlocatable function
    instead of silently pinning nothing — the failure mode `check_source_stamp`
    and `check_install_set_parity` were both bitten by.

    Brace-counting, not a shell parser: these are our own files, written in one
    style (`name() {` … a closing brace at the function's own indent). A guard
    hidden in a construct this cannot follow is a guard nobody can review.

    KNOWN LIMIT, recorded because it fails toward None and None is REPORTED, not
    skipped: a K&R head (`name()` with `{` on the next line) does not match the
    locator regex. No function in scripts/*.sh is written that way — verified by
    grep — so this is unexercised, not live. The first one written will fail the
    build with "cannot locate", which is the correct direction: a security pin
    that cannot find its target must say so, never quietly pin nothing. Widen
    the regex then; do not make the caller tolerate None.

    An unbalanced `{` inside a string truncates the body early. Also the safe
    direction — a short body fails the literal search and reports.
    """
    lines = code.splitlines()
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


# The source-state stamp (U10/#22): every row's evidence cell ends with the
# tree that produced it. Pinned here because an UNSTAMPED row looks exactly
# like a stamped one until audited — no runtime consumer would announce a
# regression. The bash S1 cases are the only other thing standing on this.
# Properties three and four are F30 (declared-but-not-applied) and #21 (a marker
# that can never be off is not a marker):
#   1. every marker the resolver can emit is present in CODE, not just prose;
#   2. the row printf still builds FOUR cells, with the stamp inside cell 3 —
#      a fifth cell would break every ledger and grep in the field;
#   3. the resolved value is APPLIED at the row site;
#   4. `.operator/` is excluded from the dirty test, or every row everywhere
#      stamps +dirty and the marker stops distinguishing anything.
# Plus the ordering the PLAYBOOK's "touching the lock" step 3 demands: git work
# is resolved BEFORE lock_acquire, never inside the critical section.
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
    stamp_at = next(
        (i for i, ln in enumerate(lines) if "source_stamp" in ln), None)
    lock_at = next(
        (i for i, ln in enumerate(lines) if "lock_acquire" in ln), None)
    if stamp_at is None or lock_at is None or stamp_at > lock_at:
        problems.append(
            "scripts/ops-verdict.sh: the source stamp must be resolved "
            "BEFORE lock_acquire on the verdict path — git work inside the "
            "critical section is the PLAYBOOK's step-3 hazard")


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
        s = lib.read_text(encoding="utf-8")
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
    for name in ("ops-stop-hook.sh", "statusline.sh"):
        p = root / "scripts" / name
        if not p.is_file():
            continue  # missing-file is already reported by check_scripts
        s = p.read_text(encoding="utf-8")
        if "partition.sh" not in s:
            problems.append(
                f"scripts/{name}: does not source lib/partition.sh — the "
                f"shared partition (sentinel ownership, deviation gate) is the "
                f"one contract this bar/hook pair must not fork")
    # The verdict CLI WRITES HANDOFF-MARK; the readers above only READ it. A
    # writer that never emits the marker strands every presented decision as
    # unpresented (F30 writer half — distinct from the reader drift above).
    vp = root / "scripts" / "ops-verdict.sh"
    if vp.is_file() and "HANDOFF-MARK" not in vp.read_text(encoding="utf-8"):
        problems.append(
            "scripts/ops-verdict.sh: does not reference HANDOFF-MARK — the "
            "deviation gate's clearing mark is in the enum but this writer "
            "never emits it (F30: the enum AND its consumers must agree)")


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
    hp = root / "hooks" / "hooks.json"
    hook = load_json(hp, problems)
    if hook is None:
        return
    for event, script in (("Stop", "ops-stop-hook.sh"),
                          ("SessionStart", "ops-sessionstart-hook.sh")):
        try:
            cmd = hook["hooks"][event][0]["hooks"][0]["command"]
        except (KeyError, IndexError, TypeError):
            problems.append(f"hooks/hooks.json: no {event} hook command found")
            continue
        if script not in cmd:
            problems.append(
                f"hooks/hooks.json: {event} command does not point at "
                f"{script} (got {cmd!r})")
        if "${CLAUDE_PLUGIN_ROOT}" not in cmd:
            problems.append(
                f"hooks/hooks.json: {event} command should use "
                "${CLAUDE_PLUGIN_ROOT}")


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
    ALLOWED = {
        "ops-armgate-hook.sh": 2,   # the -x and -w halves of the unusable-.armed
                                    # guard (#19, #27), both paired with `! -d`,
                                    # both documented inert for uid 0 in place.
    }
    pat = re.compile(r"\[\s+!?\s*-[rwx]\s")
    for path in sorted((root / "scripts").glob("*.sh")):
        code = [ln for ln in path.read_text(encoding="utf-8").splitlines()
                if not ln.lstrip().startswith("#")]
        # OCCURRENCES, not lines. A line-based count makes the pin depend on
        # formatting: the two halves of the unusable-.armed guard read as 2 when
        # the condition wraps across lines and 1 when it does not, so a reflow
        # would fail the build and a fixture written on one line would silently
        # under-report. Measured both ways while writing this.
        n = sum(len(pat.findall(ln)) for ln in code)
        allowed = ALLOWED.get(path.name, 0)
        if n > allowed:
            problems.append(
                f"scripts/{path.name}: {n} permission test(s) `[ -r/-w/-x ]` in "
                f"code, allowlist permits {allowed} (#21). A permission test is "
                f"INERT for uid 0 — root bypasses mode bits, and no capability "
                f"probe distinguishes the state (measured). If this new one is a "
                f"complete guard it is wrong; if it is a best-effort half, pair "
                f"it with a test that holds on every uid (`-d` is a type test), "
                f"document the inertness at the call site, and raise the count "
                f"here with that reasoning")
        elif n < allowed:
            problems.append(
                f"scripts/{path.name}: {n} permission test(s), allowlist expects "
                f"{allowed} — a guard was REMOVED. If deliberate, lower the count "
                f"in check_permission_guards; if not, #19/#27 have regressed")


def check_armgate(root, problems):
    r"""The PreToolUse arm gate must never match `Bash` (G2/G2.7).

    The arm gate BLOCKS (exit 2). Deciding whether an arbitrary shell command
    writes is an unwinnable classification problem, and `ops-task.sh` — the only
    way to clear a denial — is itself a Bash call, so a matcher that grew `Bash`
    would deadlock the repair path: the session could neither write nor arm.
    That is this repo's recurring worst outcome (a guard that makes an existing
    task unclosable), and its loss would be silent — the gate would still look
    like it worked, right up to the first wedged session.

    Pinned here rather than left to review because the matcher is one string in
    a JSON file, and every other property of the gate is enforced by a test that
    would still pass with `Bash` in it.
    """
    hp = root / "hooks" / "hooks.json"
    hook = load_json(hp, problems)
    if hook is None:
        return
    try:
        block = hook["hooks"]["PreToolUse"][0]
    except (KeyError, IndexError, TypeError):
        problems.append(
            "hooks/hooks.json: no PreToolUse block — the arm gate (G2) is not wired")
        return
    matcher = block.get("matcher", "")
    tools = [t for t in matcher.split("|") if t]
    if "Bash" in tools:
        problems.append(
            "hooks/hooks.json: the PreToolUse arm-gate matcher includes `Bash` — "
            "it must never (G2.7): classifying shell commands is unwinnable, and "
            "gating Bash deadlocks the repair path (ops-task.sh IS a Bash call)")
    expected = {"Write", "Edit", "MultiEdit", "NotebookEdit"}
    if set(tools) != expected:
        problems.append(
            f"hooks/hooks.json: PreToolUse arm-gate matcher is {matcher!r}; "
            f"expected exactly {'|'.join(sorted(expected))} (structured "
            f"file-mutation tools only — see scripts/ops-armgate-hook.sh SCOPE)")
    try:
        entry = block["hooks"][0]
        cmd = entry["command"]
    except (KeyError, IndexError, TypeError):
        problems.append("hooks/hooks.json: PreToolUse block has no hook command")
        return
    # A timeout on the blocking gate (#33): fail-open-FAST polarity, and a hung
    # parser (a `jq` wrapping `sleep`) would otherwise stall every edit.
    t = entry.get("timeout")
    if not isinstance(t, (int, float)) or isinstance(t, bool) or t <= 0:
        problems.append(
            "hooks/hooks.json: the PreToolUse arm-gate hook has no positive "
            "`timeout` — it blocks every Write/Edit/MultiEdit/NotebookEdit "
            "synchronously, so a hung JSON parser stalls the session with no "
            "bound (measured: still blocked at 6s against a ~44ms normal path)")
    elif t > 30:
        problems.append(
            f"hooks/hooks.json: the PreToolUse arm-gate timeout is {t}s — far "
            f"above the ~44ms the hook costs; a gate that can stall an edit for "
            f"that long is not the fail-open-fast contract its header states")
    if "ops-armgate-hook.sh" not in cmd:
        problems.append(
            f"hooks/hooks.json: PreToolUse command does not point at "
            f"ops-armgate-hook.sh (got {cmd!r})")
    if "${CLAUDE_PLUGIN_ROOT}" not in cmd:
        problems.append(
            "hooks/hooks.json: PreToolUse command should use ${CLAUDE_PLUGIN_ROOT} "
            "— hooks run from the plugin root, not the project (a scripts/ path "
            "resolves only inside this repo)")
    # The gate is opt-in in 0.7.x: the switch must be READ, and its absence must
    # be the allow path. A hook that stopped consulting armgate.on would block
    # every project that never asked for the gate.
    p = root / "scripts" / "ops-armgate-hook.sh"
    if p.is_file():
        text = p.read_text(encoding="utf-8")
        if "armgate.on" not in text:
            problems.append(
                "scripts/ops-armgate-hook.sh: does not consult armgate.on — the "
                "gate is opt-in in 0.7.x; without the switch it blocks every project")
        if ".armed/" not in text and ".armed/$session" not in text:
            problems.append(
                "scripts/ops-armgate-hook.sh: does not read the .armed/ marker — "
                "the whole gate is that one stat (G2.1)")
        if ".exempt" not in text:
            problems.append(
                "scripts/ops-armgate-hook.sh: does not honour .armed/<sid>.exempt "
                "— the G3 exemption is the only escape from a blocking gate")
        # An EXISTING-but-unusable .armed must fail OPEN: without this the gate
        # denies an armed session while every documented repair is dead
        # (marker writes swallowed as success, --exempt dead after its row).
        # Pinned because every other assertion here passed with the bug present.
        code = [ln for ln in text.splitlines() if not ln.lstrip().startswith("#")]
        if not any("-d" in ln and ".armed" in ln for ln in code):
            problems.append(
                "scripts/ops-armgate-hook.sh: no `-d` test on .armed — an existing "
                "but unusable marker directory must fail OPEN, or a legitimately "
                "armed session is denied every edit with no in-band repair (the "
                "hook's own header promises this; it was once documented and "
                "unimplemented)")


def check_scripts(root, problems):
    for name in ("ops-init.sh", "ops-verdict.sh", "ops-task.sh",
                 "ops-adopt.sh", "ops-claims.sh", "ops-backlog.sh",
                 "ops-stop-hook.sh", "ops-sessionstart-hook.sh",
                 "ops-armgate-hook.sh", "statusline.sh", "ops-tiers.sh",
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
    }
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
        bounded = sum(len(re.findall(r"read -r -n \d+", ln)) for ln in code)
        unbounded = [
            ln.strip() for ln in code
            if re.search(r"\bread -r\b", ln)
            and "read -r -n" not in ln
            and "read -r -d" not in ln   # the stdin payload slurp; bounded by the payload
        ]
        if unbounded:
            problems.append(
                f"scripts/{name}: {len(unbounded)} unbounded `read -r` loop(s) — "
                f"use `read -r -n N` (a line cap is not a byte cap; see "
                f"docs/PLAYBOOK.md 'adding a reader of a file'): "
                f"{unbounded[0][:70]}")
        if bounded < expected:
            problems.append(
                f"scripts/{name}: expected >={expected} byte-bounded read(s), "
                f"found {bounded} — a reader lost its bound")
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
        elif "*__*" not in body:
            problems.append(
                f"scripts/{name}: check_bare_name() does not reject '__' — it "
                f"separates owner from task in the sentinel name, so an owner or "
                f"task-id containing it makes every reader's first-`__` split "
                f"parse a name our own writers could never have built (PR #77 "
                f"review; the arm must match ops-task.sh's copy)")
    # the readers' parser (lib/partition.sh since 0.10) must reject what the
    # writers reject, or a hand-written sentinel reads as a valid foreign owner
    # and the gate opens
    lib = root / "scripts" / "lib" / "partition.sh"
    if lib.is_file():
        text = shell_code(lib)
        if "[[:space:]]" not in text:
            problems.append(
                "scripts/lib/partition.sh: sentinel_owner does not reject "
                "whitespace owners — an owner that can never match a real "
                "session id makes its task permanently non-blocking")
    # The -L symlink rejection: the opener plus every sentinel reader (`-f`
    # follows a planted symlink; F65/F66). The Stop hook's pending/ enumeration
    # lives in lib/partition.sh since 0.10, so its obligation moved there.' owners (F65/F66, code-review of f4cae1a 2026-08-04).
    # `-f` follows symlinks; a symlink is never a sentinel our CLIs wrote.
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
    # sentinel_owner_of_name()'s reject-set must include *.exempt, mirroring
    # check_owner_name's reserved G3-grant reject (F1/#30). SCOPED TO THE
    # FUNCTION BODY: the CLIs carry `*.exempt` at the writer too, and a
    # file-wide search is satisfied by the writer alone — F1 verbatim.
    for name in ("ops-verdict.sh", "lib/partition.sh"):
        p = root / "scripts" / name
        if not p.is_file():
            continue
        text = _function_body(shell_code(p), "sentinel_owner_of_name")
        if text is None:
            problems.append(
                f"scripts/{name}: cannot locate sentinel_owner_of_name() — the F1 "
                f"reject-set pin has nothing to check. Renaming or reshaping "
                f"the parser must update this locator, not silently skip it")
            continue
        if "*.exempt" not in text:
            problems.append(
                f"scripts/{name}: sentinel_owner_of_name()'s reject-set is missing "
                f"*.exempt — a sentinel body naming a G3 grant parses as a "
                f"valid owner, letting recompute_arm_marker delete another "
                f"session's exemption (F1)")
    # F15: ops-adopt's inline PREV reject-set echoes untrusted input and must
    # degrade `.exempt` like the parsers. Matched on the PREV-assigning arm
    # (inline at top level — no function body to bind to); REPORTS on a moved
    # arm, never skips.
    p = root / "scripts" / "ops-adopt.sh"
    if p.is_file():
        prev_arms = [ln for ln in shell_code(p).splitlines()
                     if re.search(r'PREV\s*=\s*"<invalid>"', ln)]
        if not prev_arms:
            problems.append(
                "scripts/ops-adopt.sh: cannot locate the PREV reject-set arm "
                "(a line assigning PREV=\"<invalid>\") — the F15 pin has "
                "nothing to check. Reshaping that guard must update this "
                "locator, not silently skip it")
        elif not any("*.exempt" in ln for ln in prev_arms):
            problems.append(
                "scripts/ops-adopt.sh: the PREV reject-set is missing *.exempt — "
                "PREV is echoed to stdout from the untrusted sentinel body, so a "
                "reserved-suffix value must degrade to <invalid> like the three "
                "sentinel_owner parsers (F15 follow-up)")
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

    # F14: the hooks' json_get() must coerce JSON booleans to "true"/"false" —
    # a bare print(v) renders Python True/False and every `= "true"` test
    # silently fails. Pinned in the body, not a whole-file substring (F30).
    for name in ("ops-sessionstart-hook.sh", "ops-stop-hook.sh",
                 "ops-armgate-hook.sh"):
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
        if "isinstance(v, bool)" not in body:
            problems.append(
                f"scripts/{name}: json_get() is missing the "
                f"isinstance(v, bool) coercion in its body — a JSON boolean "
                f"renders Python True/False and a downstream '= \"true\"' test "
                f"silently never matches (F14; the three hooks' json_get "
                f"helpers must agree; a comment-only marker does not satisfy)")


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
    literal = re.search(r'^PROTECTED="(.*)"$', text, re.MULTILINE)
    canonical = ("scripts/validate_plugin.py tests/ .operator/bin/ hooks/ "
                 "scripts/ops-*.sh scripts/statusline.sh backlog/")
    if not literal:
        problems.append(
            "scripts/ops-claims.sh: PROTECTED literal not found — the "
            "gate-trespass protected set must be a single declared literal "
            "(F-A2: the builder cannot edit its own grader)")
    elif literal.group(1) != canonical:
        problems.append(
            f"scripts/ops-claims.sh: PROTECTED literal drifted — expected "
            f"{canonical!r}, got {literal.group(1)!r}. A divergence is two "
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
    # statusline.sh must be in the literal — it is the F66 amendment and the
    # one a prior glob missed. Match the token, not the whole literal, so a
    # reordering stays free but dropping it fires.
    if "statusline.sh" not in (literal.group(1) if literal else ""):
        problems.append(
            "scripts/ops-claims.sh: PROTECTED omits scripts/statusline.sh — "
            "it is a full sentinel reader (F66); leaving it out re-opens a "
            "parser-weakening laundering path")


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
    m = re.search(r'^_OPS_TOOLS="([^"]+)"\s*$',
                  manifest.read_text(encoding="utf-8"), re.MULTILINE)
    if not m:
        problems.append(
            "scripts/ops-install-set.sh: no plain `_OPS_TOOLS=\"…\"` assignment "
            "found — both writers source this file expecting that variable; a "
            "reshape (array, computed value) must update this locator AND both "
            "writers, not silence the pin")
        return
    tools = m.group(1).split()
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
        if not re.search(r'for _?tool in \$_OPS_TOOLS', code):
            problems.append(
                f"scripts/{name}: copy loop does not iterate $_OPS_TOOLS — "
                f"sourcing the manifest while looping an inline list is the "
                f"drift coming back with this check green (F30: "
                f"declared-but-not-applied)")
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
    # `handoff-*.md` is evidence (the HANDOFF section's artifact) and
    # `armgate.on` is a committable opt-in decision - neither is machine state
    # (#28/#31).
    ALLOW = ("!.gitignore", "!.gitattributes", "!VERDICTS.md", "!DECISIONS.md",
             "!tiers.env", "!verdicts.d/", "!verdicts.d/*.md",
             "!handoff-*.md", "!armgate.on")
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
        elif not re.search(r"grep\s+-qF\s+(?:\"\$_GI_MARK\"|'" + re.escape(MARK) + r"')", text):
            problems.append(
                f"scripts/{name}: emits the v2 marker but never greps for it — "
                f"without that read the writer cannot tell a v1 file from a v2 "
                f"one, so an existing v1 blocklist is never migrated (it is "
                f"appended to, and the two schemes contradict). Emitting the "
                f"marker is not the same claim as detecting it")
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


def check_lock_parity(root, problems):
    """ops-verdict.sh and ops-adopt.sh must carry the SAME lock implementation.

    They contend on the same `.operator/.lock`, so a divergence is not a style
    problem — it is two different ideas of mutual exclusion, and the failure it
    produces (two writers inside the critical section) is invisible until it
    corrupts the ledger of record.

    "Keep the two implementations identical" was prose in CLAUDE.md and in both
    files' comments for the whole 0.4.0 cycle. Prose cannot hold a coupling: the
    same instruction is what `check_reader_bounds` was written to replace after a
    byte bound reached one reader of four. This compares the marked block byte
    for byte, normalizing only the tool name in warning messages.

    The bash suite asserts this too, but it takes ~4 minutes to reach; the point
    of a build gate is that a maintainer editing one file learns immediately.
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

    # The LENS_NAMESPACES allowlist lived here until 0.8.3: a hand-held list of
    # facts about ANOTHER system, measured wrong against a live catalogue of
    # 409 ids (it refused 8 that route). Deleted with the allowlist. A future
    # guard needing cc-proxy facts should ASK cc-proxy — do not
    # re-copy its table into this repo, where nothing can keep it honest.

    names = {}
    for name, text in src.items():
        m = re.search(r"^(?:readonly\s+)?TIER_NAMES=([\"'])(.*?)\1",
                      text, re.MULTILINE)
        if not m:
            problems.append(
                f"scripts/{name}: no `TIER_NAMES=\"…\"` assignment found — both "
                f"the resolver and the renderer gate seat bindings on this set; "
                f"a legal refactor (renaming, retyping) must update this regex, "
                f"not silence it")
            return
        names[name] = tuple(m.group(2).split())
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

        # (b) meta is the first statement. The harness requires `export const
        # meta = {…}` as the first statement and a pure literal — a computed
        # meta is rejected at launch. Check the anchor, not the object body (the
        # runtime validates phases/whenToUse).
        #
        # …and the literal must not be COMPUTED. `whenToUse: "a" + "b"` is a
        # concatenation expression, not a literal, and the harness rejects a
        # computed meta AT LAUNCH — the workflow simply does not run, which no
        # suite here would notice because none of them launches one. plan.js
        # briefly shipped this while documenting its new required args, and it
        # was the only workflow of five to do so; a review flagged it as
        # unverifiable from inside the repo, which is exactly why it needs a pin
        # rather than a convention.
        meta_block = re.search(r"export const meta\s*=\s*\{.*?\n\};", text, re.S)
        if meta_block and re.search(r'"\s*\+|\+\s*"', meta_block.group(0)):
            problems.append(
                f"workflows/{f.name}: `meta` contains a concatenation — the harness "
                f"requires a PURE LITERAL and rejects a computed meta at launch, so "
                f"the workflow would fail to run with every gate here green")

        # No `node --check` (too lenient: exit 0 on redeclared consts and
        # unclosed parens — a gate passing 90% of real syntax errors trains
        # ignore). Real syntax errors surface at launch; the contracts below
        # are what the build can
        # actually enforce.
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
# parity invariant. BAD_CHARSET IS — it defines what "valid charset" means, and
# a divergence between two workflows' copies is a silent disagreement about
# which ids are well-formed.
# ROUTABLE was dropped from this tuple in 0.8.3 along with the guard itself
# (see check_workflows (c)); BAD_CHARSET is what remains to hold in parity.
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
        if not re.search(r'NEVER_COMPRESS\.has\(\s*tool\s*\)\s*\)\s*return null', code):
            problems.append("ops-compress.mjs: NEVER_COMPRESS.has(tool) call site missing a `return null` body (a neutered body skips the exclusion — F48)")
            break  # one missing call site is the same defect for all four
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
        if not re.search(rf"{k}:\s*{v}\b", src):
            problems.append(f"ops-compress.mjs: pinned default {k}={v} is missing or changed — the replay test asserts these exact numbers")
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
        sst = ss.read_text(encoding="utf-8")
        for d in (".compress-spill", ".compress-state"):
            if d not in sst:
                problems.append(f"ops-sessionstart-hook.sh: does not clear `{d}` — a stale dedup hash after a compact collapses output the model can no longer see")


def check_release_gates_cover_validate(root, problems):
    """
    release.yml must run every suite validate.yml runs (#38): a tag build
    publishes, so its gate must be a superset, and it was a strict subset —
    both node suites ran on every PR and on no release. Compares suite
    commands, not run blocks (they legitimately differ elsewhere).
    """
    wf = root / ".github" / "workflows"
    val, rel = wf / "validate.yml", wf / "release.yml"
    if not val.is_file() and not rel.is_file():
        return  # a tree with no CI at all — nothing to compare
    if not val.is_file() or not rel.is_file():
        # ONE present and the other absent is reported, not skipped: that is a
        # half-configured CI, and the whole point of this check is that the
        # publishing job must not be the weaker one. Only the both-absent case
        # above is a legitimate skip (the validator's own fixtures build a
        # plugin tree without workflows).
        missing = val.name if not val.is_file() else rel.name
        problems.append(
            f".github/workflows: {missing} is missing while its counterpart "
            f"exists — cannot verify that a tag build gates at least as much "
            f"as a PR build")
        return
    # The runners this project uses. Matched as substrings of the file text so
    # a step's formatting (block scalar, inline, extra flags) does not matter.
    SUITES = (
        "tests/test-scripts.sh",
        "tests/test_workflows.mjs",
        "tests/test_compress.mjs",
        "validate_plugin.py",
        "unittest discover",
    )
    vtext = val.read_text(encoding="utf-8")
    rtext = rel.read_text(encoding="utf-8")
    for suite in SUITES:
        if suite in vtext and suite not in rtext:
            problems.append(
                f".github/workflows/release.yml: runs no `{suite}` step while "
                f"validate.yml does — the tag build that PUBLISHES gates less "
                f"than the PR build that does not (#38)")


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
    check_armgate,
    check_permission_guards,
    check_scripts,
    check_reader_bounds,
    check_guard_parity,
    check_claims,
    check_install_set_parity,
    check_gitignore_parity,
    check_compressor,
    check_lock_parity,
    check_resolver_renderer_parity,
    check_workflows,
    check_workflow_parity,
    check_workflow_default_tiers,
    check_workflow_agent_types,
    check_commands,
    check_release_gates_cover_validate,
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
