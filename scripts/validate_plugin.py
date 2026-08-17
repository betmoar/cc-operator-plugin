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

    Every pin that asserts "this guard exists" by searching for a literal must
    search THIS, never `read_text()`. A raw-text search is satisfied by the
    comment that explains the guard, so deleting the guard while leaving its
    comment — the realistic regression, since the comment is what a careless
    edit preserves — keeps the validator green. Measured on 2026-08-14: removing
    `*.exempt` from `ops-stop-hook.sh`'s reject-set while its two explanatory
    comment lines stayed put left BOTH gates silent (validator "all contracts
    hold", bash 590/0). The F1 pin was guarding its own documentation.

    Whole-line only, deliberately: a trailing-comment stripper would have to
    understand shell quoting, and `case` arms legitimately contain `#`. So a
    pinned literal must not sit in a TRAILING comment — that text lands in the
    "code" this returns and re-opens the vacuity. ops-verdict.sh:552 was exactly
    that and was moved onto its own line; a scan of every pinned literal
    (`*.exempt`, `[[:space:]]`, `check_bare_name()`, `check_owner_name()`, `.*)`)
    across scripts/*.sh found no other. Re-run that scan when adding a pin.

    Found by the Copilot review of PR #56, which flagged two of the seven sites;
    the other five had the same hole. `test_validate_plugin.py` now mutation-
    tests every one of them (`GuardParityVacuityTest`) rather than pinning the
    helper's existence — a shared helper nobody calls is the same vacuity one
    level up.
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
# the packet in plain English and drifted (F69): it dropped TEXT, the SHA and
# the `CHANGED:` line — and CHANGED is the input ops-claims.sh verifies, so a
# user taught from the handout runs the worker-boundary layer unchecked. The pin
# is against teaching a WRONG packet, so it applies only when the file exists:
# deleting the handout is a visible act; drifting it is not.
#
# `REACH` (#57, 0.8.4) is in the spine for a reason the two originals illustrate:
# they are the packet's FIRST and LAST fragments, so a field inserted in the
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


# The source-state stamp (U10, issue #22): every verdict row's evidence cell ends
# with the state that produced it, so a PASS names exactly one tree. Pinned here
# because the failure it closes is invisible by construction — an UNSTAMPED row
# looks exactly like a stamped one until someone tries to audit it, and there is
# no runtime consumer whose breakage would announce a regression. The bash
# suite's S1 cases are the only other thing standing on this.
#
# Four properties. The third and fourth are the F30 lesson (a literal declared
# and never applied is the defect one level up) and the #21 lesson (a marker
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
    # "Applied" means the ROW carries it, not that the identifier appears
    # somewhere: `SOURCE_STAMP="$(source_stamp)"` alone satisfied a substring
    # test, so swapping the row's own `"$SOURCE_STAMP"` argument for a literal
    # left every row unstamped with the build green (Copilot review of PR #12,
    # measured 2026-08-12) — the F30 declared-but-not-applied shape inside the
    # check written to prevent it. Inspect the printf's argument list.
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
    # Ordering, on the verdict path's own section: a `git status` inside the
    # lock lengthens the critical section, and a holder that outruns
    # LOCK_LIVE_SPINS leaves its waiters proceeding UNLOCKED.
    #
    # The split runs on the RAW text and the comment strip happens after, in
    # that order and not the other way round: the section marker is itself a
    # comment, so splitting `code` finds nothing, takes the not-found branch,
    # and skips the assertion entirely. That draft passed a mutation that moved
    # the stamp inside the lock — the check was fail-open, which is the one
    # direction the PLAYBOOK does not allow a guard to fail. Not-found is now a
    # reported problem for the same reason.
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


# The DECISIONS-header kind set — split into GATED (block Stop until presented),
# RECORD (logged, never block), and the HANDOFF-MARK marker (clears the gated
# set). The hook/statusline deviation gate counts ONLY the GATED kinds; the
# schema must advertise that split so a reader does not mistake a non-gated
# record (DECISION/DEFERRED-VERDICT) for a kind that should block Stop
# (issue #9, F30). Pin each token AND the gated/record grouping.
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
    # Both deviation-gate readers must count EXACTLY the gated kinds: a reader
    # that widened to DECISION would gate routine notes, and one that dropped a
    # kind would miss unpresented decisions (issue #9, F30 call-site half).
    for name in ("ops-stop-hook.sh", "statusline.sh"):
        p = root / "scripts" / name
        if not p.is_file():
            continue  # missing-file is already reported by check_scripts
        s = p.read_text(encoding="utf-8")
        if DECISIONS_GATED_LITERAL not in s:
            problems.append(
                f"scripts/{name}: deviation gate does not count the gated kinds "
                f"({DECISIONS_GATED_LITERAL!r}) — must match the header's gated "
                f"set exactly (issue #9)")
        if "HANDOFF-MARK" not in s:
            problems.append(
                f"scripts/{name}: does not reference HANDOFF-MARK — the "
                f"deviation gate's clearing mark is in the enum but this reader "
                f"never matches it, so a presented decision reads as unpresented "
                f"forever (F30: the enum AND its consumers must agree)")
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

    # No CR in any splice SOURCE. render_to()'s awk anchors its frontmatter
    # delimiters on /^---$/, which `---\r` never matches — pre-F29 that skipped
    # every substitution branch and copied the file through verbatim, shipping
    # an agent with the template's stale model: value at exit 0. The renderer
    # now strips CR itself, so this is defense in depth against the source
    # drifting to CRLF (a Windows checkout, an editor default) rather than the
    # only guard.
    #
    # agents/op-*.md is checked too, NOT just _templates/: render_to tries the
    # plugin-root agent file FIRST as the body source (F14, single-source
    # bodies), so it is the likelier splice input of the two.
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
    # A BOUND on the blocking gate (issue #33). This hook runs synchronously
    # before every file mutation and its whole polarity is fail-open-FAST; with
    # no timeout, a hung parser stalls every edit indefinitely. Measured: a `jq`
    # on PATH containing `sleep 300` left the hook still blocked at 6s, while the
    # normal path costs ~44ms — so any small bound is ~100x headroom and the
    # pathological case becomes bounded instead of unbounded. The PostToolUse
    # compressor in the same file already carries one; this block did not.
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
        # An EXISTING-but-unusable .armed (a regular file, a chmod accident) must
        # fail OPEN. Without this the gate denies a legitimately armed session
        # AND every documented repair is dead: ops-task.sh/ops-adopt.sh swallow
        # their marker write and report success, --exempt dies after its ledger
        # row lands. Measured unwritable-and-unrepairable (PR review 2026-08-07).
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
    """Every reader of a sentinel/fragment must bound its reads in BYTES.

    `read -r` is bounded by LINES, not bytes — one newline-less line is a single
    "line" and gets slurped whole. Measured on a 256MB single-line file:
    0.17s bounded vs 13.5s / 16.8s / 32.6s unbounded across the three readers
    that were missed when the bound was first added to the Stop hook only.

    The 32.6s one mattered most: it happens while holding the ledger lock, whose
    crash-presumption budget is 30s, so a concurrent writer reclaimed a LIVE
    reconcile's lock and both entered the critical section.

    This is a coupling no prose can enforce — the rule lives in CLAUDE.md and was
    still applied to one of four readers. Now it fails the build instead.
    """
    readers = {
        "ops-stop-hook.sh": 2,   # sentinel_owner + the DECISIONS.md deviation scan
        "ops-verdict.sh": 2,     # sentinel_owner + the --reconcile fragment loop
        "ops-adopt.sh": 1,       # the inline sentinel parse
        # The statusline segment renders on a ~300ms timer, which makes it the
        # hottest reader here by three orders of magnitude — the others run once
        # per turn-end or per command. Measured on one 64MB newline-less
        # sentinel: 0.014s bounded vs 6.20s per parse unbounded, i.e. a
        # permanently wedged status bar rather than a slow one.
        "statusline.sh": 2,      # sentinel_owner + the dev[N] reverse-tail scan
        # The tier-config resolver reads a file under .operator/ (untrusted — a
        # merge or checkout can produce it). Same hazard class as the others:
        # a newline-less multi-MB tiers.env is one "line" to an unbounded read.
        "ops-tiers.sh": 1,       # the load_file config loop
        # ops-render.sh parses the same tiers.env with the same bounded loop.
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
        # The NUL probe (`read -r -d '' -n 512`) must be BOUNDED by a chunk
        # counter, not loop the whole file. An uncapped probe still detects a
        # late NUL but walks a newline-less multi-MB file end-to-end first —
        # measured 66-70s on a 64MB tiers.env vs 0.11s capped (bash 3.2.57,
        # 2026-08-04 — the 4.0s first cited is wrong by ~15x), defeating the
        # bounded-reader guarantee this check exists to enforce. The Stop hook
        # established the canonical capped form (F59); this keeps tiers/render
        # from drifting back to the uncapped loop. The `-n 512` inside the
        # probe is itself a `read -r -n \d+`, so it is already counted above as
        # a bounded read; here we additionally require the cap to accompany it.
        # Match ANY NUL-probe loop, not the literal variable name `_nulprobe`:
        # a rename would otherwise carry the probe out of the check's sight
        # entirely (the first version required `_nulprobe` and a renamed,
        # uncapped probe passed clean — code-review of f4cae1a, 2026-08-04).
        nul_probes = [
            i for i, ln in enumerate(code)
            if re.search(r"read -r -d '' -n \d+ \w+", ln)
        ]
        for i in nul_probes:
            # The counter + cap must appear within the same probe block (the
            # few lines from the `while` to the chunk-size check), and the
            # cap's VALUE is parsed and bounded — the first version substring-
            # matched "le 40", which `-le 400000` (effectively uncapped)
            # satisfies (same review). Two file classes, two legal scales:
            # sentinel/config probes cap at 40 chunks (20KB — the owner is line
            # 1); the DECISIONS.md deviation scans cap at 4096 (2MB — the ledger
            # is append-forever, bounded by DECISIONS_MAX_BYTES). The ceiling is
            # 8192 (4MB): above the largest legitimate probe, below the
            # effectively-uncapped `le 400000` that defeats the bound.
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


def check_platform_idioms(root, problems):
    """Ban idioms that pass on one platform and silently fail on the other.

    Two families, same failure signature — green where the author runs it, wrong
    where the other half of the world runs it.

    ONE: the try-BSD-then-GNU fallback.

    `stat -f %m F || stat -c %Y F` looks portable and is not. On GNU coreutils
    `-f` means FILESYSTEM status and the format goes via `-c`, so `stat -f %m F`
    treats BOTH operands as files: `%m` errors (exit 1) while F prints a
    filesystem block to STDOUT. In a command substitution that partial stdout is
    CONCATENATED with the fallback's output — the value is garbage, every
    numeric comparison on it fails, and the feature dies silently on Linux while
    passing on the maintainer's Mac. Exactly how the statusline's wf segment
    shipped broken (its first CI run caught it; four cases red).

    Same shape, same silence: `date -v-5M` (BSD) vs `date -d '5 min ago'` (GNU).
    A test that backdates with the wrong one gets an EMPTY string, `touch -t ""`
    fails, and the "stale" assertion passes for the wrong reason.

    The rule: PROBE the flavor once and branch, or use a form both accept
    (`touch -t <literal>`). Never `A || B` across platform dialects where A can
    emit stdout before failing.

    TWO: a brace group inside a DOUBLE-QUOTED sed script. `sed -n "/^f() {$/,/^}$/p"`
    is correct under bash 5 and mangled under bash 3.2 — which is still
    /bin/bash on every macOS — once it sits inside `"$( … )"`: the nested double
    quotes do not survive that parse, `{$/,/^}` becomes a BRACE EXPANSION, and
    sed receives a split script ("invalid command code $"). The extraction it was
    driving silently produces nothing.

    That is worse than a normal portability bug because of WHERE it lands. The
    measured instance (tests/test-scripts.sh, fixed 2026-08-17) was a control
    assertion — the one asserting that a guard had been exercised. It could not
    pass on darwin, and CI's bash 5 parsed it correctly and reported green, so
    the local suite was red and the only visible signal said fine. #21's class
    with the polarity inverted: not a guard that cannot fail, a control that
    cannot pass.

    Single-quote the sed script. Nothing in a sed address needs interpolation,
    and a single-quoted script is immune at every nesting depth.
    """
    # A brace group is only expandable when unquoted or double-quoted, so the
    # pattern requires the double quote. `[^"}]*` on both sides of the comma
    # keeps it inside one brace group rather than spanning two arguments.
    sed_brace = re.compile(r"""sed\s+(?:-[a-zA-Z]+\s+)*"[^"]*\{[^"}]*,[^"}]*\}""")
    bad = (
        (sed_brace,
         "a brace group inside a double-quoted sed script — bash 3.2 (every "
         "macOS /bin/bash) brace-expands it inside \"$( … )\" and sed gets a "
         "split script, while bash 5 parses it correctly and CI stays green; "
         "single-quote the sed script"),
        (re.compile(r"stat\s+-f\s+%\w+.*\|\|.*stat\s+-c"),
         "stat -f … || stat -c … — GNU `-f` prints filesystem info to stdout "
         "before failing, so the fallback CONCATENATES garbage; probe the "
         "flavor once and branch (see statusline.sh:mtime)"),
        (re.compile(r"stat\s+-c\s+%\w+.*\|\|.*stat\s+-f"),
         "stat -c … || stat -f … — same trap in the other order; probe once "
         "and branch (see statusline.sh:mtime)"),
        (re.compile(r"date\s+-v[-+]"),
         "date -v is BSD-only (empty output on GNU); use a literal "
         "`touch -t YYYYMMDDhhmm` or probe the flavor"),
        (re.compile(r"date\s+-d\s"),
         "date -d is GNU-only (fails on BSD); use a literal "
         "`touch -t YYYYMMDDhhmm` or probe the flavor"),
    )
    targets = sorted((root / "scripts").glob("*.sh"))
    tsh = root / "tests" / "test-scripts.sh"
    if tsh.is_file():
        targets.append(tsh)
    for p in targets:
        rel = p.relative_to(root)
        for i, line in enumerate(p.read_text(encoding="utf-8").splitlines(), 1):
            if line.lstrip().startswith("#"):
                continue  # the ban is documented at length in comments
            for rx, why in bad:
                if rx.search(line):
                    problems.append(f"{rel}:{i}: {why}")


def check_guard_parity(root, problems):
    """The three CLIs must agree on what a name may contain.

    A guard enforced in one place only is the shape of the 2026-07-10 traversal
    bug. `check_bare_name` (filename safety) and `check_owner_name` (additionally
    compared against a session id) are deliberately separate — conflating them
    wedged every pre-0.4 task whose id contained a space.
    """
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
    # the hook's parser must reject what the writers reject, or a hand-written
    # sentinel reads as a valid foreign owner and the gate opens
    hook = root / "scripts" / "ops-stop-hook.sh"
    if hook.is_file():
        text = shell_code(hook)
        if "[[:space:]]" not in text:
            problems.append(
                "scripts/ops-stop-hook.sh: sentinel_owner does not reject "
                "whitespace owners — an owner that can never match a real "
                "session id makes its task permanently non-blocking")
    # The -L symlink rejection is a FIVE-site coupling: the opener plus every
    # sentinel reader. It was first applied to ops-task.sh alone, and every
    # read site kept following planted symlinks — adopt laundered them into
    # real sentinels, verdict closed them into the ledger, the hook and bar
    # read their targets' owners (F65/F66, code-review of f4cae1a 2026-08-04).
    # `-f` follows symlinks; a symlink is never a sentinel our CLIs wrote.
    for name in ("ops-task.sh", "ops-verdict.sh", "ops-adopt.sh",
                 "ops-stop-hook.sh", "statusline.sh"):
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
    # sentinel_owner()'s reject-set must include *.exempt in all three body
    # parsers, mirroring check_owner_name's reject of the reserved G3 grant
    # namespace — else a corrupted body "session_id: victim.exempt" parses as
    # a valid owner and recompute_arm_marker deletes another session's grant
    # (F1, issue #30).
    #
    # SCOPED TO THE FUNCTION BODY, not the file. ops-verdict.sh carries
    # `*.exempt` TWICE in real code: check_owner_name's writer-side die (line
    # ~161) and sentinel_owner's parser-side reject (~552). A file-wide search
    # is satisfied by the writer alone — which is F1 itself, verbatim: "rejects
    # .exempt at the writer but not the body parser". The pin would have
    # green-lit the exact regression it was written to prevent. Caught by
    # GuardParityVacuityTest when the file-wide version failed to fire on a
    # parser-only deletion (2026-08-14).
    for name in ("ops-verdict.sh", "ops-stop-hook.sh", "statusline.sh"):
        p = root / "scripts" / name
        if not p.is_file():
            continue
        text = _function_body(shell_code(p), "sentinel_owner")
        if text is None:
            problems.append(
                f"scripts/{name}: cannot locate sentinel_owner() — the F1 "
                f"reject-set pin has nothing to check. Renaming or reshaping "
                f"the parser must update this locator, not silently skip it")
            continue
        if "*.exempt" not in text:
            problems.append(
                f"scripts/{name}: sentinel_owner()'s reject-set is missing "
                f"*.exempt — a sentinel body naming a G3 grant parses as a "
                f"valid owner, letting recompute_arm_marker delete another "
                f"session's exemption (F1)")
    # F15 follow-up: ops-adopt.sh's inline PREV reject-set is a FIFTH copy of
    # the owner-reject pattern. It reads the same untrusted sentinel body and
    # echoes PREV to stdout, so it must carry the same reserved-suffix guard
    # — else a PREV ending in .exempt is echoed verbatim (the stdout-injection-
    # adjacent path F15 closed) with no parity check catching the regression
    # (the loop above is scoped to the three sentinel_owner parsers; this was
    # the gap the final review surfaced).
    #
    # SCOPED TO THE PREV CASE-ARM, for the same reason the F1 loop above is
    # scoped to a function body — and this site had the identical hole, found by
    # the review panel one round after the F1 one was fixed here. ops-adopt.sh
    # carries `*.exempt` TWICE in real code: check_owner_name's writer-side die
    # (~389) and this parser-side reject (~498). A file-wide search is satisfied
    # by the writer alone, so deleting `| *.exempt` from the PREV arm left BOTH
    # gates silent — validator "all contracts hold" AND bash 590/0 (measured
    # 2026-08-14). That is F15 reopened by the check meant to pin it shut.
    #
    # Matched on the arm rather than a function body because PREV's reject-set
    # is inline at top level, not inside a function — `_function_body` has
    # nothing to bind to. The arm is identified by what only it does: assign
    # PREV. REPORTS when it cannot find the arm, never skips.
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
    # F2: the F65 -L guard was applied to the five pending/ sites but never to
    # the verdicts.d/ evidence-fragment directory. A planted symlink at
    # .operator/verdicts.d/<owner>.md -> arbitrary-file makes append_fragment
    # append every row for that owner THROUGH the link (exit 0, silent), and
    # both read sites follow it. The file-wide "any -L in the file" check above
    # could not see this hole — ops-verdict.sh already carries -L for pending/.
    # Pin the verdicts.d/-specific guard: an -L test must reference a
    # verdicts.d fragment path in append_fragment and both read sites.
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
    # F17: both fragment scanners in ops-verdict.sh — the --reconcile read loop
    # and retro_gate's prior-row scan — must use the SAME `read -r -n N` bound.
    # They read the same verdicts.d/ fragment body, so a long evidence cell
    # (>512B) that splits into chunks at one site but not the other is a drift
    # that silently drops honest rows from the ledger on every reconcile (the
    # issue-#9 long-row blindness class — the reconcile site kept 512 while
    # retro_gate moved to 1MiB). Pin them EQUAL, not just present: the two reads
    # are copy-paste neighbors, so uniform drift to a smaller bound would pass a
    # mere "both bounded" check.
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

    # F14: the three hooks' json_get() helpers must agree. A JSON boolean
    # renders Python True/False under a bare print(v), so a downstream
    # [ "$x" = "true" ] silently never matches. ops-stop-hook.sh and
    # ops-armgate-hook.sh carry the isinstance(v, bool) -> "true"/"false"
    # coercion; ops-sessionstart-hook.sh omitted it (no live trigger today —
    # it reads only string fields — but the drift is real and the next
    # boolean field added would ship broken). Pin the coercion in the CODE of
    # json_get's body, not as a whole-file substring: a marker only in a
    # comment (or a moved fragment) would satisfy a bare substring search and
    # let the real coercion revert silently (final-review follow-up; modeled
    # on check_resolver_renderer_parity's body extraction).
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
    r"""The .operator/bin install set is now declared in TWO files: ops-init.sh
    (the authoritative install on /cc-operator:start) and ops-sessionstart-hook.sh
    (the automated upgrade path). A fifth CLI added to one and not the other ships
    green — every upgraded project silently never receives it (CR4, code-review
    2026-08-04). This is the F30 shape the repo's check_claims docstring argues
    against. Pin the two literals equal.

    Either writer may spell the set inline (`for _tool in ops-verdict.sh …`) or
    via a variable it assigns (`_OPS_TOOLS="…"` / `for _tool in $_OPS_TOOLS`);
    ops-sessionstart-hook.sh needs the variable because its staleness probe and
    its copy loop must iterate the SAME set, and a second inline copy would be
    one more place to drift. Both spellings resolve to the same list here.

    A writer whose set cannot be located is REPORTED, not skipped. The earlier
    version returned None for an unmatched file and then guarded with
    `if a and b`, so refactoring one writer to a variable silently reduced the
    comparison to nothing — the check passed while pinning zero (measured
    2026-08-12 while fixing #34). A parity check that goes quiet when it stops
    understanding its input is worse than no parity check.
    """
    inline = re.compile(r'for _?tool in (ops-verdict\.sh ops-task\.sh ops-adopt\.sh[^;]*)')
    via_var = re.compile(r'^_OPS_TOOLS="([^"]*)"', re.MULTILINE)
    sets = {}
    for name in ("ops-init.sh", "ops-sessionstart-hook.sh"):
        p = root / "scripts" / name
        if not p.is_file():
            continue
        text = p.read_text(encoding="utf-8")
        m = inline.search(text) or via_var.search(text)
        if not m:
            problems.append(
                f"scripts/{name}: cannot locate the .operator/bin install set "
                f"(neither `for _tool in ops-verdict.sh …` nor `_OPS_TOOLS=\"…\"`) "
                f"— check_install_set_parity is reporting rather than skipping, "
                f"because a parity check that cannot read one side pins nothing "
                f"(CR4)")
            continue
        sets[name] = " ".join(m.group(1).split())
        # A variable spelling only helps if it is what the copy loop iterates.
        if via_var.search(text) and not re.search(r'for _?tool in \$_OPS_TOOLS', text):
            problems.append(
                f"scripts/{name}: declares _OPS_TOOLS but its copy loop does not "
                f"iterate it — the declared set and the installed set are then "
                f"two different lists (F30: declared-but-not-applied)")
    a, b = sets.get("ops-init.sh"), sets.get("ops-sessionstart-hook.sh")
    if a and b and a != b:
        problems.append(
            f"install-set drift: ops-init.sh installs [{a}] but "
            f"ops-sessionstart-hook.sh upgrades [{b}] — a CLI in one and not the "
            f"other means upgraded projects never receive it (CR4; the two lists "
            f"must stay equal)")


def check_gitignore_parity(root, problems):
    r"""The .operator/.gitignore v2 allowlist body is written in TWO places:
    ops-init.sh (_gi_write, on /cc-operator:start) and ops-sessionstart-hook.sh
    (the every-session v1 migration). Drift means a project migrated by one path
    ignores a different set than one migrated by the other — and the direction
    that bites is silent: an allow line present in ops-init but missing in the
    hook un-tracks a ledger the moment a session starts. Same F30 shape as
    check_install_set_parity: two copies, uniform drift is the realistic failure.

    Pins the bare `*` AND the ALLOW lines, in both writers, plus the marker they
    grep for to detect a v1 file.

    The `*` is pinned because it is what makes this an allowlist at all, and its
    loss is the silent direction: drop it and the file inverts back to a v1
    blocklist — every ephemera directory (`bin/`, `pending/`, `.lock/`,
    `.compress-spill/`) becomes TRACKED by default, which is precisely the
    recurring failure v2 exists to end. An earlier version of this docstring
    called `*` "the load-bearing half" and then checked only the allow lines;
    dropping `*` from a writer left the build green (Copilot review, PR #12).
    Naming an invariant in prose while pinning a different one is the F30 shape
    this check was written to prevent, reproduced inside the check itself.
    """
    MARK = "# cc-operator gitignore v2 (allowlist)"
    IGNORE_ALL = "*"
    # `handoff-*.md` and `armgate.on` are evidence/policy, not machine state:
    # the handoff is the artifact the charter's HANDOFF section exists to
    # produce (commands/handoff.md writes `.operator/handoff-<date>.md`), and
    # armgate.on is the project's opt-in DECISION, which a team must be able to
    # commit once rather than re-make in every clone. Both were ignored by the
    # v2 allowlist's bare `*` — the handoff a REGRESSION from v1, which tracked
    # it (measured against main's ops-init.sh in a fresh repo). Issues #28/#31.
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
        # EMIT and DETECT are two claims, and the message above makes both — but
        # a substring test proves only the first: the heredoc body contains the
        # marker, so deleting the migration `grep` left the build green while
        # every existing v1 project silently stopped being detected (Copilot
        # review of PR #12, measured 2026-08-12 in both writers). Assert the
        # detection expression separately. Either spelling counts: ops-init.sh
        # greps the `$_GI_MARK` variable, the hook greps the literal, because
        # the hook must stay standalone.
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

    # MIGRATION SAFETY, both writers. The v1→v2 migration REPLACES a file the
    # user may have edited, and both writers advertise `.gitignore.v1.bak` as
    # the recovery path. Before 2026-08-12 the backup was `cp … 2>/dev/null`
    # followed by an UNCONDITIONAL write, so a failed backup destroyed the rules
    # while the notice claimed they were recoverable (measured in both writers:
    # an unwritable `.operator/`, and a `.v1.bak` that is already a directory).
    # The invariant is ordering, which no allowlist comparison can see: the
    # write must be REACHABLE ONLY through a successful backup. Pinned as "the
    # copy is tested, and the body-writer is inside the success branch" — a
    # `cp … 2>/dev/null` on its own line, with the write following it
    # unconditionally, is exactly the shape that shipped.
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
    """ops-tiers.sh and ops-render.sh must agree on check_routable and on the
    canonical tier set.

    Both parse the same tiers.env and both refuse an id the other would refuse —
    that agreement was prose ("share check_routable byte-aligned" in CLAUDE.md's
    coupling table) with nothing enforcing it, while the two neighbouring
    duplications (the bash lock, the workflow regexes) each got a parity check
    after the same lesson. A divergence here means the renderer writes a seat
    binding the resolver would have rejected, or refuses one the resolver
    accepts: two different ideas of which model ids exist.

    TIER_NAMES is the second copy. _resolver_tier_names reads it from
    ops-tiers.sh only, and check_workflow_tier_namespace holds the workflows to
    that; ops-render.sh declares its own literal and nothing checked it. A fifth
    tier added per the coupling table's instructions would leave the renderer's
    is_tier_name gating a stale namespace — accepting or rejecting the wrong
    set, with a `die` message listing tiers that disagree with the resolver's.

    Compared as normalized token streams, not byte-for-byte: the two copies are
    line-wrapped differently for readability, and reflowing a `case` arm is not
    a semantic change. Whitespace collapses; everything else must match.
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
        # Equality alone is satisfied by two IDENTICALLY gutted copies — the
        # same hole CANONICAL_BAD_CHARSET closed for the workflow regexes,
        # reachable here by commenting the body out in both files (comments are
        # stripped above). Pin the load-bearing reject to its content.
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

    # The LENS_NAMESPACES pin lived here until 0.8.3 — an allowlist of five
    # cc-proxy provider namespaces, pinned twice over (equal across the two
    # files AND equal to a canonical literal) because equality alone had proven
    # vacuous. All of that machinery existed to hold a list of facts about
    # ANOTHER system in sync by hand, and the list was already wrong: measured
    # against a live catalogue of 409 ids, the guard it fed refused 8 that
    # cc-proxy routes. Deleted with the allowlist itself. If a future guard
    # needs to know something about cc-proxy's namespaces, ASK cc-proxy — do not
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
    """Every workflows/*.js must (a) be syntactically valid JS, (b) begin with a
    `export const meta = {...}` first statement, (c) NOT re-declare a ROUTABLE
    id-shape guard, and (d) carry BAD_CHARSET pinned to its canonical literal
    AND applied at a `.test(id)` call site.

    (c) IS INVERTED FROM WHAT IT USED TO BE, and the inversion is the point.
    Until 0.8.2 a ROUTABLE constant was REQUIRED here and pinned to a canonical
    id-shape regex. 0.8.3 deleted it: a shape catalogue is operator asserting
    which model ids exist, which is the user's choice (tiers.env / args.model)
    and cc-proxy's routing decision. So the check now fires on ROUTABLE's
    PRESENCE — the only presence-check in this file — because the re-add is the
    reflex fix when an unguarded id reaches dispatch and every other gate stays
    green. See the inline comment at the call site for the failure it prevents.

    The model values an agent() call receives are tier *constants* (JUDGMENT,
    MECHANICAL, …), resolved through DEFAULT_TIERS. So this check does NOT
    regex-extract model strings from agent() call sites — that would be brittle
    (they are variables, not literals) and redundant with the runtime throw.
    Instead it validates the GUARD INFRASTRUCTURE, mirroring check_guard_parity
    (validate the guard exists, not the guarded data). With ROUTABLE gone,
    BAD_CHARSET is the only id guard a workflow carries, so (d) now bears alone
    what two pins used to share: a neutered `.test(id)` call site has nothing
    behind it.
    """
    wf_dir = root / "workflows"
    files = sorted(wf_dir.glob("*.js")) if wf_dir.is_dir() else []
    if not files:
        return  # workflows/ is optional; the plugin ships review.js only at need
    # CANONICAL_ROUTABLE lived here until 0.8.3, pinning an id-shape alternation
    # across every workflow copy. It is gone with the guard it pinned: the shape
    # catalogue was operator asserting which model ids exist, which is the
    # user's choice and cc-proxy's routing decision (see ops-tiers.sh
    # check_routable). The pin was doing its job perfectly — it held four copies
    # of a wrong list in exact agreement, which is why the wrongness survived
    # three releases. A pin is only as good as the thing it pins.
    #
    # BAD_CHARSET keeps its pin and inherits the full weight: it is now the only
    # id guard the workflows carry, so a mutation to /(?!)/ has no second line
    # of defence behind it.
    CANONICAL_BAD_CHARSET = r"/[^\w./:@[\]-]/"
    for f in files:
        rel = f"workflows/{f.name}"
        text = f.read_text(encoding="utf-8")

        # A comment-stripped view for the APPLICATION checks (`X.test(`): a call
        # site moved into a comment must not satisfy the "is it applied" regex
        # while the real guard is gone — the F48/F57 class, demonstrated live
        # against this very check by the full-PR panel (commenting both .test
        # call sites in review.js left the validator green while an unroutable,
        # quote-bearing id reached agent()). Strip block then line comments,
        # exactly as check_compressor does (F57). The DECLARATION checks below
        # still run on raw `text`: BAD_CHARSET's not-found branch reads the
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
        # No `node --check` here: it is too lenient to gate on (measured
        # 2026-07-30 — returns exit 0 on redeclared consts, unclosed parens,
        # and dangling expressions; only structural nonsense like a stray `}`
        # fails). A gate that passes 90% of real syntax errors trains
        # maintainers to ignore the build. A genuine syntax error surfaces at
        # launch time regardless; the contracts below are what the build can
        # actually enforce.
        body = text.lstrip()
        if not body.startswith("export const meta ="):
            problems.append(
                f"{rel}: does not begin with `export const meta = {{…}}` as the "
                f"first statement (the harness requires a pure-literal meta block "
                f"first, or it refuses to launch the workflow)")

        # (c) a re-introduced id-shape guard is a REGRESSION, not an upgrade.
        # This is the only check in this file that fires on a guard's PRESENCE.
        # It exists because the deletion above is easy to undo by reflex — a
        # future maintainer sees an unguarded id reach dispatch, writes
        # `const ROUTABLE = /^(?:glm-|claude-)…/`, and every test still passes,
        # because the tests never asked whether operator SHOULD judge model ids.
        # It should not: the user picks the model, cc-proxy routes it. Whatever
        # symptom prompted the re-add, a hardcoded id catalogue in this repo is
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

        # (d) the charset guard — pinned to a canonical literal, and proven
        # applied. Since 0.8.3 it is the ONLY id guard, so this pin carries what
        # two used to.
        #
        # check_workflow_parity compares the copies to EACH OTHER, which is
        # necessary but not sufficient: a review mutated BAD_CHARSET to /(?!)/
        # in all four workflows at once and every gate stayed green (node 25/25,
        # validator rc 0), because four identically-broken files are trivially
        # "in parity". This closes that hole for the guard that rejects
        # whitespace and quotes — and since 0.8.3 removed the id-shape guard
        # that used to sit beside it, this is the last one standing.
        # Uniform drift is the realistic failure — a maintainer edits the block
        # once and copies it to the other three, exactly as the copy-paste
        # convention instructs.
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


# The shared invariants every workflow must carry identically. The workflow
# sandbox forbids `import()` (measured 2026-07-30 — "import() is not available
# in workflow scripts"), so the tier-validation block is COPY-PASTED across
# review/brainstorm/plan rather than imported from a shared module. With no
# dedup possible, byte-parity across the copies is the only thing that holds
# them together — the same lesson check_lock_parity enforces for the bash
# lock block. DEFAULT_TIERS is excluded: each workflow deliberately declares
# only the tiers it uses (review has 2, brainstorm 3, plan 3), so it is NOT a
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


# The canonical tier namespace the resolver may emit. Workflows accept overrides
# against THIS set (KNOWN_TIERS), not their smaller DEFAULT_TIERS — otherwise a
# valid resolver key a workflow happens not to use (IMPLEMENT in review) is
# rejected and forwarding the resolver's full map throws (audit F07). The guard
# is the inverse coupling of WORKFLOW_PARITY_CONSTS: the regexes must not drift
# APART across workflows, and KNOWN_TIERS must not drift FROM the resolver.
TIER_NAMES_SRC = "scripts/ops-tiers.sh"


def _resolver_tier_names(root, problems):
    """Read the TIER_NAMES literal from ops-tiers.sh, as a sorted tuple.

    Fails LOUD — appends a problem and returns None on any read failure, rather
    than silently disabling check_workflow_tier_namespace (the fail-open a review
    caught: deleting ops-tiers.sh or single-quoting TIER_NAMES made the whole
    namespace check pass with rc 0). A None return therefore ALWAYS carries a
    problem; callers treat None as "unreadable, already reported" and skip the
    per-workflow equality loop, not as "no constraint".

    Accepts both quote styles and an optional `readonly` prefix so a legal shell
    refactor of the TIER_NAMES line cannot silently turn the guard off.
    """
    p = root / TIER_NAMES_SRC
    if not p.is_file():
        return None  # missing-file is check_scripts' job (ops-tiers.sh is required)
    m = re.search(r'^\s*(?:readonly\s+)?TIER_NAMES=["\']([^"\']+)["\']',
                  p.read_text(encoding="utf-8"), re.MULTILINE)
    if not m:
        problems.append(
            f"{TIER_NAMES_SRC}: no `TIER_NAMES=\"…\"` assignment found — the "
            f"canonical tier namespace is unreadable, so check_workflow_tier_"
            f"namespace cannot hold the resolver↔workflow contract (F07). A legal "
            f"refactor (renaming, retyping) must update this regex, not silence it.")
        return None
    return tuple(sorted(m.group(1).split()))


def check_workflow_tier_namespace(root, problems):
    """Each workflow's KNOWN_TIERS array must equal the resolver's TIER_NAMES.

    KNOWN_TIERS is the set of tier keys a workflow accepts in args.tiers; the
    resolver (ops-tiers.sh TIER_NAMES) is the set it may emit. If a workflow's
    KNOWN_TIERS omits a resolver tier, forwarding the resolver's full map throws
    on a legitimate key — the F07 bug. If it adds one the resolver does not know,
    a typo is no longer caught. Keep them equal; the array is copy-pasted per the
    import-forbidden sandbox, so a check is the only thing holding it.
    """
    canonical = _resolver_tier_names(root, problems)
    wf_dir = root / "workflows"
    files = sorted(wf_dir.glob("*.js")) if wf_dir.is_dir() else []
    for f in files:
        rel = f"workflows/{f.name}"
        text = f.read_text(encoding="utf-8")
        # CODE lines only — a KNOWN_TIERS appearing solely in a comment must NOT
        # satisfy this check (matches the check_reader_bounds convention; a review
        # caught that raw-text matching made `// const KNOWN_TIERS=…` pass).
        code = "\n".join(ln for ln in text.splitlines()
                         if not ln.lstrip().startswith("//"))
        m = re.search(r"const\s+KNOWN_TIERS\s*=\s*\[([^\]]*)\]", code)
        if not m:
            problems.append(
                f"{rel}: no `const KNOWN_TIERS = [...]` found — a workflow must "
                f"validate args.tiers keys against the canonical tier namespace "
                f"(see audit F07: rejecting a valid resolver tier breaks the "
                f"forwarding path)")
            continue
        got = tuple(sorted(t.strip().strip('"').strip("'")
                           for t in m.group(1).split(",") if t.strip()))
        if canonical is not None and got != canonical:
            problems.append(
                f"{rel}: KNOWN_TIERS={list(got)} does not match the resolver's "
                f"TIER_NAMES={list(canonical)} in {TIER_NAMES_SRC} — a workflow "
                f"must accept every tier the resolver may emit or forwarding the "
                f"resolver map throws on a valid key (F07)")


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
        # Match the VALUE, not the `agentType:` key. The key form was blind to
        # the one file that most needed checking: dispatch.js resolves its
        # agentType from a SEATS lookup and passes it as the shorthand property
        # `agentType,`, so the old regex found ZERO matches there — while
        # dispatch.js's own comment and CLAUDE.md's coupling row both claimed
        # this check was the reason its SEATS map is a literal. Measured: every
        # one of the six SEATS values retyped to a nonexistent agent shipped
        # green (validator rc 0, node 100/0, pytest 213/0). The value form
        # covers both spellings — a literal at the call site AND a literal in a
        # lookup table — which is what "names no shipped agent" always meant.
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
    """The input-axis compressor's carve-outs, per spec I1/I2 (Validator guardrails §2).

    The compressor is the only component that REWRITES what the model reads, so
    its exclusion lists are load-bearing in a way ordinary config is not: drop
    `Read` from the allowlist and the model edits against text it never saw;
    drop a ledger path and a mid-body elision of PASS rows falsifies the exact
    artifact this plugin exists to protect. Both lists are therefore byte-checked
    here rather than trusted to review.
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

    # Strip comments so a regex cannot match prose that merely mentions a
    # pattern (the inverse of F48: a call site written ABOUT in a comment would
    # satisfy a call-site check while the real call site is gone). BOTH syntaxes:
    # the first draft stripped `//` lines only, and a call site moved into a
    # /* */ block still satisfied every guard regex — the same F48 class through
    # the other comment syntax, and block comments are an existing idiom in this
    # file (pr-review, 2026-08-03). The non-greedy DOTALL sub is not a JS lexer
    # (a string literal containing `/*` would confuse it), but no guarded
    # pattern lives inside a string, so a false strip cannot green a broken file
    # — it can only redden a weird-but-correct one, which is the safe direction.
    code = re.sub(r"/\*.*?\*/", "", src, flags=re.DOTALL)
    # Strip TRAILING line comments too, not just whole comment lines: a call
    # site deleted and its pattern relocated into a trailing comment
    # (`const _x = 1; // NEVER_COMPRESS.has(tool)) return null`) left the real
    # guard gone while the regex still matched the comment text (full-PR panel,
    # finding 5b). `//` inside a string or a regex literal (e.g. a URL, or the
    # `/\/\//` idiom) is not a comment, but no guarded pattern lives after a
    # `//` in a string here, and a false strip can only redden a correct file,
    # never green a broken one — the safe direction, same as the block strip.
    code = "\n".join(
        re.sub(r"//.*$", "", ln)
        for ln in code.split("\n")
        if not ln.lstrip().startswith("//")
    ).strip()

    # 2a. I1 — the never-compress set. These break exact-match editing if
    # elided. F48's lesson, now applied correctly: EACH name must be both in the
    # set LITERAL and reach a `return null` via the .has(tool) call site. The
    # first draft of this check hardcoded "Read" in the literal clause, so
    # dropping Edit/Write/NotebookEdit left the validator green — those tools
    # silently became elidable (pr-review, 2026-08-03). Per-tool now.
    for tool in ("Read", "Edit", "Write", "NotebookEdit"):
        if not re.search(rf'NEVER_COMPRESS\s*=\s*new Set\([^)]*"{tool}"', code):
            problems.append(f"ops-compress.mjs: `{tool}` is not in the NEVER_COMPRESS set literal (dropping it makes the tool elidable — I1; F48)")
        if not re.search(r'NEVER_COMPRESS\.has\(\s*tool\s*\)\s*\)\s*return null', code):
            problems.append("ops-compress.mjs: NEVER_COMPRESS.has(tool) call site missing a `return null` body (a neutered body skips the exclusion — F48)")
            break  # one missing call site is the same defect for all four
    # 2a'. ELIDABLE is the allowlist that DECIDES what gets elided; the first
    # draft of this check never looked at it, so a maintainer could add a
    # never-compress tool to ELIDABLE and (paired with a weakened NEVER_COMPRESS)
    # elide a Read (full-PR panel, finding 5a). The load-bearing invariant is
    # DISJOINTNESS: no NEVER_COMPRESS tool may appear in the ELIDABLE literal.
    # Pin that directly rather than the membership list (which is free to grow).
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

    # 2b/2c. I2.1/I2.2 — the evidence-gate carve-out. Each PATH/CLI must be in
    # its array literal AND the .some() call must carry `return null` (a neutered
    # `.some(() => false)` would otherwise pass a bare `.some(` check). The first
    # draft checked only that the arrays contained the strings AND a bare
    # `.some(` — which a comment or a neutered body defeated.
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


# Issue references. Three FORMS ship in this tree, and only two are checkable:
#
#   [#27]                       reference-style use, needs a matching link def
#   [#27]: https://…/issues/27  the link def
#   [#22](https://…/issues/22)  inline link (docs/INFOGRAPHICS.md)
#   (#21) / `issue #9`          BARE — deliberately NOT checked, see below
#
# Each linked form captures (number, url) in that order, so the pair can be
# cross-checked with one loop.
#
# The `(?![:(])` on the USE pattern excludes the def and inline forms, which are
# matched by their own patterns. It deliberately does NOT allow whitespace
# before `:`/`(`: CommonMark requires the `(` of an inline link to follow the
# `]` immediately, so `[#9] (a note)` IS a reference-style use, and an `\s*`
# here would silently drop it from `uses` — a dangling ref that never reports.
ISSUE_USE_RE = re.compile(r"\[#(\d+)\](?![:(])")
ISSUE_DEF_RE = re.compile(r"^\[#(\d+)\]:[ \t]*(\S+)", re.MULTILINE)
ISSUE_INLINE_RE = re.compile(r"\[#(\d+)\]\((\S+?)\)")
ISSUE_URL_RE = re.compile(r"https?://\S*?/issues/(\d+)")

# A markdown span whose contents are quoted, not live: fenced/indented-fence
# code blocks and inline code spans. A `[#28]` inside one is an ILLUSTRATION of
# a reference, not a reference — this file's own CHANGELOG entry documents the
# inverted-ref class by quoting `[#28]` in backticks, and without this the check
# reads its own prose as a live ref and drags an unrelated def into the release
# body. Stripped before parsing, so spans are invisible to every pattern above.
MD_CODE_RE = re.compile(r"^[ \t]*(```|~~~).*?^[ \t]*\1[ \t]*$|`+[^`\n]*`+",
                        re.DOTALL | re.MULTILINE)

# GitHub issue URLs legitimately carry a fragment or query — `#issuecomment-N`
# is what the "copy link" button on a comment produces. The number ends at the
# first `/`, `#`, or `?`; everything after is addressing WITHIN the issue and
# must not be compared against the label.
ISSUE_TARGET_RE = re.compile(r"^(\d+)(?:[/#?].*)?$")


def check_issue_refs(root, problems):
    r"""Issue references in tracked markdown must resolve to THIS repo and to
    the number they claim.

    Three failure modes:

      1. **Label/URL mismatch.** `[#28]: …/issues/29` renders as "#28", links to
         29, and reads correct in every review — the eye checks the label, the
         click follows the URL, and nothing compares them.
      2. **Dangling / orphan.** A `[#N]` with no link def renders as literal
         "[#N]" in the published output; a def nobody uses is a leftover from a
         rewrite that silently stops being maintained.
      3. **Foreign repo.** A URL pasted from another project's tracker resolves,
         200s, and points at someone else's issue. Pinned to plugin.json's
         `repository`, which is already the manifest's single source of truth.

    **Honest provenance: mode 1 has never occurred in this repo.** An earlier
    revision of this docstring claimed two 0.7.0 commits shipped inverted refs
    and cited 6b9fb89 / ff57517. Measured against the history, that is wrong:
    6b9fb89 wrote `[#28]: …/issues/28` — label and URL AGREED — and ff57517
    never touched CHANGELOG.md. Their real defect was an *invented* issue
    number, written before the issue existed and later assigned to a different
    one (90094f8's message says exactly that). No commit in this repo's history
    carries a label≠URL mismatch: all historical def lines agree.

    That matters, because **this check would not have caught the bug that was
    used to justify it.** A wrong-but-self-consistent number is invisible here
    and always will be — catching it means asking GitHub what the issue is
    about. What this check does buy is cheap and real: modes 2 and 3 are
    mechanical, and mode 1 is the one that survives review by construction, so
    pinning it before it happens costs a regex and prevents a class that is
    genuinely hard to see by eye.

    **What it deliberately does NOT check: that the issue exists, is open, or
    is about what the sentence says.** That needs `gh issue view` — network, a
    token, and a rate limit — in a validator whose other subprocess is a local
    `bash -n`. A build that fails because GitHub is slow teaches maintainers to
    skip the build.

    **Bare `#N` is out of scope, by measurement.** Tracked markdown uses `#N`
    for things that are not issues at all — `Backlog #2` (docs/LANDMINES.md),
    `task #1` (docs/spec/backlog-charter.md), `F48 #5`. Requiring those to be
    linked would force either wrong links or an exception list, and an
    exception list for prose is a rot generator. The convention enforced is
    narrower and honest: *if* you write a reference-style or inline issue link,
    it must be internally consistent.

    Scope is `git ls-files '*.md'` — tracked files only. Untracked local audit
    trails (`docs/audits/`, `AUDIT_LOG.md`) are maintainer scratch that no
    reader of the clone can follow anyway, and `docs/spec/` is gitignored
    wholesale; a gate whose verdict depends on files absent from the repo gives
    two clones two answers. When git is unavailable OR lists nothing, the scope
    falls back to a glob that skips dot-directories. That fallback is a superset
    of the tracked set **only while no tracked `.md` lives under a dot-directory**
    (none does today; `.github/` and `.claude-plugin/` ship no markdown). It is
    not an absolute guarantee — if one is ever added, the fallback goes blind to
    it, and the primary git path is what must carry the load. An empty git
    listing is never taken at face value: that is the F48 vacuous-guard shape,
    a check that passes because it examined nothing.

    A file git tracks but cannot be read is REPORTED, not skipped. The usual
    cause is a sparse checkout: `git ls-files` reports index entries, so a
    sparse-excluded file is listed but absent from the working tree, and
    swallowing that `FileNotFoundError` means the check silently inspects fewer
    files than it appears to — measured: a foreign-repo link in a sparse-
    excluded file produced zero problems instead of two.
    """
    plugin = root / ".claude-plugin" / "plugin.json"
    try:
        repo_url = json.loads(
            plugin.read_text(encoding="utf-8")).get("repository")
    except (FileNotFoundError, json.JSONDecodeError):
        return  # already reported by check_manifests
    if not repo_url:
        problems.append(
            "plugin.json: no `repository` — check_issue_refs cannot tell a "
            "reference to this project's tracker from a foreign one")
        return
    expected_base = repo_url.rstrip("/") + "/issues/"

    files = []
    try:
        listing = subprocess.run(
            ["git", "-C", str(root), "ls-files", "-z", "*.md"],
            capture_output=True, text=True, check=True)
        files = [n for n in listing.stdout.split("\0") if n]
    except (OSError, subprocess.CalledProcessError):
        pass  # not a checkout (or no git) — the glob below is the fallback
    if not files:
        files = sorted(
            str(p.relative_to(root))
            for p in root.rglob("*.md")
            if not any(part.startswith(".") for part in p.relative_to(root).parts))

    for rel in sorted(files):
        path = root / rel
        try:
            text = path.read_text(encoding="utf-8")
        except FileNotFoundError:
            # git tracks it, the working tree does not have it — a sparse
            # checkout, or an index desynced from disk. Categorically different
            # from a permission error: the file EXISTS as far as the repo is
            # concerned, so skipping it silently means the gate quietly covers
            # less than it claims. Report and move on.
            problems.append(
                f"{rel}: tracked by git but absent from the working tree "
                f"(sparse checkout?) — check_issue_refs cannot inspect it, so "
                f"this file is NOT covered by the gate")
            continue
        except (OSError, UnicodeDecodeError):
            continue  # unreadable or not text; not this check's business

        # Code spans and fenced blocks quote references, they do not make them.
        # Stripping them first is what keeps this file's own CHANGELOG entry —
        # which documents the inverted-ref class by writing `[#28]` in
        # backticks — from being read as a live reference.
        text = MD_CODE_RE.sub("", text)

        uses = set(ISSUE_USE_RE.findall(text))
        # NOT dict(findall): a repeated `[#N]:` would collapse to the LAST one,
        # while CommonMark resolves to the FIRST — so the check would validate
        # a URL the renderer never uses. Keep every occurrence and check each.
        defs = ISSUE_DEF_RE.findall(text)
        def_nums = {num for num, _ in defs}
        inline = ISSUE_INLINE_RE.findall(text)

        dupes = sorted({n for n, _ in defs
                        if sum(1 for m, _ in defs if m == n) > 1}, key=int)
        for num in dupes:
            problems.append(
                f"{rel}: `[#{num}]:` is defined more than once — markdown "
                f"resolves the FIRST and ignores the rest, so the later "
                f"definitions are invisible at render time; delete them")

        for num in sorted(uses - def_nums, key=int):
            problems.append(
                f"{rel}: `[#{num}]` is used reference-style but has no "
                f"`[#{num}]: <url>` definition — it publishes as the literal "
                f"text `[#{num}]`, not a link")
        for num in sorted(def_nums - uses, key=int):
            problems.append(
                f"{rel}: `[#{num}]:` is defined but never used — a leftover "
                f"from a rewrite; delete it or restore the reference")

        # Label vs URL, for both linked forms. This is the inverted-ref catch.
        # Every URL reached here is also matched by the bare-URL scan below, so
        # each is recorded and excluded there — one fault, one problem line.
        labelled_urls = set()
        for num, url in sorted(defs, key=lambda p: int(p[0])) + inline:
            labelled_urls.add(url)
            if not url.startswith(expected_base):
                problems.append(
                    f"{rel}: `[#{num}]` points at {url!r}, which is not "
                    f"{expected_base}<n> — an issue link must resolve in THIS "
                    f"repo's tracker (plugin.json `repository`)")
                continue
            # Everything after the number addresses a location WITHIN the issue
            # (`#issuecomment-N`, `?tab=`, a trailing `/`) and is not part of
            # the identity. Comparing it against the label reports a legitimate
            # deep link — the form GitHub's own "copy link" produces — as an
            # inverted ref.
            m = ISSUE_TARGET_RE.match(url[len(expected_base):])
            if not m:
                problems.append(
                    f"{rel}: `[#{num}]` points at {url!r} — the path after "
                    f"{expected_base} is not an issue number")
                continue
            if m.group(1) != num:
                problems.append(
                    f"{rel}: `[#{num}]` links to issue {m.group(1)} — the label "
                    f"and the URL disagree, so it reads as #{num} everywhere "
                    f"and navigates to #{m.group(1)} (the inverted-ref class)")

        # A bare issue URL carrying no label cannot be cross-checked against a
        # number, but it can still be foreign.
        for m in ISSUE_URL_RE.finditer(text):
            url = m.group(0)
            # `labelled_urls` holds FULL urls (ISSUE_DEF_RE captures `\S+`, so a
            # fragment is included) while this pattern stops at the number — so
            # match by prefix, not equality, or a labelled deep link reports
            # twice.
            if any(u.startswith(url) for u in labelled_urls):
                continue  # already judged, with a better message, above
            if not url.startswith(expected_base):
                problems.append(
                    f"{rel}: issue URL {url!r} is not under {expected_base} — "
                    f"a reference to another project's tracker")


def check_replay_charter(root, problems):
    r"""Every CLI invocation the replay charter tells a human to type must
    resolve: the script exists, and the flags it passes exist in that script.

    **Why this check exists, stated bluntly: two runs of the replay charter, and
    the defective party was the charter itself both times.** The 2026-08-12 run
    found `bash .operator/bin/ops-init.sh` — a command that could never have
    run, because ops-init is the one CLI NOT in the install set (it creates
    `bin/`). The 2026-08-14 run found three phases invoking
    `${CLAUDE_PLUGIN_ROOT}/scripts/…`, which is unset in the Bash tool env and
    expands to `/scripts/…` (#62). Neither is subtle; both survived because
    nothing read the charter except a human following it under load, who worked
    around the breakage live and recorded the phase green. That is the exact
    shape this repo's guards exist to catch, applied to the one document that
    audits the guards.

    **Resolvability ONLY.** No execution, no network, no semantic claim. This
    cannot tell you the expected-output strings still match the scripts (prose,
    maintained by hand — CLAUDE.md says so), whether a phase proves what it
    says, or whether a flag is passed sensibly. It answers one question: would
    this command die with "no such file" or "unknown option" before doing
    anything? That is a small question with a measured 100% hit rate on the
    charter's real defects to date.

    Scope is deliberately narrow to stay quiet:

      - Only lines that look like an INVOCATION — a path ending in `ops-*.sh`
        followed by arguments — are parsed. A bare mention (``ops-verdict.sh``
        in prose, or the install-set enumeration in R1) is not a command and is
        skipped, or every sentence naming a CLI becomes a finding.
      - `<placeholder>` arguments are ignored; the charter is a template.
      - A path is resolved by BASENAME against `scripts/`, because the charter
        legitimately writes three different bases for the same file
        (`.operator/bin/…`, `$PR/scripts/…`, bare) and they are all the same
        script at different install points. What matters is that the name is a
        CLI this plugin ships.
      - Flags are checked against the target script's own `--flag` literals,
        with COMMENTS STRIPPED FIRST. That is not tidiness: the charter's #64
        negative control types `--ownr` on purpose, and the fix for #64 put the
        word `--ownr` in ops-verdict.sh's explanatory comment — so the lookup
        passed against prose describing the bug rather than against any code.
        Measured here while mutation-checking this very function. A flag the
        script never mentions in code is a typo or a rename that left the
        charter behind — the #64 class, one level up.
      - A **negative control** is exempt, and declares itself: if the line
        carrying the invocation also says the command must be refused (`must
        exit non-zero`, `must be refused`), the flag is deliberately invalid
        and is not checked. The charter needs to type wrong commands — rule 3
        requires one per phase — and a lint that forbids them would forbid the
        controls. Requiring the expectation ON THE SAME LINE keeps that from
        becoming an escape hatch: a charter line that types a bad flag and says
        nothing about it is still a finding.

    The charter is untracked-adjacent but real: it ships in-tree, it is the
    protocol a release "claiming a live-verified gate" must run, and a broken
    command in it costs a replayer a phase. If the file is absent (a stripped
    tree), skip — like every other doc check here, this one grades what ships.
    """
    charter = root / "docs" / "REPLAY-CHARTER.md"
    if not charter.is_file():
        return
    try:
        text = charter.read_text(encoding="utf-8")
    except OSError as exc:
        problems.append(f"docs/REPLAY-CHARTER.md: unreadable ({exc})")
        return

    scripts_dir = root / "scripts"
    # An invocation: an optional path prefix, then ops-<name>.sh, then the rest
    # of the line. The prefix alternatives are the three the charter uses; a
    # bare name counts only when arguments follow (that is what separates a
    # command from a mention). The tail skips a closing quote before the
    # arguments — `bash "$PR/scripts/ops-init.sh" --owner X` is the real shape,
    # and a tail anchored on whitespace alone matched none of them, which made
    # the missing-script branch below unreachable (measured while mutation-
    # checking this function: renaming an invoked script produced no finding).
    inv_re = re.compile(
        r"(?:\$PR/scripts/|\.operator/bin/|\$\{CLAUDE_PLUGIN_ROOT\}/scripts/)?"
        r"(ops-[a-z-]+\.sh)\"?((?:[ \t]+[^\n`|]+)?)")
    # A flag in the argument tail. `--` alone (end-of-options) is not a flag.
    flag_re = re.compile(r"(?<![\w-])--([a-z][a-z-]*)")
    # A line that declares its own command invalid — see the docstring. Kept
    # narrow and literal so it cannot be satisfied by incidental prose.
    control_re = re.compile(r"must (?:exit non-zero|be refused|fail)")

    lines = text.splitlines()
    seen = set()
    for m in inv_re.finditer(text):
        name, tail = m.group(1), m.group(2) or ""
        flags = flag_re.findall(tail)
        if not flags:
            continue  # a mention, or a flagless form — nothing to resolve
        line_no = text.count("\n", 0, m.start()) + 1
        # The expectation may wrap onto the next line — the charter hard-wraps
        # at 80. Two lines, not the whole paragraph: the point is that the
        # control declares itself AT the command.
        window = " ".join(lines[line_no - 1:line_no + 1])
        is_control = bool(control_re.search(window))
        target = scripts_dir / name
        key = (name, tuple(sorted(set(flags))), is_control)
        if key in seen:
            continue
        seen.add(key)
        if not target.is_file():
            problems.append(
                f"docs/REPLAY-CHARTER.md:{line_no}: invokes `{name} "
                f"--{flags[0]} …` but scripts/{name} does not exist — a "
                f"replayer following this literally hits a missing command "
                f"(the 2026-08-12 run's `.operator/bin/ops-init.sh` defect)")
            continue
        if is_control:
            continue  # a deliberately-wrong command with its refusal stated
        # shell_code(), NOT read_text(): a flag named only in a COMMENT is not
        # a flag the CLI has. ops-verdict.sh documents `--ownr` at length while
        # rejecting it, and a raw-text lookup passed on that prose.
        try:
            body = shell_code(target)
        except OSError as exc:
            problems.append(f"scripts/{name}: unreadable ({exc})")
            continue
        for flag in flags:
            # `--flag)` in a case arm, `--flag=*`, or the flag inside a usage
            # string all count as "this script knows this word" — the question
            # is resolvability, not parse position.
            if f"--{flag}" not in body:
                problems.append(
                    f"docs/REPLAY-CHARTER.md:{line_no}: invokes `{name} "
                    f"--{flag}` but scripts/{name}'s CODE never mentions "
                    f"`--{flag}` — the charter names a flag the CLI does not "
                    f"have (state the refusal on the line if it is a control)")

    # THE VACUITY FLOOR — the check must prove it still examined something.
    #
    # Everything above is regex-driven against the charter's current markdown
    # shape (inline code spans, these three path prefixes). Change the charter's
    # convention — fence the commands, rename the CLI prefix, quote differently
    # — and `inv_re` matches nothing, `seen` stays empty, and this function
    # reports zero problems: indistinguishable from "every command resolves".
    # Measured: a charter describing the same commands in prose ("run the tool
    # named opsVerdict with flag ownerFlag") produced [] findings.
    #
    # That is the F48 class this very check exists to catch one level down, and
    # the floor belongs in the FUNCTION rather than in a test: it then protects
    # any charter, not just this repo's. The bound is deliberately low — a real
    # charter drives the gate CLIs many times over (this one, well clear of the
    # floor; the exact count is deliberately not written down, since it changes
    # with any charter edit and a stale number here is the rot this file warns
    # about elsewhere) — so it fires
    # on a convention change, never on ordinary editing.
    MIN_INVOCATIONS = 5
    if len(text.split()) > 200 and len(seen) < MIN_INVOCATIONS:
        problems.append(
            f"docs/REPLAY-CHARTER.md: this check resolved only {len(seen)} "
            f"CLI invocation(s) in a {len(text.splitlines())}-line charter — "
            f"below the floor of {MIN_INVOCATIONS}. Either the charter stopped "
            f"driving the gate CLIs, or its command convention changed and the "
            f"parser above no longer matches it. A silently-zero result reads "
            f"exactly like a clean pass (F48)")

    # The variable the 2026-08-14 run tripped over. It is legitimate in PROSE
    # (the charter explains why it is unset) but never inside a command: a
    # `bash "${CLAUDE_PLUGIN_ROOT}/scripts/…"` line expands to `/scripts/…` in
    # the Bash tool env. Distinguish by looking only at lines that RUN it.
    for i, line in enumerate(text.splitlines(), 1):
        if "CLAUDE_PLUGIN_ROOT" not in line:
            continue
        if re.search(r"(?:bash|sh|cmp -s .*)\s+\"?\$\{CLAUDE_PLUGIN_ROOT\}", line):
            problems.append(
                f"docs/REPLAY-CHARTER.md:{i}: a command runs "
                f"${{CLAUDE_PLUGIN_ROOT}}, which is NOT set in the Bash tool "
                f"environment — it expands to `/scripts/…` and fails (#62). "
                f"Use the $PR the charter resolves in R0.")


def check_release_gates_cover_validate(root, problems):
    """release.yml must run every test suite validate.yml runs.

    A tag build publishes; a PR build does not. So the release job has to be a
    SUPERSET of the validate job, and it was a strict subset (#38): both node
    suites — 148 cases over the workflow layer and the compressor — ran on
    every PR and on no release. 0.7.1 changed the ROUTABLE regex in all four
    workflows, code test_workflows.mjs covers, and the tag build that shipped it
    would not have run one case over it.

    The failure was invisible because release.yml's own header says it "re-runs
    the full validation". A gate that names one scope and enforces another is
    the class docs/PLAYBOOK.md exists to catch, and nothing compared the two
    files.

    Compares the SUITE COMMANDS, not whole `run:` blocks: the two jobs
    legitimately differ elsewhere (release_gate.py, `gh release create`), and
    shellcheck is invoked through docker in both with slightly different
    argument spelling. What must not diverge is which test runners execute.
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
    check_issue_refs,
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
    check_platform_idioms,
    check_guard_parity,
    check_claims,
    check_install_set_parity,
    check_gitignore_parity,
    check_compressor,
    check_lock_parity,
    check_resolver_renderer_parity,
    check_workflows,
    check_workflow_parity,
    check_workflow_tier_namespace,
    check_workflow_agent_types,
    check_commands,
    check_replay_charter,
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
