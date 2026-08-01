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
CHARTER_REQUIRED_CLIS = ("ops-task.sh", "ops-verdict.sh", "ops-adopt.sh")
AGENT_MODEL_ALIASES = ("opus", "sonnet", "haiku")


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


def check_scripts(root, problems):
    for name in ("ops-init.sh", "ops-verdict.sh", "ops-task.sh",
                 "ops-adopt.sh", "ops-stop-hook.sh",
                 "ops-sessionstart-hook.sh", "statusline.sh", "ops-tiers.sh",
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
        "ops-stop-hook.sh": 1,   # sentinel_owner
        "ops-verdict.sh": 2,     # sentinel_owner + the --reconcile fragment loop
        "ops-adopt.sh": 1,       # the inline sentinel parse
        # The statusline segment renders on a ~300ms timer, which makes it the
        # hottest reader here by three orders of magnitude — the others run once
        # per turn-end or per command. Measured on one 64MB newline-less
        # sentinel: 0.014s bounded vs 6.20s per parse unbounded, i.e. a
        # permanently wedged status bar rather than a slow one.
        "statusline.sh": 1,      # sentinel_owner
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


def check_platform_idioms(root, problems):
    """Ban the try-BSD-then-GNU fallback idiom in scripts and tests.

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
    """
    bad = (
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
        text = p.read_text(encoding="utf-8")
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
        text = hook.read_text(encoding="utf-8")
        if "[[:space:]]" not in text:
            problems.append(
                "scripts/ops-stop-hook.sh: sentinel_owner does not reject "
                "whitespace owners — an owner that can never match a real "
                "session id makes its task permanently non-blocking")


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


def check_workflows(root, problems):
    """Every workflows/*.js must (a) be syntactically valid JS, (b) begin with a
    `export const meta = {...}` first statement, and (c) carry the tier guard —
    a ROUTABLE constant matching the canonical cc-proxy id shape AND a loop that
    applies ROUTABLE.test to every resolved tier before dispatch.

    The model values an agent() call receives are tier *constants* (JUDGMENT,
    MECHANICAL, …), resolved through DEFAULT_TIERS and validated at runtime by
    ROUTABLE.test. So this check does NOT regex-extract model strings from
    agent() call sites — that would be brittle (they are variables, not
    literals) and redundant with the runtime throw. Instead it validates the
    GUARD INFRASTRUCTURE: the regex that the runtime uses to refuse an
    unroutable id, and that it is actually applied. This mirrors
    check_guard_parity (validate the guard exists, not the guarded data).

    An unroutable id — a typo, a retired version — falls through to cc-proxy's
    default backend at dispatch time, a silent mis-route deep inside a run with
    no build-time signal. The runtime ROUTABLE.test catches it; this check
    ensures a maintainer cannot silently remove or drift that guard while
    editing a workflow. The canonical regex is the same shape check_routable
    enforces in ops-tiers.sh and the same one every workflow shipped with.
    """
    wf_dir = root / "workflows"
    files = sorted(wf_dir.glob("*.js")) if wf_dir.is_dir() else []
    if not files:
        return  # workflows/ is optional; the plugin ships review.js only at need
    CANONICAL_ROUTABLE = r"/^glm-|\/|^claude-/"
    for f in files:
        rel = f"workflows/{f.name}"
        text = f.read_text(encoding="utf-8")

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

        # (c) the tier guard. Two requirements, both structural:
        #   - ROUTABLE is declared with the canonical cc-proxy id shape
        #   - a loop applies ROUTABLE.test to every resolved tier (Object.entries
        #     over TIERS, the resolved table). The loop is what makes an
        #     unroutable id fail at resolve time, not dispatch time.
        routable_decl = re.search(r"const\s+ROUTABLE\s*=\s*(/\S.*?)\s*;", text)
        if not routable_decl:
            problems.append(
                f"{rel}: no `const ROUTABLE = …` declaration found — every "
                f"workflow must validate tiers against the cc-proxy id shape "
                f"before dispatch (an unroutable id otherwise silently falls "
                f"through to the default backend)")
        else:
            # Direct equality on the matched regex literal against the canonical.
            got = routable_decl.group(1).strip()
            if got != CANONICAL_ROUTABLE.strip():
                problems.append(
                    f"{rel}: ROUTABLE regex is {got!r}, expected "
                    f"{CANONICAL_ROUTABLE.strip()!r} — cc-proxy routes by id "
                    f"shape; a divergent regex either over-accepts (silent "
                    f"mis-route) or under-accepts (rejects valid ids)")

        if not re.search(r"ROUTABLE\.test\s*\(", text):
            problems.append(
                f"{rel}: ROUTABLE is declared but never applied — a tier must be "
                f"checked with `ROUTABLE.test(id)` inside the tier-resolution loop "
                f"or an unroutable id reaches dispatch unchecked")


# The shared invariants every workflow must carry identically. The workflow
# sandbox forbids `import()` (measured 2026-07-30 — "import() is not available
# in workflow scripts"), so the tier-validation block is COPY-PASTED across
# review/brainstorm/plan rather than imported from a shared module. With no
# dedup possible, byte-parity across the copies is the only thing that holds
# them together — the same lesson check_lock_parity enforces for the bash
# lock block. DEFAULT_TIERS is excluded: each workflow deliberately declares
# only the tiers it uses (review has 2, brainstorm 3, plan 3), so it is NOT a
# parity invariant. The regexes ARE — they define what "routable" and
# "valid charset" mean, and a divergence between two workflows' ROUTABLE is a
# silent disagreement about which ids dispatch.
WORKFLOW_PARITY_CONSTS = ("ROUTABLE", "BAD_CHARSET")


def check_workflow_parity(root, problems):
    """Every workflow's shared regex constants (ROUTABLE, BAD_CHARSET) must be
    byte-identical across all workflows/*.js.

    The tier-resolution block is duplicated because the sandbox forbids imports
    (measured 2026-07-30). Prose ("keep them in sync") does not hold that
    coupling — check_lock_parity was written for the identical lesson in bash.
    This is its JS analogue: a divergence between two workflows' ROUTABLE is a
    silent disagreement about which model ids are routable, with no crash.
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
        for m in re.finditer(
                rf'agentType:\s*"{re.escape(PLUGIN_NAME)}:([\w-]+)"', text):
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
    check_agents,
    check_render_templates,
    check_hook,
    check_scripts,
    check_reader_bounds,
    check_platform_idioms,
    check_guard_parity,
    check_lock_parity,
    check_workflows,
    check_workflow_parity,
    check_workflow_tier_namespace,
    check_workflow_agent_types,
    check_commands,
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
