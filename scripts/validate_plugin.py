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
     scripts/ops-stop-hook.sh via ${CLAUDE_PLUGIN_ROOT}.
  8. The four gate scripts exist and are syntactically valid bash (`bash -n`).

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

    headings = [ln[3:].split(" (")[0].strip()
                for ln in lines if ln.startswith("## ")]
    if headings != CHARTER_SECTION_ORDER:
        problems.append(
            f"templates/OPERATOR.md: section order {headings} != "
            f"expected {CHARTER_SECTION_ORDER}")

    text = "\n".join(lines)
    if ".operator/bin/ops-verdict.sh" not in text:
        problems.append(
            "templates/OPERATOR.md: does not reference "
            "'.operator/bin/ops-verdict.sh' — the charter must name the "
            "project-installed CLI path (a scripts/ path does not resolve in "
            "a target project)")

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


def check_hook(root, problems):
    hp = root / "hooks" / "hooks.json"
    hook = load_json(hp, problems)
    if hook is None:
        return
    try:
        stop = hook["hooks"]["Stop"]
        cmd = stop[0]["hooks"][0]["command"]
    except (KeyError, IndexError, TypeError):
        problems.append("hooks/hooks.json: no Stop hook command found")
        return
    if "ops-stop-hook.sh" not in cmd:
        problems.append(
            f"hooks/hooks.json: Stop command does not point at "
            f"ops-stop-hook.sh (got {cmd!r})")
    if "${CLAUDE_PLUGIN_ROOT}" not in cmd:
        problems.append(
            "hooks/hooks.json: Stop command should use ${CLAUDE_PLUGIN_ROOT}")


def check_scripts(root, problems):
    for name in ("ops-init.sh", "ops-verdict.sh", "ops-task.sh", "ops-stop-hook.sh"):
        p = root / "scripts" / name
        if not p.is_file():
            problems.append(f"scripts/{name}: missing")
            continue
        r = subprocess.run(["bash", "-n", str(p)], capture_output=True, text=True)
        if r.returncode != 0:
            problems.append(f"scripts/{name}: bash syntax error — {r.stderr.strip()}")


def main(argv=None):
    root = pathlib.Path(argv[0]) if argv else pathlib.Path(
        __file__).resolve().parent.parent
    problems = []
    check_manifests(root, problems)
    check_changelog(root, problems)
    check_charter(root, problems)
    check_ledger_schema(root, problems)
    check_agents(root, problems)
    check_hook(root, problems)
    check_scripts(root, problems)

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
