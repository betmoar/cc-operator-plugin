"""Each validate_plugin check must FIRE on a broken fixture and PASS on a good
tree. We build a minimal valid repo in a tmpdir, assert it is clean, then break
one contract at a time and assert the specific failure surfaces.
"""
import json
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile
import textwrap
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
import validate_plugin as vp  # noqa: E402


# One CLI per line: the charter now bounds per-line length (F19), so the
# fixture must satisfy CHARTER_MAX_LINE_CHARS like the real charter does.
_CLI_SENTENCE = " — run [DOC:spec-D4]:\n" + "\n".join(
    f"`.operator/bin/{c}`" for c in vp.CHARTER_REQUIRED_CLIS)

# The dispatch packet, which check_handout_packet requires the charter to carry
# (#57). Split across lines like the real charter's, so the fixture also honours
# CHARTER_MAX_LINE_CHARS. Written out rather than joined from
# vp.HANDOUT_PACKET_SPINE: a good-tree fixture derived from the constant under
# test is clean by construction and would stay clean if the constant were
# retyped to nonsense.
_PACKET_SENTENCE = (
    "\n\n```\nTASK / TEXT / SCENE / INPUTS / FORBIDDEN / DONE / REACH (entry\n"
    "point + the proof) / REPORT (status, SHA, CHANGED: <paths>|none)\n```"
)

GOOD_CHARTER = "# OPERATOR.md\n\n" + "\n".join(
    f"## {sec}\n\nrule [D:tag-{i}] body"
    + (_CLI_SENTENCE if sec == "EVIDENCE GATE" else ".")
    + (_PACKET_SENTENCE if sec == "ORCHESTRATED MODE" else "")
    + "\n"
    for i, sec in enumerate(vp.CHARTER_SECTION_ORDER)
)


# Stub scripts that actually SATISFY the guardrail checks. The good tree must
# be clean under every check in vp.CHECKS, not merely under the manifest-shaped
# ones — a fixture that only passes the checks someone remembered to call is
# how three guardrails went unexercised here.
# 0.10: the shared partition lib — the hook and the bar source ONE
# implementation (scan_pending + scan_deviations + sentinel_owner_of_name).
# The gate CLIs (Zone B: they install standalone into .operator/bin/) keep
# their own copies, still pinned by check_guard_parity.
GOOD_PARTITION_LIB = (
    "#!/usr/bin/env bash\n"
    "sentinel_owner_of_name() {\n"
    "  case \"$_o\" in \"\" | */* | .* | *\"|\"* | *[[:space:]]*) printf '\\n'; return 0 ;; esac\n"
    "}\n"
    "# deviation gate: counts DEVIATION|ESCALATION|GATE-EXCEPTION (HANDOFF-MARK)\n"
    "while IFS= read -r -n 512 dline; do :; done < \"$decisions\"\n"
    "[ ! -L \"$decisions\" ] || exit 0\n")
GOOD_STATUSLINE = (
    "#!/usr/bin/env bash\n"
    '. lib/partition.sh\n'
    "[ ! -L \"$decisions\" ] || exit 0\n"
    "while IFS= read -r -n 512 dline; do :; done < \"$decisions\"\n"
    "while IFS= read -r -n 512 dline; do :; done < \"$decisions\"\n"
    "while IFS= read -r -n 512 dline; do :; done < \"$decisions\"\n")

# A json_get() whose python3 branch carries the bool coercion. The three hooks
# must agree on it (F14 parity pin); fixtures embed this single source so the
# four hook-stub sites cannot drift apart.
# JSON null maps to "" here, exactly as the three real hooks do — the fixture
# is only useful while it MEANS the same thing as the code it stands in for.
# The F14 pin looks for `isinstance(v, bool)` alone, so a null-blind stub passes
# today; the risk is the next pin, written against a fixture that quietly
# diverged. (Copilot review of PR #56.)
JSON_GET = (
    "# json_get python3 branch carries the bool coercion (F14 parity pin)\n"
    "json_get() { printf '%s' \"$input\" | python3 -c 'import sys,json; "
    "v=json.load(sys.stdin).get(sys.argv[1],\"\"); "
    "print(\"true\" if isinstance(v, bool) and v else \"false\" if isinstance(v, bool) "
    "else \"\" if v is None else v)' \"$1\"; }\n")

GOOD_LOCK_BLOCK = (
    "# >>> LOCK BLOCK\n"
    "lock_acquire() { mkdir \"$LOCKDIR\" 2>/dev/null; }\n"
    "lock_release() { rm -f \"$LOCKDIR/holder\"; rmdir \"$LOCKDIR\"; }\n"
    "# <<< LOCK BLOCK\n")

# The U10 source-state stamp (check_source_stamp). A compliant stub carries the
# resolver, every marker it can emit, the `.operator` dirty-exclusion, the 4-cell
# row format, the APPLIED SOURCE_STAMP, and the verdict-path marker with the
# stamp resolved before lock_acquire. Appended AFTER the lock block on purpose:
# the ordering assertion reads the first lock_acquire that follows the marker,
# and the block's own definition sits above it.
GOOD_SOURCE_STAMP = (
    "source_stamp() {\n"
    "  command -v git >/dev/null 2>&1 || { printf 'no-vcs'; return 0; }\n"
    "  sha=\"$(git rev-parse --verify --short=12 HEAD 2>/dev/null || true)\"\n"
    "  [ -n \"$sha\" ] || { printf 'no-commit'; return 0; }\n"
    "  porc=\"$(git status --porcelain -- ':(exclude).operator' 2>/dev/null)\""
    " && rc=0 || rc=$?\n"
    "  [ \"$rc\" -eq 0 ] || { printf '%s+unknown' \"$sha\"; return 0; }\n"
    "  [ -z \"$porc\" ] || { printf '%s+dirty' \"$sha\"; return 0; }\n"
    "  printf '%s' \"$sha\"\n"
    "}\n"
    "# --- Verdict path ---\n"
    "SOURCE_STAMP=\"$(source_stamp)\"\n"
    "lock_acquire\n"
    "ROW=\"$(printf '| %s | %s | %s @%s | %s |'"
    " \"$ID\" \"$C\" \"$E\" \"$SOURCE_STAMP\" \"$V\")\"\n")


def write(p, text):
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(text, encoding="utf-8")


def make_good_tree(root):
    # `repository` is load-bearing, not decorative: check_issue_refs compares
    # every issue link against it, and without it the check can only report that
    # it has no baseline — which would make every other issue-ref assertion pass
    # for the wrong reason.
    write(root / ".claude-plugin" / "plugin.json", json.dumps({
        "name": "cc-operator", "version": "0.1.0",
        "description": "d", "license": "MIT",
        "repository": "https://github.com/betmoar/cc-operator-plugin",
    }))
    write(root / ".claude-plugin" / "marketplace.json", json.dumps({
        "name": "cc-operator-plugin", "owner": {"name": "b"},
        "plugins": [{"name": "cc-operator", "source": "./", "description": "d"}],
    }))
    write(root / "CHANGELOG.md", "# Changelog\n\n## [Unreleased]\n\n## [0.1.0] - 2026-07-06\n\n- init\n")
    write(root / "templates" / "OPERATOR.md", GOOD_CHARTER)
    # Every [DOC:spec-<key>] in the charter must have a `### spec-<key>` entry
    # in the tracked tag index (#76 step E) — the fixture charter cites spec-D4.
    write(root / "docs" / "spec" / "TAGS.md",
          "# Tags\n\n### spec-D4\n\nThe evidence gate.\n")
    write(root / "templates" / "VERDICTS-header.md",
          "# Verdicts\n" + vp.VERDICTS_HEADER + "\n|---|---|---|---|\n")
    write(root / "templates" / "DECISIONS-header.md",
          "# Decisions — append-only, one line per entry\n"
          "# <ISO-date> | <engagement.task> | <kind> | <what> | <why>\n"
          "# gated: DEVIATION | ESCALATION | GATE-EXCEPTION\n"
          "# record: DECISION | DEFERRED-VERDICT\n"
          "# marker: HANDOFF-MARK\n")
    for name, model in (("op-author", "opus"),
                        ("op-mechanic", "sonnet"),
                        ("op-reviewer", "opus")):
        tools = ("Read, Grep, Glob, Bash" if name == "op-reviewer"
                 else "Read, Write, Edit, Grep, Glob, Bash")
        write(root / "agents" / f"{name}.md", textwrap.dedent(f"""\
            ---
            name: {name}
            description: d
            model: {model}
            tools: {tools}
            ---
            Body. End with NEEDS_CONTEXT when underspecified.
            """))
    write(root / "hooks" / "hooks.json", json.dumps({
        "hooks": {
            "Stop": [{"hooks": [{
                "type": "command",
                "command": 'bash "${CLAUDE_PLUGIN_ROOT}/scripts/ops-stop-hook.sh"',
            }]}],
            "SessionStart": [{"matcher": "startup", "hooks": [{
                "type": "command",
                "command": 'bash "${CLAUDE_PLUGIN_ROOT}/scripts/ops-sessionstart-hook.sh"',
            }]}],
            "PostToolUse": [{"matcher": "Bash", "hooks": [{
                "type": "command",
                "command": 'node "${CLAUDE_PLUGIN_ROOT}/scripts/ops-compress.mjs"',
            }]}],
            # The G2 arm gate. `Bash` must NEVER appear in this matcher —
            # check_armgate pins the set exactly (gating Bash deadlocks the
            # repair path, since ops-task.sh is itself a Bash call).
        }
    }))
    write(root / ".claude-plugin" / "statusline.json", json.dumps({
        "name": "cc-operator", "render": "scripts/statusline.sh", "order": 30,
    }))
    # Both writers of .operator/.gitignore must carry the v2 allowlist body,
    # byte-equal (check_gitignore_parity — same F30 shape as the install set).
    gitignore_v2 = ("# cc-operator gitignore v2 (allowlist)\n"
                    "*\n"
                    "!.gitignore\n!.gitattributes\n"
                    "!VERDICTS.md\n!DECISIONS.md\n!tiers.env\n"
                    "!verdicts.d/\n!verdicts.d/*.md\n"
                    # Evidence and policy, not machine state (#30/#31): the
                    # handoff is what the charter's HANDOFF section produces,
                    # and armgate.on is the project's committable opt-in.
                    "!handoff-*.md\n!armgate.on\n")
    # Both writers must DETECT a v1 file as well as emit the v2 body, and must
    # refuse to overwrite it without a backup they verified. Emitting alone used
    # to satisfy the check; a stub that only emits would now (correctly) fail.
    # The install set lives in ONE manifest (#76 step 3): both writer stubs
    # source it and iterate $_OPS_TOOLS, exactly what check_install_set_parity
    # now pins (source line + loop var + no inline literal).
    write(root / "scripts" / "ops-install-set.sh",
          '_OPS_TOOLS="ops-verdict.sh ops-task.sh ops-adopt.sh '
          'ops-claims.sh ops-backlog.sh"\n')
    _install_loop = ('. "$SCRIPT_DIR/ops-install-set.sh"\n'
                     "for _tool in $_OPS_TOOLS; do :; done\n")
    write(root / "scripts" / "ops-init.sh",
          "#!/usr/bin/env bash\nset -eu\n" + _install_loop +
          "_GI_MARK='# cc-operator gitignore v2 (allowlist)'\n"
          "if ! grep -qF \"$_GI_MARK\" \"$OPDIR/.gitignore\" 2>/dev/null; then\n"
          "  if [ -e \"$OPDIR/.gitignore.v1.bak\" ] && [ ! -f \"$OPDIR/.gitignore.v1.bak\" ]; then\n"
          "    echo refusing >&2\n"
          "  elif ! cp \"$OPDIR/.gitignore\" \"$OPDIR/.gitignore.v1.bak\" 2>/dev/null; then\n"
          "    echo refusing >&2\n"
          "  else\n"
          "cat > \"$OPDIR/.gitignore\" <<'EOF'\n" + gitignore_v2 + "EOF\n"
          "  fi\nfi\n"
          "echo ok\n")
    # SessionStart clears the compressor's session-scoped artifacts; the guard
    # checks for both directory names, so the stub must carry them. It also
    # migrates a v1 gitignore, so it carries the same allowlist body — behind
    # the same verified backup.
    write(root / "scripts" / "ops-sessionstart-hook.sh",
          "#!/usr/bin/env bash\nset -eu\n" + _install_loop + JSON_GET +
          "rm -rf \"$cwd/.operator/.compress-spill\" \"$cwd/.operator/.compress-state\"\n"
          "if ! grep -qF '# cc-operator gitignore v2 (allowlist)' \"$_gi\" 2>/dev/null; then\n"
          "  if [ -e \"$_gi.v1.bak\" ] && [ ! -f \"$_gi.v1.bak\" ]; then\n"
          "    _gi_backup_failed=1\n"
          "  elif ! cp \"$_gi\" \"$_gi.v1.bak\" 2>/dev/null; then\n"
          "    _gi_backup_failed=1\n"
          "  else\n"
          "cat > \"$_gi\" <<'EOF'\n" + gitignore_v2 + "EOF\n"
          "  fi\nfi\n"
          "echo ok\n")
    # The readers/CLIs need bodies that satisfy the byte-bound, guard-parity and
    # lock-parity checks — a bare `echo ok` stub fails all three.
    guards = ("check_bare_name() { case \"$2\" in .*) die x ;; *__*) die x ;; esac; }\n"
              "check_owner_name() { :; }\n")
    bounded = "while IFS= read -r -n 512 line; do :; done < \"$1\"\n"
    # every sentinel touchpoint carries the -L symlink rejection (F65/F66)
    nolink = "[ ! -L \"$1\" ] || exit 0\n"
    write(root / "scripts" / "ops-stop-hook.sh",
          "#!/usr/bin/env bash\n. lib/partition.sh\n" + JSON_GET)
    write(root / "scripts" / "ops-task.sh",
          "#!/usr/bin/env bash\n" + guards + nolink)
    write(root / "scripts" / "ops-verdict.sh",
          "#!/usr/bin/env bash\n" + guards + nolink +
          "sentinel_owner_of_name() {\n"
          "  case \"$_o\" in \"\" | */* | .* | *\"|\"* | *[[:space:]]*) printf '\\n'; return 0 ;; esac\n"
          "}\n" +
          "# F2: refuse a symlink fragment before the write + skip on both reads\n"
          '[ -L "$FRAGDIR/$who.md" ] && exit 1\n'
          '[ -f "$frag" ] && [ ! -L "$frag" ] && :;\n'
          '[ -f "$frag" ] && [ ! -L "$frag" ] && :;\n'
          "# F17: both verdicts.d fragment scanners use the same 1MiB read bound\n"
          "while IFS= read -r -n 1048576 row; do :; done < \"$frag\"\n"
          "while IFS= read -r -n 1048576 line; do :; done < \"$frag\"\n" +
          "# --mark-handoff writes a HANDOFF-MARK line under the lock\n" +
          GOOD_LOCK_BLOCK + GOOD_SOURCE_STAMP)
    write(root / "scripts" / "ops-adopt.sh",
          "#!/usr/bin/env bash\n" + guards + nolink +
          "# PREV reject-set (F15): carries *.exempt like the sentinel_owner parsers\n"
          'case "${PREV:-}" in */* | .* | *"|"* | *[[:space:]]* | *[[:cntrl:]]* | *.exempt) PREV="<invalid>" ;; esac\n'
          + GOOD_LOCK_BLOCK)
    # ops-claims.sh: a fourth gate CLI. check_claims pins its PROTECTED literal
    # and requires matches_protected applied to $p — the stub carries both so
    # the good tree is clean (and the check_claims mutation tests stub it out
    # of compliance deliberately).
    write(root / "scripts" / "ops-claims.sh",
          "#!/usr/bin/env bash\n"
          'PROTECTED="scripts/validate_plugin.py tests/ .operator/bin/ hooks/ '
          'scripts/ops-*.sh scripts/statusline.sh backlog/"\n'
          "matches_protected() { :; }\n"
          'for p in $ACTUAL; do matches_protected "$p"; done\n')
    # ops-backlog.sh: the planning/reporting CLI (B10.1). In check_scripts (so it
    # gets bash -n) but NOT a gate CLI — not in CHARTER_REQUIRED_CLIS/GATE_CLIS.
    write(root / "scripts" / "ops-backlog.sh",
          "#!/usr/bin/env bash\n"
          'if [ "${1:-}" = "--census" ]; then echo "files: 0"; exit 0; fi\n')
    (root / "scripts" / "lib").mkdir(exist_ok=True)
    write(root / "scripts" / "lib" / "partition.sh", GOOD_PARTITION_LIB)
    write(root / "scripts" / "statusline.sh", GOOD_STATUSLINE)
    # Every shipped slash command: frontmatter the harness registers it by,
    # and plugin-root script paths (a bare scripts/ path resolves only inside
    # this repo — the v0.2.0 blocked-start bug check_commands exists for).
    for name in ("start", "handoff"):
        write(root / "commands" / f"{name}.md", textwrap.dedent(f"""\
            ---
            description: d
            argument-hint: []
            allowed-tools: Bash(bash:*), Read, Write, Edit
            ---
            Run `bash "${{CLAUDE_PLUGIN_ROOT}}/scripts/ops-init.sh"`.
            """))
    # Two workflow fixtures carrying the shared tier-validation invariants
    # identically (BAD_CHARSET byte-equal, DEFAULT_TIERS values harness
    # aliases) so check_workflows, check_workflow_parity, and
    # check_workflow_default_tiers pass on the good tree. The sandbox forbids
    # imports, so the block is copy-pasted; parity + the alias pin are the
    # only things holding it together. (KNOWN_TIERS and its namespace check
    # were deleted with #76 step 2 — the workflows no longer carry a tier-name
    # catalogue.)
    # Both stubs carry check_routable and TIER_NAMES: the resolver and the
    # renderer parse the same tiers.env, so check_resolver_renderer_parity
    # requires both to declare each (a plugin shipping one guarded and one
    # unguarded is exactly what that check exists to reject).
    # The stub tracks the guard's STRUCTURE, not just its name: since #35 the
    # `<provider>:<model>` lens is gated on LENS_NAMESPACES, which the parity
    # check pins both inside the body (the lookup) and outside it (the value).
    ROUTABLE_STUB = (
        'check_routable() {\n'
        '  case "$2" in\n'
        '    "") die "$1 is empty" ;;\n'
        '    *[!A-Za-z0-9._:/@[\\]-]*) die "$1 outside charset" ;;\n'
        '  esac\n'
        '  case "$2" in\n'
        '    *:*)\n'
        '      _lens_head="${2%%:*}"\n'
        '      case "$_lens_head" in */*) ;;\n'
        '        *) case " $LENS_NAMESPACES " in\n'
        '             *" $_lens_head "*) return 0 ;;\n'
        '             *) die "unknown lens" ;; esac ;;\n'
        '      esac ;;\n'
        '  esac\n'
        '  case "$2" in glm-*|claude-*) return 0 ;; */*) return 0 ;; esac\n'
        '  die "$1 is not cc-proxy-routable"\n'
        '}\n'
        'LENS_NAMESPACES="glm openrouter deepseek qwen claude"\n'
        'TIER_NAMES="JUDGMENT IMPLEMENT MECHANICAL RECON"\n'
    )
    write(root / "scripts" / "ops-tiers.sh",
          ROUTABLE_STUB +
          '# minimal stub; one byte-bounded read satisfies check_reader_bounds\n'
          'while IFS= read -r -n 512 line; do :; done < "$1"\n')
    # ops-render.sh ships alongside the resolver; a stub with one bounded read
    # satisfies check_scripts (bash -n) and check_reader_bounds.
    write(root / "scripts" / "ops-render.sh",
          ROUTABLE_STUB +
          '# stub renderer\n'
          'while IFS= read -r -n 256 line; do :; done\n')
    # The compressor is hook-wired, so the good tree must carry it or
    # check_compressor fires. The guard checks CALL SITES (F48: a name in a
    # comment or bare declaration is not enforcement), so the stub carries both
    # the declarations AND the .has()/.some() applications a real compress()
    # would apply — anything less and the guard's call-site checks fire on the
    # fixture itself.
    write(root / "scripts" / "ops-compress.mjs",
          'export const DEFAULTS = {\n'
          '  SCRUB_MIN: 1024, MAX_CHARS: 8000, HEAD_BYTES: 6144, TAIL_BYTES: 4096,\n'
          '  LINE_CHARS: 400, SALVAGE_LINES: 12, MIN_SHRINK: 64,\n'
          '};\n'
          'const ELIDABLE = new Set(["Bash", "WebFetch", "WebSearch", "Grep", "Glob"]);\n'
          'const NEVER_COMPRESS = new Set(["Read", "Edit", "Write", "NotebookEdit"]);\n'
          'const LOSSLESS_ONLY = new Set(["Agent"]);\n'
          'const LEDGER_PATHS = [".operator/VERDICTS.md", ".operator/DECISIONS.md",\n'
          '  ".operator/verdicts.d/"];\n'
          'const GATE_CLIS = ["ops-verdict.sh", "ops-task.sh", "ops-adopt.sh", "ops-claims.sh"];\n'
          'const SALVAGE_RE = /error|fail|not ok/i;\n'
          'function compress(tool, cmd) {\n'
          '  if (NEVER_COMPRESS.has(tool)) return null;\n'
          '  if (tool.startsWith("mcp__")) return null;\n'
          '  const losslessOnly = LOSSLESS_ONLY.has(tool);\n'
          '  if (LEDGER_PATHS.some((p) => cmd.includes(p))) return null;\n'
          '  if (GATE_CLIS.some((c) => cmd.includes(c))) return null;\n'
          '  return losslessOnly;\n'
          '}\n')

    # The renderer splices a model: id into each template; default.tmpl must
    # carry a model: line or check_render_templates fires.
    write(root / "agents" / "_templates" / "default.tmpl",
          '---\nname: op-NAME\nmodel: MODEL\ntools: Read\n---\nbody\n')
    # No ROUTABLE since 0.8.3: an id-shape catalogue is a validator FINDING
    # now, not a requirement (check_workflows (c)). BAD_CHARSET is the guard.
    WF_SHARED = (
        'const BAD_CHARSET = /[^\\w./:@[\\]-]/;\n'
        'const DEFAULT_TIERS = { JUDGMENT: "opus" };\n'
        'for (const [n, id] of Object.entries(DEFAULT_TIERS)) {\n'
        '  if (BAD_CHARSET.test(id)) throw new Error("bad");\n'
        '}\n'
    )
    for wname in ("review", "brainstorm"):
        write(root / "workflows" / f"{wname}.js",
              f'export const meta = {{ name: "{wname}", description: "d" }};\n' + WF_SHARED)
    # plan.js is written separately because check_northstar REPORTS a missing
    # plan.js rather than skipping — a check that goes inert when its target is
    # absent is the vacuous-guard shape, and a "clean tree" of this plugin has a
    # plan.js. So the fixture has to carry the #58 north-star shape: read without
    # a fallback, refused when absent, refused without a `Missed if:` clause, and
    # interpolated into EXACTLY ONE prompt (decompose, never a vet packet).
    write(root / "workflows" / "plan.js",
          'export const meta = { name: "plan", description: "d" };\n' + WF_SHARED +
          'const TASK = { properties: {\n'
          '    produces: {\n      type: "array",\n      items: { type: "string" },\n    },\n'
          '    consumes: {\n      type: "array",\n      items: { type: "string" },\n    },\n'
          '} };\n'
          'const g = { contractsInferred: [] };\n'
          'const spec = A.spec;\n'
          'if (typeof spec !== "string") { throw new Error("args.spec is required"); }\n'
          'const MISS_CLAUSE = /\\bmissed\\s+if\\s*:\\s*(\\S.*)/is;\n'
          'const northStar = A.northStar;\n'
          'if (typeof northStar !== "string") {\n'
          '  throw new Error("args.northStar is required: … then a `Missed if: …` clause");\n'
          '}\n'
          'if (!MISS_CLAUSE.exec(northStar)) { throw new Error("no miss clause"); }\n'
          'const p = `NORTH STAR:\\n${northStar}\\n\\nSPEC:\\n${spec}`;\n')


class ValidatorTest(unittest.TestCase):
    def setUp(self):
        self.dir = pathlib.Path(tempfile.mkdtemp())
        make_good_tree(self.dir)

    def tearDown(self):
        shutil.rmtree(self.dir, ignore_errors=True)

    def problems(self):
        # Iterate vp.CHECKS rather than re-listing the checks here. The old
        # hand-copied list had silently fallen three behind the build
        # (check_reader_bounds, check_guard_parity, check_lock_parity), so
        # test_good_tree_is_clean — the assertion a reader trusts most — was
        # not exercising them at all.
        probs = []
        for check in vp.CHECKS:
            check(self.dir, probs)
        return probs

    def assertFires(self, needle):
        probs = self.problems()
        self.assertTrue(any(needle in p for p in probs),
                        f"expected a problem containing {needle!r}; got {probs}")

    # --- baseline ---
    def test_good_tree_is_clean(self):
        self.assertEqual(self.problems(), [])

    # --- F14: json_get bool-coercion parity pin (must fire on a broken hook) ---
    def test_f14_json_get_bool_coercion_missing_fires(self):
        # Strip the coercion from one hook's json_get. The pin greps for the
        # literal isinstance(v, bool); renaming it must make check_guard_parity
        # report the drift (the file's docstring mandates fire-on-broken).
        p = self.dir / "scripts" / "ops-sessionstart-hook.sh"
        p.write_text(p.read_text(encoding="utf-8").replace(
            "isinstance(v, bool)", "isinstance(v, wasbool)"), encoding="utf-8")
        self.assertFires("json_get() is missing the isinstance(v, bool)")

    # --- the U10 source-state stamp (check_source_stamp) ---
    # Each mutation is one way the stamp stops binding a row to a tree. The
    # last two are the ones that matter most, because neither changes any
    # observable output: a stamp that never reaches the row, and a check that
    # cannot see the difference, both look exactly like a working build.
    def _verdict(self):
        return self.dir / "scripts" / "ops-verdict.sh"

    def _mutate_verdict(self, old, new):
        p = self._verdict()
        text = p.read_text(encoding="utf-8")
        self.assertIn(old, text)
        write(p, text.replace(old, new))

    def test_source_stamp_resolver_removed(self):
        self._mutate_verdict("source_stamp() {", "_removed_stamp() {")
        self.assertFires("no source_stamp()")

    def test_source_stamp_marker_dropped(self):
        # A failure path that degrades to silence instead of an explicit state.
        self._mutate_verdict("printf '%s+unknown' \"$sha\"", "printf '%s' \"$sha\"")
        self.assertFires("'+unknown' marker")

    def test_source_stamp_dirty_exclusion_dropped(self):
        # Counting .operator/ pins every row to +dirty — a marker that can never
        # be off, which is the vacuous-guard class (#21) wearing a feature's
        # clothes. Nothing errors; the signal just stops meaning anything.
        self._mutate_verdict(" -- ':(exclude).operator'", "")
        self.assertFires("must exclude")

    def test_source_stamp_fifth_cell(self):
        self._mutate_verdict("| %s | %s | %s @%s | %s |",
                             "| %s | %s | %s | @%s | %s |")
        self.assertFires("four cells")

    def test_source_stamp_resolved_but_never_applied(self):
        # F30: declared and not applied. The resolver still exists, still
        # returns the right token, and the row still carries none of it.
        self._mutate_verdict("SOURCE_STAMP", "UNUSED_STAMP")
        self.assertFires("never applied to the row")

    def test_source_stamp_dropped_from_the_row_argument_only(self):
        # The narrower mutation the substring test could not see: the assignment
        # `SOURCE_STAMP="$(source_stamp)"` stays, so `"SOURCE_STAMP" in code` is
        # still true, but the ROW's own argument becomes a literal and every row
        # ships unstamped (Copilot review of PR #12). "Applied" has to mean the
        # printf carries it, not that the identifier occurs somewhere.
        self._mutate_verdict('"$E" "$SOURCE_STAMP" "$V"', '"$E" "BOGUS" "$V"')
        self.assertFires('does not pass "$SOURCE_STAMP"')

    def test_source_stamp_row_site_missing_is_reported(self):
        # Not-found must be a reported problem, never a silent skip — the
        # PLAYBOOK's rule for every guard that locates its target by regex.
        self._mutate_verdict('ROW="$(printf ', 'ROW2="$(printf ')
        self.assertFires("check_source_stamp cannot verify")

    def test_source_stamp_resolved_inside_the_lock(self):
        # The PLAYBOOK's step-3 hazard: git work inside the critical section.
        # This is the mutation the first draft of the check PASSED — it split on
        # a comment marker it had already stripped, found nothing, and skipped
        # the assertion. Pinned so the fail-open cannot come back.
        self._mutate_verdict(
            "SOURCE_STAMP=\"$(source_stamp)\"\nlock_acquire",
            "lock_acquire\nSOURCE_STAMP=\"$(source_stamp)\"")
        self.assertFires("BEFORE lock_acquire")

    def test_source_stamp_verdict_path_marker_lost(self):
        # Not-found must be a reported problem, never a silent skip: a guard
        # whose landmark disappeared cannot tell "compliant" from "unreadable".
        self._mutate_verdict("# --- Verdict path ---", "# --- verdict stuff ---")
        self.assertFires("Verdict path")

    # --- the handout packet pin (check_handout_packet, F69 + #57) ---
    #
    # The full packet spine, written once. Both halves of the pin are checked
    # against it: the charter must carry every field, and the handout must teach
    # every field. Spelled out rather than built from vp.HANDOUT_PACKET_SPINE,
    # because a test that derives its expectation from the code under test
    # asserts self-consistency, not correctness — retype the spine to garbage and
    # a derived test follows it green.
    # FENCED, because check_handout_packet extracts the ``` block rather than
    # searching the whole document: prose around the packet already contains
    # 'REACH', so a whole-document search stayed green when the field was
    # deleted from the packet itself (Copilot, PR #72).
    _PACKET = ("```\n"
               "TASK / TEXT / SCENE / INPUTS / FORBIDDEN / DONE / REACH (entry "
               "point + proof) / REPORT (status, SHA, CHANGED: <paths>|none)\n"
               "```\n")

    # The spine's fields, hardcoded — and the reason is that writing the warning
    # above was NOT enough to avoid the trap it describes. The per-field cases
    # below first shipped as `for field in vp.HANDOUT_PACKET_SPINE`, which reads
    # the tuple out of the module under test: drop "REACH" from the spine and the
    # loop drops the same field from its own expectation, so the cases stayed
    # green while the guard lost the field they exist to protect. Measured
    # exactly that way — 3 passed with REACH deleted from the spine.
    #
    # That is the vacuous-guard class (#21) reached from its least obvious side:
    # not a check that cannot fail, but a check whose expectation is defined by
    # the thing it checks. `_EXPECTED_SPINE` is the independent copy, and
    # test_spine_matches_expected below is what makes adding a field to the
    # product require adding it here — the coupling stated out loud instead of
    # silently satisfied.
    _EXPECTED_SPINE = ("TASK / TEXT / SCENE", "REACH", "CHANGED: <paths>|none")

    def test_spine_matches_expected(self):
        # The one place the two copies are compared. A field added to the product
        # spine without being added here fails HERE, loudly, instead of silently
        # widening every per-field loop below.
        self.assertEqual(
            tuple(vp.HANDOUT_PACKET_SPINE), self._EXPECTED_SPINE,
            "HANDOUT_PACKET_SPINE changed — update _EXPECTED_SPINE too, and check "
            "that templates/OPERATOR.md and docs/HANDOUT.md carry the new field")

    def test_handout_packet_pin(self):
        # No handout: the handout half must skip — prose is optional, and the
        # good tree has no HANDOUT.md. The CHARTER half is unconditional, so the
        # stub charter gets the packet first.
        c = self.dir / "templates" / "OPERATOR.md"
        write(c, c.read_text() + "\n" + self._PACKET)
        probs = []
        vp.check_handout_packet(self.dir, probs)
        self.assertEqual(probs, [])
        # A handout carrying the packet is clean.
        h = self.dir / "docs" / "HANDOUT.md"
        write(h, "packet:\n" + self._PACKET)
        probs = []
        vp.check_handout_packet(self.dir, probs)
        self.assertEqual(probs, [])
        # F69, measured: the handout dropped CHANGED — ops-claims.sh's input.
        # Kept FENCED, so this exercises the missing-FIELD path rather than the
        # missing-BLOCK one; both are real and they are different findings.
        write(h, "packet:\n```\nTASK / TEXT / SCENE / INPUTS / DONE / REACH / REPORT\n```\n")
        self.assertFires("the dispatch packet is missing")
        # And the missing-block path: an unfenced packet is REPORTED, not skipped.
        # A checker that silently found nothing would read as "handout is clean".
        write(h, "packet:\nTASK / TEXT / SCENE / INPUTS / DONE / REACH / CHANGED: <paths>|none\n")
        self.assertFires("no fenced dispatch-packet block found")

    def test_handout_packet_pin_fires_per_field(self):
        # Every field in the spine must be independently load-bearing. The
        # original pin held only the FIRST and LAST fragments, so a field added
        # or dropped in the MIDDLE was invisible — which is where REACH went in
        # 0.8.4, and the pin stayed green teaching a packet without it. One
        # assertion per field, so no future field can be added to the tuple
        # without being genuinely enforced.
        c = self.dir / "templates" / "OPERATOR.md"
        write(c, c.read_text() + "\n" + self._PACKET)
        h = self.dir / "docs" / "HANDOUT.md"
        for field in self._EXPECTED_SPINE:
            write(h, "packet:\n" + self._PACKET.replace(field, "«removed»"))
            probs = []
            vp.check_handout_packet(self.dir, probs)
            self.assertTrue(
                any(repr(field) in p for p in probs),
                f"dropping {field!r} from the handout packet did not fire: {probs}")

    def test_handout_packet_pin_checks_the_charter_itself(self):
        # The half that did not exist before #57: parity between the handout and
        # the charter passes perfectly when the CHARTER is what lost the field
        # (F30 — uniform drift is invisible to a parity check). With no packet in
        # the charter at all, every field must fire, handout or no handout.
        c = self.dir / "templates" / "OPERATOR.md"
        stripped = c.read_text().replace(_PACKET_SENTENCE, "")
        self.assertNotIn("REACH", stripped, "the strip did not take — this case would be vacuous")
        write(c, stripped)
        probs = []
        vp.check_handout_packet(self.dir, probs)
        # Stripping the whole stanza removes the FENCE as well, so the finding is
        # the missing block rather than N missing fields. Both name OPERATOR.md
        # and both are failures — what must never happen is silence.
        self.assertTrue(
            any("OPERATOR.md" in p for p in probs),
            f"a charter with no dispatch packet produced no finding at all: {probs}")
        self.assertTrue(
            any("no fenced dispatch-packet block found" in p for p in probs),
            f"expected the missing-block finding, got: {probs}")
        # The per-FIELD half, on a charter that still HAS a packet but lost one
        # field — the shape #57 actually shipped.
        for field in self._EXPECTED_SPINE:
            write(c, stripped + "\n" + self._PACKET.replace(field, "«removed»"))
            probs = []
            vp.check_handout_packet(self.dir, probs)
            self.assertTrue(
                any("OPERATOR.md" in p and repr(field) in p for p in probs),
                f"a charter packet missing {field!r} did not fire: {probs}")

    # --- 1. manifests ---
    def test_wrong_plugin_name(self):
        p = self.dir / ".claude-plugin" / "plugin.json"
        d = json.loads(p.read_text()); d["name"] = "operator"; write(p, json.dumps(d))
        self.assertFires("name is")

    def test_non_semver_version(self):
        p = self.dir / ".claude-plugin" / "plugin.json"
        d = json.loads(p.read_text()); d["version"] = "1.0"; write(p, json.dumps(d))
        self.assertFires("not semver")

    def test_wrong_marketplace_source(self):
        p = self.dir / ".claude-plugin" / "marketplace.json"
        d = json.loads(p.read_text()); d["plugins"][0]["source"] = "./operator"
        write(p, json.dumps(d))
        self.assertFires("source is")

    # --- 3. changelog sync ---
    def test_changelog_not_newest(self):
        write(self.dir / "CHANGELOG.md",
              "# C\n\n## [Unreleased]\n\n## [0.2.0]\n\n## [0.1.0]\n")
        self.assertFires("newest versioned heading")

    def test_changelog_missing(self):
        (self.dir / "CHANGELOG.md").unlink()
        self.assertFires("CHANGELOG.md: missing")

    # --- issue references (check_issue_refs) ---
    # The good tree carries NO issue refs, so every test here writes the refs it
    # asserts on. That is deliberate: a fixture pre-loaded with a valid ref set
    # would make the "clean tree" assertion carry the check's weight, and a
    # check that only ever sees good input proves nothing (F48).
    _ISSUE_BASE = "https://github.com/betmoar/cc-operator-plugin/issues/"

    def _changelog_with(self, body):
        write(self.dir / "CHANGELOG.md",
              "# C\n\n## [Unreleased]\n\n## [0.1.0] - 2026-07-06\n\n" + body)

    def _git(self, *args):
        return subprocess.run(("git", "-C", str(self.dir)) + args,
                              capture_output=True, text=True)

    def _init_repo(self, *tracked):
        # SKIP, not error, when git is absent. Measured on python:3.11-slim,
        # which ships no git: both callers died on `git init` with a traceback,
        # so a machine without git reported two ERRORS that read like defects in
        # the code under test. Every other environment dependency in this project
        # announces a skip instead — root for the chmod cases, a missing
        # .operator/bin for the #24 exec-bit control — and the reason is the
        # same: an unrunnable case must say it did not run.
        if shutil.which("git") is None:
            self.skipTest("git is not installed; the tracked-files path cannot be exercised")
        self._git("init", "-q")
        self._git("config", "user.email", "t@example.invalid")
        self._git("config", "user.name", "t")
        self._git("add", "--", *tracked)
        self._git("commit", "-qm", "t")
        # The listing must be non-empty, or the check falls back to the glob and
        # this test silently proves nothing about the git path.
        listed = self._git("ls-files", "*.md").stdout.split()
        self.assertTrue(listed, "fixture did not track any markdown")
        return listed

    def test_charter_too_long(self):
        write(self.dir / "templates" / "OPERATOR.md",
              GOOD_CHARTER + "\nx" * (vp.CHARTER_MAX_LINES + 5))
        self.assertFires("cap")

    def test_charter_section_order(self):
        scrambled = "# OPERATOR.md\n\n" + "\n".join(
            f"## {sec}\n\nrule [D:t{i}].\n"
            for i, sec in enumerate(reversed(vp.CHARTER_SECTION_ORDER)))
        write(self.dir / "templates" / "OPERATOR.md", scrambled)
        self.assertFires("section order")

    def test_charter_untagged_section(self):
        bad = "# OPERATOR.md\n\n" + "".join(
            (f"## {sec}\n\nrule [D:t{i}].\n" if sec != "HANDOFF"
             else f"## {sec}\n\nno tag here.\n")
            for i, sec in enumerate(vp.CHARTER_SECTION_ORDER))
        write(self.dir / "templates" / "OPERATOR.md", bad)
        self.assertFires("no citation tag")

    def test_charter_doc_tag_without_index_entry_fires(self):
        # A [DOC:spec-*] tag added to the charter with no `### spec-*` entry in
        # docs/spec/TAGS.md must fail: the index is where DOC tags resolve in a
        # clone (#76 step E — 22 of 24 used to dangle against untracked files).
        write(self.dir / "templates" / "OPERATOR.md",
              GOOD_CHARTER.replace("[DOC:spec-D4]", "[DOC:spec-D4] [DOC:spec-ghost]", 1))
        self.assertFires("[DOC:spec-ghost] has no `### spec-ghost` entry")

    def test_charter_doc_tags_with_missing_index_fires(self):
        (self.dir / "docs" / "spec" / "TAGS.md").unlink()
        self.assertFires("docs/spec/TAGS.md: missing")

    def test_charter_orphan_index_entry_is_not_a_finding(self):
        # The reverse direction is deliberately unchecked: an entry surviving a
        # retired tag is history, not rot.
        p = self.dir / "docs" / "spec" / "TAGS.md"
        p.write_text(p.read_text() + "\n### spec-retired\n\nold entry.\n",
                     encoding="utf-8")
        probs = []
        vp.check_charter(self.dir, probs)
        self.assertEqual([x for x in probs if "spec-retired" in x], [])

    def test_charter_missing_project_cli_path(self):
        write(self.dir / "templates" / "OPERATOR.md",
              GOOD_CHARTER.replace(".operator/bin/ops-verdict.sh",
                                   "scripts/ops-verdict.sh"))
        self.assertFires(".operator/bin/ops-verdict.sh")

    def test_charter_missing_adopt_cli_path(self):
        # Every CLI ops-init installs must be reachable from the charter —
        # ops-adopt.sh is the /clear recovery path and was the one most likely
        # to be shipped without a charter reference.
        write(self.dir / "templates" / "OPERATOR.md",
              GOOD_CHARTER.replace(".operator/bin/ops-adopt.sh", "ops-adopt.sh"))
        self.assertFires(".operator/bin/ops-adopt.sh")

    # --- 5. ledger schema ---
    def test_verdicts_header_wrong(self):
        write(self.dir / "templates" / "VERDICTS-header.md",
              "# V\n| Gate | Criterion | Evidence (cmd) | PASS/FAIL |\n")
        self.assertFires("byte-match")

    # --- decisions schema (stage 2: the deviation gate parses this enum) ---
    def test_decisions_kind_enum_drift_fires(self):
        # Drop HANDOFF-MARK from the enum — a presented decision would then read
        # as unpresented forever. check_decisions_schema pins every kind token.
        write(self.dir / "templates" / "DECISIONS-header.md",
              "# Decisions\n"
              "# gated: DEVIATION | ESCALATION | GATE-EXCEPTION\n"
              "# record: DECISION | DEFERRED-VERDICT\n")
        self.assertFires("missing 'HANDOFF-MARK'")

    def test_decisions_enum_missing_split_fires(self):
        # All kinds present but no gated/record split — a reader cannot tell which
        # kinds block Stop (issue #9). check_decisions_schema pins the split.
        write(self.dir / "templates" / "DECISIONS-header.md",
              "# <ISO-date> | <eng> | "
              "<DEVIATION|ESCALATION|GATE-EXCEPTION|DECISION|DEFERRED-VERDICT"
              "|HANDOFF-MARK> | <what> | <why>\n")
        self.assertFires("does not distinguish gated from record kinds")

    def test_decisions_reader_missing_handoff_mark_fires(self):
        # A deviation-gate reader that never matches HANDOFF-MARK never clears —
        # the enum is declared but the consumer drifted (F30 call-site half).
        # 0.10: the shared scan lives in lib/partition.sh.
        p = self.dir / "scripts" / "lib" / "partition.sh"
        write(p, p.read_text().replace("HANDOFF-MARK", "NO-SUCH-MARK"))
        self.assertFires("does not reference HANDOFF-MARK")

    def test_decisions_reader_gated_literal_drift_fires(self):
        # A reader that counts a kind the gate should ignore (DECISION) diverges
        # from the header's gated set (issue #9). Mutate the shared lib's gated
        # literal (the scan lives there since 0.10) so only this check fires.
        p = self.dir / "scripts" / "lib" / "partition.sh"
        write(p, p.read_text().replace(
            "DEVIATION|ESCALATION|GATE-EXCEPTION", "DEVIATION|ESCALATION|DECISION"))
        self.assertFires("deviation gate does not count the gated kinds")

    # --- 6. agents ---
    def test_agent_missing_model(self):
        p = self.dir / "agents" / "op-author.md"
        write(p, p.read_text().replace("model: opus\n", ""))
        self.assertFires("missing 'model:'")

    def test_agent_pinned_model_id(self):
        p = self.dir / "agents" / "op-mechanic.md"
        write(p, p.read_text().replace("model: sonnet", "model: claude-sonnet-4-6"))
        self.assertFires("pinned ID")

    def test_agent_missing_needs_context(self):
        p = self.dir / "agents" / "op-mechanic.md"
        write(p, p.read_text().replace("NEEDS_CONTEXT", "just-guess"))
        self.assertFires("NEEDS_CONTEXT")

    def test_agent_build_naming(self):
        p = self.dir / "agents" / "op-reviewer.md"
        write(p, p.read_text() + "\nRefer to the unknowns-harness F1 finding.\n")
        self.assertFires("build-specific naming")

    # --- 7. hook ---
    def test_hook_wrong_command(self):
        p = self.dir / "hooks" / "hooks.json"
        d = json.loads(p.read_text())
        d["hooks"]["Stop"][0]["hooks"][0]["command"] = "bash other.sh"
        write(p, json.dumps(d))
        self.assertFires("ops-stop-hook.sh")

    def test_sessionstart_hook_missing(self):
        # Without it the agent never learns its session id, so every sentinel
        # is opened unowned and blocks every concurrent session.
        p = self.dir / "hooks" / "hooks.json"
        d = json.loads(p.read_text())
        del d["hooks"]["SessionStart"]
        write(p, json.dumps(d))
        self.assertFires("no SessionStart hook command found")

    def test_sessionstart_hook_not_plugin_root(self):
        p = self.dir / "hooks" / "hooks.json"
        d = json.loads(p.read_text())
        d["hooks"]["SessionStart"][0]["hooks"][0]["command"] = \
            "bash scripts/ops-sessionstart-hook.sh"
        write(p, json.dumps(d))
        self.assertFires("SessionStart command should use")

    # --- 8. scripts ---
    def test_script_syntax_error(self):
        write(self.dir / "scripts" / "ops-init.sh",
              "#!/usr/bin/env bash\nif then fi oops(\n")
        self.assertFires("syntax error")

    def test_script_missing(self):
        (self.dir / "scripts" / "ops-verdict.sh").unlink()
        self.assertFires("scripts/ops-verdict.sh: missing")

    def test_ops_task_missing(self):
        (self.dir / "scripts" / "ops-task.sh").unlink()
        self.assertFires("scripts/ops-task.sh: missing")

    def test_ops_adopt_missing(self):
        (self.dir / "scripts" / "ops-adopt.sh").unlink()
        self.assertFires("scripts/ops-adopt.sh: missing")

    def test_ops_sessionstart_hook_missing(self):
        (self.dir / "scripts" / "ops-sessionstart-hook.sh").unlink()
        self.assertFires("scripts/ops-sessionstart-hook.sh: missing")

    # --- 8b. the statusline manifest ---
    # cc-status discovers the segment ONLY through this manifest and skips an
    # unresolvable renderer silently — no error, the segment just never appears
    # and the bar looks like a project with no open tasks. Nothing else in the
    # build would notice, which is exactly why it is a checked contract.

    def test_statusline_manifest_missing(self):
        (self.dir / ".claude-plugin" / "statusline.json").unlink()
        self.assertFires("statusline.json: missing")

    def test_statusline_render_path_does_not_resolve(self):
        write(self.dir / ".claude-plugin" / "statusline.json", json.dumps({
            "name": "cc-operator", "render": "scripts/moved.sh", "order": 30,
        }))
        self.assertFires("does not resolve")

    def test_statusline_name_mismatch(self):
        write(self.dir / ".claude-plugin" / "statusline.json", json.dumps({
            "name": "cc-operatorr", "render": "scripts/statusline.sh",
        }))
        self.assertFires("the key users toggle")

    def test_statusline_order_not_an_integer(self):
        write(self.dir / ".claude-plugin" / "statusline.json", json.dumps({
            "name": "cc-operator", "render": "scripts/statusline.sh",
            "order": "30",
        }))
        self.assertFires("is not an integer")

    def test_statusline_reader_bound_is_enforced(self):
        # The segment renders on a ~300ms timer, so a lost byte bound is a
        # permanently wedged bar (6.20s per parse on a 64MB single-line
        # sentinel, measured), not merely a slow one. It is registered in
        # check_reader_bounds alongside the three once-per-event readers.
        write(self.dir / "scripts" / "statusline.sh",
              '#!/usr/bin/env bash\nwhile IFS= read -r line; do :; done < "$1"\n')
        self.assertFires("scripts/statusline.sh")

    # --- 9/10. audit guardrails: reader bounds + guard parity ---
    # These enforce cross-file couplings that were previously prose in CLAUDE.md
    # and were still violated: the byte bound reached one of four readers, and a
    # guard applied to the wrong one of two name-checks wedged legacy tasks.

    def _write_readers(self, verdict_body=None, adopt_body=None, hook_body=None):
        """Install minimal but realistic reader scripts into the fixture tree."""
        good_hook = (
            "#!/usr/bin/env bash\n"
            ". lib/partition.sh\n"
            "[ ! -L \"$1\" ] || exit 0\n" + JSON_GET)
        good_verdict = (
            "#!/usr/bin/env bash\n"
            "check_bare_name() { case \"$2\" in .*) die x ;; *__*) die x ;; esac; }\n"
            "check_owner_name() { :; }\n"
            "[ ! -L \"$f\" ] || exit 0\n"
            "sentinel_owner_of_name() {\n"
          "  case \"$_o\" in \"\" | */* | .* | *\"|\"* | *[[:space:]]*) printf '\\n'; return 0 ;; esac\n"
          "}\n"
            "# F2: refuse a symlink fragment before the write + skip on both reads\n"
            '[ -L "$FRAGDIR/$who.md" ] && exit 1\n'
            '[ -f "$frag" ] && [ ! -L "$frag" ] && :;\n'
            '[ -f "$frag" ] && [ ! -L "$frag" ] && :;\n'
            "# F17: both verdicts.d fragment scanners use the same 1MiB read bound\n"
            "while IFS= read -r -n 1048576 row; do :; done < \"$frag\"\n"
            "while IFS= read -r -n 1048576 line; do :; done < \"$frag\"\n")
        good_adopt = (
            "#!/usr/bin/env bash\n"
            "check_bare_name() { case \"$2\" in .*) die x ;; *__*) die x ;; esac; }\n"
            "check_owner_name() { :; }\n"
            "[ ! -L \"$F\" ] || exit 0\n"
            # PREV reject-set (F15): the owner now arrives in the sentinel NAME,
            # so the sanitisation moved with it — adoption reads no file at all.
            'case "${PREV:-}" in */* | .* | *"|"* | *[[:space:]]* | *[[:cntrl:]]* | *.exempt) PREV="<invalid>" ;; esac\n')
        write(self.dir / "scripts" / "ops-stop-hook.sh", hook_body or good_hook)
        write(self.dir / "scripts" / "ops-verdict.sh", verdict_body or good_verdict)
        write(self.dir / "scripts" / "ops-adopt.sh", adopt_body or good_adopt)
        write(self.dir / "scripts" / "ops-task.sh",
              "#!/usr/bin/env bash\n"
              "check_bare_name() { case \"$2\" in .*) die x ;; *__*) die x ;; esac; }\n"
              "check_owner_name() { :; }\n"
              "[ ! -L \"$F\" ] || exit 0\n")
        write(self.dir / "scripts" / "statusline.sh", GOOD_STATUSLINE)

    def bounds_problems(self):
        probs = []
        vp.check_reader_bounds(self.dir, probs)
        vp.check_guard_parity(self.dir, probs)
        return probs

    def test_reader_bounds_clean_tree_passes(self):
        self._write_readers()
        self.assertEqual(self.bounds_problems(), [])

    def test_unbounded_read_fires(self):
        self._write_readers(verdict_body=(
            "#!/usr/bin/env bash\n"
            "check_bare_name() { case \"$2\" in .*) die x ;; *__*) die x ;; esac; }\n"
            "check_owner_name() { :; }\n"
            "while IFS= read -r line; do :; done < \"$f\"\n"
            "while IFS= read -r -n 512 row; do :; done < \"$frag\"\n"))
        probs = self.bounds_problems()
        self.assertTrue(any("unbounded `read -r`" in p for p in probs), probs)

    # The NUL probe (`read -r -d '' -n 512`) MUST carry a chunk cap (_np … le
    # 40). An uncapped probe still detects a late NUL but walks a newline-less
    # multi-MB tiers.env end-to-end first — 66-70s on 64MB vs 0.11s capped
    # (bash 3.2.57, 2026-08-04; the 4.0s first cited is wrong by ~15x).
    # These two mutation tests pin the parity the F59 fix established for the
    # hook but left tiers/render drifting on.

    _CAPPED_PROBE = (
        "  if ! (LC_ALL=C _np=0\n"
        "        while IFS= read -r -d '' -n 512 _nulprobe; do\n"
        "          _np=$((_np + 1)); [ \"$_np\" -le 40 ] || exit 1\n"
        "          [ \"${#_nulprobe}\" -eq 512 ] || exit 1\n"
        "        done < \"$1\") 2>/dev/null; then die x; fi\n")
    _UNCAPPED_PROBE = (
        "  if ! (LC_ALL=C\n"
        "        while IFS= read -r -d '' -n 512 _nulprobe; do\n"
        "          [ \"${#_nulprobe}\" -eq 512 ] || exit 1\n"
        "        done < \"$1\"); then die x; fi\n")

    def test_capped_nul_probe_passes(self):
        write(self.dir / "scripts" / "ops-tiers.sh",
              "#!/usr/bin/env bash\n"
              "while IFS= read -r -n 512 line; do :; done < \"$1\"\n"
              + self._CAPPED_PROBE)
        probs = []
        vp.check_reader_bounds(self.dir, probs)
        self.assertEqual([p for p in probs if "chunk cap" in p], [])

    def test_uncapped_nul_probe_fires(self):
        # The exact drift F59 prevented: a probe that loops whole-file with no
        # _np counter. It still has `read -r -n 512` (counts as byte-bounded
        # above), so only the new chunk-cap check catches the missing bound.
        write(self.dir / "scripts" / "ops-render.sh",
              "#!/usr/bin/env bash\n"
              "while IFS= read -r -n 512 line; do :; done < \"$1\"\n"
              + self._UNCAPPED_PROBE)
        probs = []
        vp.check_reader_bounds(self.dir, probs)
        self.assertTrue(any("chunk cap" in p for p in probs), probs)

    def test_missing_symlink_guard_fires(self):
        # The F65 -L guard is a reader coupling (task/verdict/adopt CLIs, the
        # statusline, and lib/partition.sh — which has carried the hook's
        # pending/ enumeration since 0.10). A reader that loses its `-L` test
        # fails the build.
        p = self.dir / "scripts" / "lib" / "partition.sh"
        write(p, p.read_text().replace('[ ! -L "$decisions" ] || exit 0', ":"))
        probs = self.bounds_problems()
        self.assertTrue(any("symlink" in p and "lib/partition.sh" in p
                            for p in probs), probs)

    def test_probe_cap_raised_to_substring_superset_fires(self):
        # The first version of the chunk-cap check was a substring test
        # ("le 40" in window), so `-le 400000` — effectively uncapped — passed
        # as if it were 40 (code-review of f4cae1a, 2026-08-04). The cap's
        # VALUE must be parsed and bounded, not string-matched.
        write(self.dir / "scripts" / "ops-tiers.sh",
              "#!/usr/bin/env bash\n"
              "while IFS= read -r -n 512 line; do :; done < \"$1\"\n"
              + self._CAPPED_PROBE.replace("-le 40 ", "-le 400000 "))
        probs = []
        vp.check_reader_bounds(self.dir, probs)
        self.assertTrue(any("chunk cap" in p for p in probs), probs)

    def test_probe_variable_rename_does_not_evade_the_check(self):
        # The probe detector was keyed to the literal variable name _nulprobe,
        # so renaming it (with the cap fully removed) produced zero problems
        # (same review). Any `read -r -d '' -n N <var>` loop over a file is a
        # NUL probe and must carry the cap, whatever the variable is called.
        write(self.dir / "scripts" / "ops-tiers.sh",
              "#!/usr/bin/env bash\n"
              "while IFS= read -r -n 512 line; do :; done < \"$1\"\n"
              + self._UNCAPPED_PROBE.replace("_nulprobe", "_chunk"))
        probs = []
        vp.check_reader_bounds(self.dir, probs)
        self.assertTrue(any("chunk cap" in p for p in probs), probs)

    def test_comments_mentioning_read_do_not_fire(self):
        # A checker that fires on its own documentation trains the maintainer to
        # ignore the build. This exact bug was introduced and caught in the audit.
        self._write_readers(adopt_body=(
            "#!/usr/bin/env bash\n"
            "# `read -r` is bounded by LINES, not bytes — discussion only.\n"
            "#    a plain read -r would slurp the whole line first\n"
            "check_bare_name() { case \"$2\" in .*) die x ;; *__*) die x ;; esac; }\n"
            "check_owner_name() { :; }\n"
            "[ ! -L \"$F\" ] || exit 0\n"
            "while IFS= read -r -n 512 line; do :; done < \"$F\"\n"
            # PREV reject-set (F15): carries *.exempt (check_guard_parity pin)
            'case "${PREV:-}" in */* | .* | *"|"* | *[[:space:]]* | *[[:cntrl:]]* | *.exempt) PREV="<invalid>" ;; esac\n'))
        self.assertEqual(self.bounds_problems(), [])

    def test_missing_guard_in_one_cli_fires(self):
        self._write_readers()
        write(self.dir / "scripts" / "ops-task.sh",
              "#!/usr/bin/env bash\ncheck_bare_name() { case \"$2\" in .*) die x ;; *__*) die x ;; esac; }\n")
        probs = self.bounds_problems()
        self.assertTrue(any("missing check_owner_name()" in p for p in probs), probs)

    def test_hook_dropping_whitespace_reject_fires(self):
        # 0.10: the readers' parser lives in lib/partition.sh — drop the arm there.
        p = self.dir / "scripts" / "lib" / "partition.sh"
        write(p, p.read_text().replace(
            r"""*"|"* | *[[:space:]]*)""", '*"|"*)'))
        probs = self.bounds_problems()
        self.assertTrue(any("whitespace owners" in p for p in probs), probs)

    # --- 11. slash commands ---
    # The plugin's entry points are its slash commands. An empty frontmatter
    # block, a missing key, or a bare scripts/ path are all silent shipping
    # bugs — the command either won't register or will fail in a target project.

    def test_a_new_permission_guard_fires(self):
        # #21: a permission test is INERT for uid 0, so a NEW one must not enter
        # a gate script unreviewed. The class went 1 -> 2 instances when #27's
        # fix added the -w half while the issue still said one; this is what
        # stops the third from arriving silently.
        real = (self.dir / "scripts" / "ops-task.sh").read_text(encoding="utf-8")
        write(self.dir / "scripts" / "ops-task.sh",
              real.replace("#!/usr/bin/env bash\n",
                           '#!/usr/bin/env bash\n[ -w /tmp ] || true\n', 1))
        probs = self.problems()
        self.assertTrue(any("permission test" in p and "ops-task.sh" in p
                            for p in probs), probs)

    def test_commands_dir_optional(self):
        # A plugin that ships only agents need not have commands/. The good-tree
        # fixture builds one; removing it must stay clean (the check treats
        # absence as "not applicable", not as a defect).
        shutil.rmtree(self.dir / "commands")
        self.assertEqual(self.problems(), [])

    def test_empty_commands_dir_fires(self):
        for f in (self.dir / "commands").glob("*.md"):
            f.unlink()
        self.assertFires("holds no *.md")

    def test_command_without_frontmatter_fires(self):
        write(self.dir / "commands" / "start.md", "Body only, no frontmatter.\n")
        self.assertFires("no `---` frontmatter block")

    def test_command_missing_required_key_fires(self):
        write(self.dir / "commands" / "start.md", textwrap.dedent("""\
            ---
            description: d
            allowed-tools: Bash(bash:*)
            ---
            Body.
            """))
        self.assertFires("missing required key 'argument-hint'")

    def test_command_empty_argument_hint_is_valid(self):
        # argument-hint: [] is a legitimate empty value (handoff.md uses it).
        write(self.dir / "commands" / "handoff.md", textwrap.dedent("""\
            ---
            description: d
            argument-hint: []
            allowed-tools: Read
            ---
            Body.
            """))
        self.assertNotIn("argument-hint", " ".join(self.problems()))

    def test_command_relative_script_path_fires(self):
        write(self.dir / "commands" / "start.md", textwrap.dedent("""\
            ---
            description: d
            argument-hint: []
            allowed-tools: Bash(bash:*)
            ---
            Run `bash scripts/ops-init.sh`.
            """))
        self.assertFires("without ${CLAUDE_PLUGIN_ROOT}")

    def test_command_plugin_root_path_is_valid(self):
        # The layout-independent form must NOT fire — the whole point of the
        # check is to steer toward this, not forbid script invocation outright.
        write(self.dir / "commands" / "start.md", textwrap.dedent("""\
            ---
            description: d
            argument-hint: []
            allowed-tools: Bash(bash:*)
            ---
            Run `bash "${CLAUDE_PLUGIN_ROOT}/scripts/ops-init.sh"`.
            """))
        self.assertNotIn("CLAUDE_PLUGIN_ROOT", " ".join(
            p for p in self.problems() if "commands/" in p))

    def test_real_commands_are_clean(self):
        # Guards the shipped tree, not just a fixture.
        probs = []
        vp.check_commands(ROOT, probs)
        self.assertEqual(probs, [])

    # --- 12. workflows: meta-first, ROUTABLE canonical+applied, charset, parity ---
    # check_workflows validates the tier-guard infrastructure per file; the audit
    # (2026-07-30) added BAD_CHARSET so JS and shell agree on the model-id
    # charset (audit F01 — JS ROUTABLE accepted whitespace the shell rejects).
    # check_workflow_parity holds the copy-pasted block together (the sandbox
    # forbids imports, measured), so a regex divergence between workflows fails.

    def _wf(self, name, body_extra=""):
        """A conforming workflow with the shared invariants."""
        return (
            f'export const meta = {{ name: "{name}", description: "d" }};\n'
            'const BAD_CHARSET = /[^\\w./:@[\\]-]/;\n'
            'for (const [n, id] of Object.entries({JUDGMENT:"claude-opus-5"})) {\n'
            '  if (BAD_CHARSET.test(id)) throw new Error("x");\n'
            '}\n' + body_extra
        )

    def test_workflow_missing_meta_first_fires(self):
        write(self.dir / "workflows" / "review.js",
              '// stray comment\n' + self._wf("review"))
        self.assertFires("does not begin with")

    def test_workflow_reintroduced_routable_fires(self):
        # The inverse of the pre-0.8.3 case that lived here. An id-shape
        # catalogue used to be REQUIRED and pinned to a canonical literal; it is
        # now a finding. The realistic path back is a maintainer who sees an
        # unguarded id reach dispatch and writes the obvious-looking guard —
        # every other test would still pass, because none of them ask whether
        # operator should be judging model ids at all. This one does.
        write(self.dir / "workflows" / "review.js",
              self._wf("review", 'const ROUTABLE = /^glm-|^claude-/;\n'))
        self.assertFires("must not come back")

    def test_workflow_routable_in_a_comment_is_not_a_reintroduction(self):
        # The ROUTABLE check reads RAW text on purpose, so this case pins the
        # boundary: prose ABOUT the removed guard — which the shipped workflows
        # all carry, and this file's own comments do — must not fire. Without
        # the `const\s+ROUTABLE\s*=` anchor, documenting the decision would
        # break the build that enforces it.
        write(self.dir / "workflows" / "review.js",
              self._wf("review", "// ROUTABLE was removed in 0.8.3; see check_workflows (c).\n"))
        probs = []
        vp.check_workflows(self.dir, probs)
        self.assertEqual([p for p in probs if "must not come back" in p], [])

    def test_workflow_uniform_bad_charset_drift_fires(self):
        # The gap a review found: check_workflow_parity compares the copies to
        # EACH OTHER, so neutering BAD_CHARSET in ALL of them at once passed
        # every gate (node 25/25, validator rc 0). Four identically-broken files
        # are trivially "in parity". Uniform drift is the REALISTIC failure —
        # the copy-paste convention tells a maintainer to edit one and copy it
        # to the rest. Only a canonical pin catches it.
        # Derived from the tree, not a hardcoded pair: "uniform" means EVERY
        # copy. Adding a third workflow to the fixture (plan.js, for #58) left
        # this rewriting two of three, so the drift stopped being uniform and
        # the parity assertion below started failing for the wrong reason —
        # the test would have been measuring a partial rewrite it never meant.
        for f in sorted((self.dir / "workflows").glob("*.js")):
            write(f, f.read_text(encoding="utf-8").replace(
                "const BAD_CHARSET = /[^\\w./:@[\\]-]/;",
                "const BAD_CHARSET = /(?!)/;"))
        probs = []
        vp.check_workflow_parity(self.dir, probs)
        self.assertEqual(probs, [], "parity alone cannot see uniform drift")
        self.assertFires("BAD_CHARSET regex is")

    def test_workflow_bad_charset_never_applied_fires(self):
        # A declared-but-unused BAD_CHARSET guards nothing. Deleting only the
        # `.test(id)` call site leaves the literal in place, so both the parity
        # check and the canonical pin still pass — this is the third way the
        # guard can be silently removed.
        write(self.dir / "workflows" / "review.js",
              self._wf("review").replace(
                  "  if (BAD_CHARSET.test(id)) throw new Error(\"x\");\n", ""))
        self.assertFires("BAD_CHARSET is declared but never applied")

    def test_workflow_missing_bad_charset_fires(self):
        write(self.dir / "workflows" / "review.js",
              self._wf("review")
              .replace("const BAD_CHARSET = /[^\\w./:@[\\]-]/;\n", "")
              .replace(" || BAD_CHARSET.test(id)", ""))
        self.assertFires("no `const BAD_CHARSET")

    def test_workflow_line_comment_neuters_bad_charset_fires(self):
        # F48/F57 class, demonstrated live against check_workflows by the
        # full-PR panel: a `.test(` call site moved into a comment satisfied the
        # raw-text application regex while the real guard was gone. The
        # declaration stays intact, so only the application check can catch it —
        # and only if it reads a comment-stripped view. `//` form; the sibling
        # below covers the block-comment syntax. Retargeted from ROUTABLE in
        # 0.8.3 — same class, and now the ONLY guard it can be done to.
        write(self.dir / "workflows" / "review.js",
              self._wf("review").replace(
                  "  if (BAD_CHARSET.test(id)) throw new Error(\"x\");",
                  "  // if (BAD_CHARSET.test(id)) throw new Error(\"x\");"))
        self.assertFires("BAD_CHARSET is declared but never applied")

    def test_workflow_block_comment_neuters_bad_charset_fires(self):
        # Same class through the OTHER comment syntax — block comments are an
        # idiom in the workflows, so the strip must handle /* */ too (F57).
        write(self.dir / "workflows" / "review.js",
              self._wf("review").replace(
                  "if (BAD_CHARSET.test(id))",
                  "if (/* BAD_CHARSET.test(id) */ false)"))
        self.assertFires("BAD_CHARSET is declared but never applied")

    def test_workflow_parity_holds_on_good_tree(self):
        # make_good_tree writes two workflows with an identical BAD_CHARSET.
        probs = []
        vp.check_workflow_parity(self.dir, probs)
        self.assertEqual(probs, [])

    def test_workflow_parity_diverged_bad_charset_fires(self):
        # Diverge BAD_CHARSET in one workflow only — the audit F01 fix's lock.
        write(self.dir / "workflows" / "review.js",
              self._wf("review").replace("const BAD_CHARSET = /[^\\w./:@[\\]-]/;",
                                         "const BAD_CHARSET = /[^\\w./:@-]/;"))
        probs = []
        vp.check_workflow_parity(self.dir, probs)
        self.assertTrue(any("BAD_CHARSET has diverged" in p for p in probs), probs)

    def test_real_workflows_pass_all_checks(self):
        # Guards the shipped tree, not just a fixture.
        probs = []
        vp.check_workflows(ROOT, probs)
        vp.check_workflow_parity(ROOT, probs)
        vp.check_workflow_default_tiers(ROOT, probs)
        vp.check_workflow_agent_types(ROOT, probs)
        self.assertEqual(probs, [])

    # --- workflow agentType resolution (F22) ---
    # A workflow agentType resolves against the PLUGIN registry; a rendered
    # project-layer agent cannot be named there. crawl.js shipped dispatching
    # op-scout while claiming op-crawler — which did not exist as an agent.

    def test_workflow_agent_type_unshipped_fires(self):
        write(self.dir / "workflows" / "review.js",
              'export const meta = { name: "review", description: "d" };\n'
                            'agent("x", { agentType: "cc-operator:op-ghost" });\n')
        probs = []
        vp.check_workflow_agent_types(self.dir, probs)
        self.assertTrue(any("op-ghost" in p and "names no shipped agent" in p
                            for p in probs), probs)

    def test_workflow_agent_type_shipped_is_clean(self):
        write(self.dir / "workflows" / "review.js",
              'export const meta = { name: "review", description: "d" };\n'
                            'agent("x", { agentType: "cc-operator:op-author" });\n')
        probs = []
        vp.check_workflow_agent_types(self.dir, probs)
        self.assertEqual(probs, [])

    def test_workflow_agent_type_in_lookup_table_fires(self):
        # The gap a review found after 0.8.3: the checker anchored on the
        # `agentType:` KEY, and dispatch.js resolves its agentType from a SEATS
        # table and passes the shorthand `agentType,`. The regex matched NOTHING
        # in that file — measured, every one of its six seat values retyped to a
        # nonexistent agent shipped green (validator rc 0, node 100/0, pytest
        # 213/0). Both the file's own comment and CLAUDE.md's coupling row cited
        # this check as the reason the map is a literal. Matching the VALUE
        # covers a table entry and a call site alike.
        write(self.dir / "workflows" / "review.js",
              'export const meta = { name: "review", description: "d" };\n'
                            'const SEATS = { scout: "cc-operator:op-ghost" };\n'
              'agent("x", { agentType: SEATS[s] });\n')
        probs = []
        vp.check_workflow_agent_types(self.dir, probs)
        self.assertTrue(any("op-ghost" in p and "names no shipped agent" in p
                            for p in probs), probs)

    def test_workflow_agent_type_in_a_comment_is_not_a_finding(self):
        # The boundary the value-form regex has to respect, and the reason it
        # reads a comment-stripped view: dispatch.js's own comment quotes
        # `"cc-operator:op-" + seat` while arguing AGAINST concatenating. A
        # checker that reads its own documentation as code fires on the file
        # that got it right.
        write(self.dir / "workflows" / "review.js",
              'export const meta = { name: "review", description: "d" };\n'
                            '// never write "cc-operator:op-ghost" as a computed string\n'
              '/* nor "cc-operator:op-phantom" in a block comment */\n'
              'agent("x", { agentType: "cc-operator:op-author" });\n')
        probs = []
        vp.check_workflow_agent_types(self.dir, probs)
        self.assertEqual(probs, [])

    # --- charter byte bounds (F19) ---
    # The 150-line cap bounds ALWAYS-ON tokens; a line-count-only gate is
    # gameable by packing prose into one long line (a 286-char line shipped
    # through a green validator). Non-table lines are length-bounded; table
    # rows (|-prefixed) are exempt; the file has a total-bytes ceiling.

    def test_charter_packed_line_fires(self):
        write(self.dir / "templates" / "OPERATOR.md",
              GOOD_CHARTER + "\npacked rule [D:tag-x] " + "y" * 120 + "\n")
        probs = []
        vp.check_charter(self.dir, probs)
        self.assertTrue(any("char line" in p for p in probs), probs)

    def test_charter_long_table_row_is_exempt(self):
        write(self.dir / "templates" / "OPERATOR.md",
              GOOD_CHARTER + "\n| cap | " + "y" * 120 + " | act [D:tag-t] |\n")
        probs = []
        vp.check_charter(self.dir, probs)
        self.assertFalse(any("char line" in p for p in probs), probs)

    def test_charter_byte_ceiling_fires(self):
        filler = "\n".join(f"r{i} [D:tag-f] " + "z" * 90 for i in range(95))
        write(self.dir / "templates" / "OPERATOR.md", GOOD_CHARTER + "\n" + filler)
        probs = []
        vp.check_charter(self.dir, probs)
        self.assertTrue(any("ceiling" in p for p in probs), probs)

    # --- 13. workflow default tiers: values must be harness aliases (#76 s2) ---
    # The namespace tests that lived here died with the KNOWN_TIERS catalogue:
    # workflows no longer declare which tier names exist (that was five copies
    # of the resolver's facts). What replaces them is the alias pin — a vendor
    # model id pasted back into a DEFAULT_TIERS is the reflex fix that
    # recreates the catalogue one file at a time, and this is the only gate
    # that sees it.

    def test_workflow_default_tiers_vendor_id_fires(self):
        write(self.dir / "workflows" / "review.js",
              'export const meta = { name: "review", description: "d" };\n'
              'const DEFAULT_TIERS = { JUDGMENT: "claude-opus-5" };\n')
        probs = []
        vp.check_workflow_default_tiers(self.dir, probs)
        self.assertTrue(any("not a harness alias" in p for p in probs), probs)

    def test_workflow_default_tiers_alias_is_clean(self):
        write(self.dir / "workflows" / "review.js",
              'export const meta = { name: "review", description: "d" };\n'
              'const DEFAULT_TIERS = { JUDGMENT: "opus", MECHANICAL: "haiku" };\n')
        probs = []
        vp.check_workflow_default_tiers(self.dir, probs)
        self.assertEqual(probs, [])

    def test_workflow_default_tiers_missing_reports(self):
        # Absence is a reshape, not a valid state — the locator must REPORT,
        # never silently skip (the fail-open shape _resolver_tier_names had).
        write(self.dir / "workflows" / "review.js",
              'export const meta = { name: "review", description: "d" };\n')
        probs = []
        vp.check_workflow_default_tiers(self.dir, probs)
        self.assertTrue(any("no `const DEFAULT_TIERS" in p for p in probs), probs)

    def test_workflow_default_tiers_in_comment_only_fires(self):
        # Code-only view, same convention as the namespace check it replaced:
        # a commented-out declaration must read as MISSING, not as conforming.
        write(self.dir / "workflows" / "review.js",
              'export const meta = { name: "review", description: "d" };\n'
              '// const DEFAULT_TIERS = { JUDGMENT: "opus" };\n')
        probs = []
        vp.check_workflow_default_tiers(self.dir, probs)
        self.assertTrue(any("no `const DEFAULT_TIERS" in p for p in probs), probs)

    def test_workflow_default_tiers_good_tree_holds(self):
        probs = []
        vp.check_workflow_default_tiers(self.dir, probs)
        self.assertEqual(probs, [])


class RenderTemplateTest(unittest.TestCase):
    """ops-render.sh splices a model id into each template's model: line. A
    template without one produces an agent silently bound to the default
    backend — the splice lands nowhere."""

    def setUp(self):
        self.dir = pathlib.Path(tempfile.mkdtemp())
        make_good_tree(self.dir)

    def tearDown(self):
        shutil.rmtree(self.dir, ignore_errors=True)

    def test_good_tree_templates_clean(self):
        probs = []
        vp.check_render_templates(self.dir, probs)
        self.assertEqual(probs, [])

    def test_template_without_model_line_fires(self):
        write(self.dir / "agents" / "_templates" / "default.tmpl",
              '---\nname: op-NAME\ntools: Read\n---\nbody\n')
        probs = []
        vp.check_render_templates(self.dir, probs)
        self.assertTrue(any("no `model:` frontmatter line" in p for p in probs), probs)

    def test_renderer_without_templates_fires(self):
        import shutil as _sh
        _sh.rmtree(self.dir / "agents" / "_templates")
        probs = []
        vp.check_render_templates(self.dir, probs)
        self.assertTrue(any("no *.tmpl found" in p for p in probs), probs)

    # --- F29: CR in a splice source ---
    # render_to()'s awk anchors on /^---$/; `---\r` does not match, so pre-fix a
    # CRLF source skipped every substitution and shipped the template's stale
    # model: value at exit 0. The renderer strips CR now; this is the build-time
    # backstop against the source itself drifting to CRLF.

    def test_crlf_template_fires(self):
        (self.dir / "agents" / "_templates" / "default.tmpl").write_bytes(
            b"---\r\nname: op-NAME\r\nmodel: haiku\r\n---\r\nbody\r\n")
        probs = []
        vp.check_render_templates(self.dir, probs)
        self.assertTrue(any("contains CR" in p for p in probs), probs)

    def test_crlf_plugin_root_agent_fires(self):
        # agents/op-*.md is the FIRST body source render_to tries (F14), so a
        # CRLF one is likelier than a CRLF template — and was unchecked.
        (self.dir / "agents" / "op-scout.md").write_bytes(
            b"---\r\nname: op-scout\r\nmodel: haiku\r\n---\r\nbody\r\n")
        probs = []
        vp.check_render_templates(self.dir, probs)
        self.assertTrue(any("op-scout.md" in p and "contains CR" in p
                            for p in probs), probs)

    def test_real_tree_splice_sources_are_lf(self):
        probs = []
        vp.check_render_templates(ROOT, probs)
        self.assertEqual(probs, [])

    # --- platform-dialect idioms (CI-caught: the wf segment died on Linux) ---
    # `stat -f %m F || stat -c %Y F` is not portable: GNU `-f` means FILESYSTEM
    # status, so it prints a filesystem block to STDOUT *and* exits 1 — the
    # fallback's output is concatenated onto that garbage. Same silence class
    # for `date -v` (BSD) / `date -d` (GNU).


class LockParityTest(unittest.TestCase):
    """The shared lock block must be identical in both writers.

    The guardrail exists because "keep the two implementations identical" was
    prose for the whole 0.4.0 cycle, and prose does not hold couplings — the
    same lesson `check_reader_bounds` was written for.
    """

    BLOCK = (
        "# >>> LOCK BLOCK\n"
        "LOCK_SPINS=300\n"
        "lock_acquire() {\n"
        '  echo "TOOL: warning — reclaiming" >&2\n'
        "}\n"
        "# <<< LOCK BLOCK\n"
    )

    def setUp(self):
        self.dir = pathlib.Path(tempfile.mkdtemp())
        (self.dir / "scripts").mkdir(parents=True)

    def tearDown(self):
        shutil.rmtree(self.dir, ignore_errors=True)

    def _write(self, verdict=None, adopt=None):
        v = self.BLOCK.replace("TOOL:", "ops-verdict:") if verdict is None else verdict
        a = self.BLOCK.replace("TOOL:", "ops-adopt:") if adopt is None else adopt
        write(self.dir / "scripts" / "ops-verdict.sh", "#!/usr/bin/env bash\n" + v)
        write(self.dir / "scripts" / "ops-adopt.sh", "#!/usr/bin/env bash\n" + a)

    def problems(self):
        probs = []
        vp.check_lock_parity(self.dir, probs)
        return probs

    def test_identical_blocks_pass(self):
        # The tool name in warnings is the ONE legitimate difference.
        self._write()
        self.assertEqual(self.problems(), [])

    def test_drifted_logic_fires(self):
        self._write(adopt=self.BLOCK.replace("TOOL:", "ops-adopt:")
                    .replace("LOCK_SPINS=300", "LOCK_SPINS=100"))
        probs = self.problems()
        self.assertTrue(any("drifted" in p for p in probs), probs)
        self.assertTrue(any("LOCK_SPINS" in p for p in probs), probs)

    def test_missing_markers_fire(self):
        self._write(adopt="lock_acquire() { :; }\n")
        probs = self.problems()
        self.assertTrue(any("LOCK BLOCK" in p for p in probs), probs)

    def test_real_scripts_are_in_parity(self):
        # Guards the shipped tree, not just a fixture.
        probs = []
        vp.check_lock_parity(ROOT, probs)
        self.assertEqual(probs, [])


class ResolverRendererParityTest(unittest.TestCase):
    """ops-tiers.sh and ops-render.sh parse the same tiers.env, so they must
    refuse the same ids and gate on the same tier set.

    Both couplings were prose in CLAUDE.md with nothing enforcing them, while
    the two neighbouring duplications (the bash lock, the workflow regexes) each
    got a parity check after the same lesson.
    """

    # A minimal but STRUCTURALLY CURRENT guard. It shrank in 0.8.3: the id-shape
    # arms and the $LENS_NAMESPACES allowlist were deleted from check_routable
    # (operator does not decide which model ids exist), so a fixture still
    # carrying them would test a shape the tree no longer has. What the parity
    # check pins now is the charset reject — the whole guard.
    ROUTABLE = (
        "check_routable() {\n"
        '  case "$2" in\n'
        '    "") die "$1 is empty" ;;\n'
        '    *[!A-Za-z0-9._:/@[\\]-]*)\n'
        '      die "$1=\'$2\' outside charset" ;;\n'
        "  esac\n"
        "  return 0\n"
        "}\n"
    )
    # Kept as an empty string rather than deleted: every `self.ROUTABLE +
    # self.LENS + self.TIERS` call site below stays readable, and a future
    # file-scope constant this fixture needs has an obvious slot.
    LENS = ''
    TIERS = 'TIER_NAMES="JUDGMENT IMPLEMENT MECHANICAL RECON"\n'

    def setUp(self):
        self.dir = pathlib.Path(tempfile.mkdtemp())
        (self.dir / "scripts").mkdir(parents=True)

    def tearDown(self):
        shutil.rmtree(self.dir, ignore_errors=True)

    def _write(self, tiers=None, render=None):
        for name, body in (("ops-tiers.sh", tiers), ("ops-render.sh", render)):
            write(self.dir / "scripts" / name,
                  "#!/usr/bin/env bash\n" +
                  (self.ROUTABLE + self.LENS + self.TIERS if body is None else body))

    def problems(self):
        probs = []
        vp.check_resolver_renderer_parity(self.dir, probs)
        return probs

    def test_identical_guards_pass(self):
        self._write()
        self.assertEqual(self.problems(), [])

    def test_reflowed_copy_passes(self):
        # The shipped copies are line-wrapped differently and one carries a
        # signature comment. Neither is a semantic difference; firing on them
        # would train maintainers to route around the check.
        reflowed = ("check_routable() { # check_routable <label> <id>\n"
                    '  case "$2" in "") die "$1 is empty" ;;\n'
                    '    *[!A-Za-z0-9._:/@[\\]-]*)\n'
                    '      die "$1=\'$2\' outside charset" ;; esac\n'
                    "  return 0\n}\n")
        self._write(render=reflowed + self.LENS + self.TIERS)
        self.assertEqual(self.problems(), [])

    def test_drifted_charset_fires(self):
        # The renderer accepts a charset the resolver refuses: it would write a
        # seat binding the resolver rejects.
        self._write(render=self.ROUTABLE.replace(
            "[!A-Za-z0-9._:/@[\\]-]", "[!A-Za-z0-9._-]") + self.TIERS)
        self.assertTrue(any("check_routable has drifted" in p
                            for p in self.problems()), self.problems())

    def test_gutted_in_both_copies_fires(self):
        # Equality alone is satisfied by two IDENTICALLY gutted copies — the
        # hole CANONICAL_BAD_CHARSET closed for the workflow regexes. Comments
        # are stripped before comparison, so commenting the body out in BOTH
        # files makes them compare equal.
        gutted = ("check_routable() {\n"
                  '  # case "$2" in *[!A-Za-z0-9._:/@[\\]-]*) die "x" ;; esac\n'
                  "  return 0\n}\n")
        self._write(tiers=gutted + self.TIERS, render=gutted + self.TIERS)
        probs = self.problems()
        self.assertTrue(any("agreeing on a guard that checks nothing" in p
                            for p in probs), probs)

    def test_missing_definition_fires(self):
        self._write(render="echo hi\n" + self.TIERS)
        self.assertTrue(any("no `check_routable()" in p
                            for p in self.problems()), self.problems())

    def test_renderer_tier_names_drift_fires(self):
        # A fifth tier added to the resolver per the coupling table leaves the
        # renderer's is_tier_name gating a stale namespace.
        self._write(tiers=self.ROUTABLE + self.LENS +
                    'TIER_NAMES="JUDGMENT IMPLEMENT MECHANICAL RECON EXTRA"\n')
        probs = self.problems()
        self.assertTrue(any("does not match the resolver's" in p
                            for p in probs), probs)

    def test_missing_tier_names_fires(self):
        self._write(render=self.ROUTABLE + self.LENS)
        self.assertTrue(any("no `TIER_NAMES" in p
                            for p in self.problems()), self.problems())

    # The three LENS_NAMESPACES cases that lived here (renderer drift, uniformly
    # wrong allowlist, missing assignment) went with the allowlist in 0.8.3.
    # They were good tests of a bad idea: they held five copied provider names
    # in exact agreement across two files and a canonical literal, and the set
    # was measurably stale anyway. No replacement case is owed — the behaviour
    # they guarded is gone, not relocated.

    def test_real_scripts_are_in_parity(self):
        probs = []
        vp.check_resolver_renderer_parity(ROOT, probs)
        self.assertEqual(probs, [])


class CompressorGuardTest(unittest.TestCase):
    """check_compressor must catch DRIFT, not just confirm presence. F48's
    lesson: a substring check that matches a comment or bare declaration passes
    while the enforcement is deleted. Each test builds the shared good tree,
    overwrites ops-compress.mjs with a MUTATED copy of the real file, and
    asserts check_compressor fires on that mutation.
    """

    def setUp(self):
        self.dir = pathlib.Path(tempfile.mkdtemp())
        make_good_tree(self.dir)
        self._real_comp = (pathlib.Path(__file__).resolve().parent.parent /
                           "scripts" / "ops-compress.mjs").read_text(encoding="utf-8")

    def tearDown(self):
        shutil.rmtree(self.dir, ignore_errors=True)

    def _probs(self, mutated_src):
        write(self.dir / "scripts" / "ops-compress.mjs", mutated_src)
        probs = []
        vp.check_compressor(self.dir, probs)
        return probs

    def test_shipped_compressor_is_clean(self):
        self.assertEqual(self._probs(self._real_comp), [],
                         "the shipped ops-compress.mjs must pass check_compressor clean")

    def test_mcp_exclusion_deletion_fires(self):
        src = re.sub(r'if\s*\(tool\.startsWith\(\s*"mcp__"\s*\)\s*\)\s*return null;',
                     '', self._real_comp, count=1)
        self.assertTrue(any("mcp__" in p for p in self._probs(src)),
                        self._probs(src))

    def test_mcp_exclusion_noop_body_fires(self):
        # A neutered body `{ /* no-op */ }` skips the exclusion without deleting
        # the call site — a bare call-site check passes. The guard now requires
        # the `return null` body (pr-review, 2026-08-03).
        src = self._real_comp.replace(
            'if (tool.startsWith("mcp__")) return null;',
            'if (tool.startsWith("mcp__")) { /* no-op */ }', 1)
        self.assertTrue(any("mcp__" in p for p in self._probs(src)), self._probs(src))

    def test_never_compress_emptied_fires(self):
        src = re.sub(r'NEVER_COMPRESS\s*=\s*new Set\(\s*\[[^\]]*\]',
                     'const NEVER_COMPRESS = new Set([]', self._real_comp, count=1)
        self.assertTrue(any("NEVER_COMPRESS" in p for p in self._probs(src)),
                        self._probs(src))

    def test_never_compress_partial_drain_fires(self):
        # The realistic drift: someone drops ONE name (NotebookEdit) but leaves
        # the rest. The first draft's hardcoded-"Read" literal check passed this
        # because Read stayed — NotebookEdit silently became elidable. Per-tool
        # now (pr-review, 2026-08-03).
        src = self._real_comp.replace(
            '"Read", "Edit", "Write", "NotebookEdit"',
            '"Read", "Edit", "Write" /* dropped NotebookEdit */', 1)
        probs = self._probs(src)
        self.assertTrue(any("NotebookEdit" in p for p in probs), probs)

    def test_never_compress_noop_body_fires(self):
        src = self._real_comp.replace(
            'if (NEVER_COMPRESS.has(tool)) return null;',
            'if (NEVER_COMPRESS.has(tool)) { /* no-op */ }', 1)
        self.assertTrue(any("return null" in p for p in self._probs(src)), self._probs(src))

    def test_agent_set_emptied_fires(self):
        src = re.sub(r'LOSSLESS_ONLY\s*=\s*new Set\(\s*\[[^\]]*\]',
                     'const LOSSLESS_ONLY = new Set([]', self._real_comp, count=1)
        self.assertTrue(any("Agent" in p for p in self._probs(src)),
                        self._probs(src))

    def test_carveout_applications_deleted_fires(self):
        # Delete both .some() lines by line (a two-line literal replace, not a
        # greedy .* to EOF that truncates the file — the first draft's regex
        # deleted 3.6KB and produced a non-parsing mutant).
        src = self._real_comp.replace(
            '    if (LEDGER_PATHS.some((p) => cmd.includes(p))) return null;\n'
            '    if (GATE_CLIS.some((c) => cmd.includes(c))) return null;\n', '', 1)
        probs = self._probs(src)
        self.assertTrue(any("return null" in p for p in probs), probs)

    def test_carveout_noop_body_fires(self):
        src = self._real_comp.replace(
            'if (LEDGER_PATHS.some((p) => cmd.includes(p))) return null;',
            'if (LEDGER_PATHS.some((p) => cmd.includes(p))) { /* no-op */ }', 1)
        self.assertTrue(any("return null" in p for p in self._probs(src)), self._probs(src))

    def test_ledger_path_dropped_from_literal_fires(self):
        # Dropping a path from the array (not the .some call) — the first draft
        # only checked `.some(` existed, so a dropped path passed.
        src = self._real_comp.replace('  ".operator/DECISIONS.md",\n', '', 1)
        self.assertTrue(any("DECISIONS" in p for p in self._probs(src)), self._probs(src))

    def test_never_compress_read_dropped_fires(self):
        # Drop Read ITSELF — the tool the first draft hardcoded. If the per-tool
        # loop ever regresses to a hardcoded name, this is the drop that stays
        # green longest, so it is the strongest regression pin for F48.
        src = self._real_comp.replace(
            '"Read", "Edit", "Write", "NotebookEdit"',
            '"Edit", "Write", "NotebookEdit"', 1)
        probs = self._probs(src)
        self.assertTrue(any('`Read`' in p for p in probs), probs)

    def test_gate_cli_dropped_from_literal_fires(self):
        # Same partial-drain class as NEVER_COMPRESS, on the GATE_CLIS side:
        # drop one CLI, leave the other two and the .some() call intact
        # (pr-review, 2026-08-03 — the literal had no per-entry drop test).
        src = self._real_comp.replace(', "ops-adopt.sh"', '', 1)
        probs = self._probs(src)
        self.assertTrue(any("ops-adopt.sh" in p for p in probs), probs)

    def test_lossless_only_callsite_neutered_fires(self):
        # The literal test (agent_set_emptied) has a call-site counterpart
        # everywhere else; this is LOSSLESS_ONLY's. Remove the .has(tool) use
        # while "Agent" stays in the set (pr-review, 2026-08-03).
        src = self._real_comp.replace(
            'LOSSLESS_ONLY.has(tool)', 'false /* neutered */', 1)
        probs = self._probs(src)
        self.assertTrue(any("LOSSLESS_ONLY" in p for p in probs), probs)

    def test_callsite_in_block_comment_fires(self):
        # The F48 class through the OTHER comment syntax: the first strip was
        # `//`-only, so a call site moved into /* */ still matched every guard
        # regex (pr-review, 2026-08-03). Comment out the real call site.
        src = self._real_comp.replace(
            'if (NEVER_COMPRESS.has(tool)) return null;',
            '/* if (NEVER_COMPRESS.has(tool)) return null; */', 1)
        probs = self._probs(src)
        self.assertTrue(any("return null" in p for p in probs), probs)

    def test_callsite_in_trailing_line_comment_fires(self):
        # F48 class through a TRAILING // comment: delete the real call site and
        # relocate its text into a trailing comment on a dead line, so the guard
        # is gone but the pattern survives (full-PR panel, finding 5b). Caught
        # only if the strip removes trailing comments, not just whole-line ones.
        src = self._real_comp.replace(
            'if (NEVER_COMPRESS.has(tool)) return null;',
            'const _x = 1; // NEVER_COMPRESS.has(tool)) return null;', 1)
        probs = self._probs(src)
        self.assertTrue(any("return null" in p for p in probs), probs)

    def test_never_compress_tool_in_elidable_fires(self):
        # ELIDABLE is the allowlist that decides what gets elided; the first
        # draft never checked it, so a never-compress tool could be added to it
        # (full-PR panel, finding 5a). The invariant is disjointness.
        src = self._real_comp.replace(
            '"Bash", "WebFetch", "WebSearch", "Grep", "Glob"',
            '"Bash", "WebFetch", "WebSearch", "Grep", "Glob", "Read"', 1)
        probs = self._probs(src)
        self.assertTrue(any("ELIDABLE" in p for p in probs), probs)

    def test_salvage_tap_alternative_dropped_fires(self):
        src = re.sub(r'\|not ok', '', self._real_comp, count=1)
        self.assertTrue(any("SALVAGE_RE omits" in p for p in self._probs(src)),
                        self._probs(src))


class ClaimsGuardTest(unittest.TestCase):
    """check_claims must catch DRIFT, not just confirm presence. F30's lesson:
    four-way copy parity is insufficient (uniform drift reads as "in parity").
    So the protected-set literal is pinned to a canonical value AND its
    application (matches_protected on $p) is required. Each test mutates the
    real ops-claims.sh and asserts check_claims fires.
    """

    def setUp(self):
        self.dir = pathlib.Path(tempfile.mkdtemp())
        make_good_tree(self.dir)
        self._real = (pathlib.Path(__file__).resolve().parent.parent /
                      "scripts" / "ops-claims.sh").read_text(encoding="utf-8")

    def tearDown(self):
        shutil.rmtree(self.dir, ignore_errors=True)

    def _probs(self, mutated_src):
        write(self.dir / "scripts" / "ops-claims.sh", mutated_src)
        probs = []
        vp.check_claims(self.dir, probs)
        return probs

    def test_good_claims_is_clean(self):
        self.assertEqual(self._probs(self._real), [])

    def test_protected_path_dropped_fires(self):
        # Drop scripts/statusline.sh from the literal — the F66 amendment. A
        # checker matching only the whole literal would not name it; the token
        # check does (drop it and the parser-weakening path re-opens).
        src = self._real.replace(" scripts/statusline.sh", "", 1)
        probs = self._probs(src)
        self.assertTrue(any("statusline.sh" in p for p in probs), probs)

    def test_protected_literal_drift_fires(self):
        # Replace the whole literal with a different set — two ideas of "the grader".
        src = re.sub(r'^PROTECTED=".*"$',
                     'PROTECTED="only/one/path"', self._real, count=1, flags=re.MULTILINE)
        self.assertTrue(any("drifted" in p for p in self._probs(src)),
                        self._probs(src))

    def test_literal_missing_fires(self):
        src = re.sub(r'^PROTECTED=".*"$\n', '', self._real, count=1,
                     flags=re.MULTILINE)
        self.assertTrue(any("PROTECTED literal not found" in p
                            for p in self._probs(src)), self._probs(src))

    def test_callsite_neutered_fires(self):
        # The literal is declared but matches_protected is not applied to $p
        # (the F30 call-site half: a declaration alone guards nothing). Replace
        # the call site with `false` so no code line carries both the matcher
        # name and $p — a declaration alone guards nothing.
        src = self._real.replace('if matches_protected "$p"; then',
                                 'if false; then', 1)
        self.assertTrue(any("not applied" in p for p in self._probs(src)),
                        self._probs(src))

    def test_callsite_renamed_fires(self):
        # Rename the matcher: the literal stays, but nothing calls it — same
        # class as commenting it out. A check that only grepped the matcher's
        # definition would pass.
        src = self._real.replace("matches_protected", "matches_safe", 10)
        self.assertTrue(any("not applied" in p for p in self._probs(src)),
                        self._probs(src))


class InstallSetParityTest(unittest.TestCase):
    """check_install_set_parity after #76 step 3: the install set has ONE
    declaration (scripts/ops-install-set.sh) and both writers must source it
    and iterate $_OPS_TOOLS. The old two-literal parity comparison died with
    the second literal; what must fire now is any shape that lets the drift
    come back — a writer with its own list, a writer not sourcing the
    manifest, a manifest the regex cannot read. Tests run against the REAL
    writers so a shipped regression cannot hide behind a conforming stub.
    """

    def setUp(self):
        self.dir = pathlib.Path(tempfile.mkdtemp())
        make_good_tree(self.dir)
        root = pathlib.Path(__file__).resolve().parent.parent
        self._real_init = (root / "scripts" / "ops-init.sh").read_text(encoding="utf-8")
        self._real_ssh = (root / "scripts" / "ops-sessionstart-hook.sh").read_text(encoding="utf-8")
        self._real_manifest = (root / "scripts" / "ops-install-set.sh").read_text(encoding="utf-8")
        write(self.dir / "scripts" / "ops-init.sh", self._real_init)
        write(self.dir / "scripts" / "ops-sessionstart-hook.sh", self._real_ssh)
        write(self.dir / "scripts" / "ops-install-set.sh", self._real_manifest)

    def tearDown(self):
        shutil.rmtree(self.dir, ignore_errors=True)

    def _probs(self):
        probs = []
        vp.check_install_set_parity(self.dir, probs)
        return probs

    def test_real_writers_and_manifest_are_clean(self):
        self.assertEqual(self._probs(), [])

    def test_missing_manifest_fires(self):
        (self.dir / "scripts" / "ops-install-set.sh").unlink()
        self.assertTrue(any("ops-install-set.sh: missing" in p for p in self._probs()),
                        self._probs())

    def test_unreadable_manifest_assignment_fires(self):
        # A reshape the regex cannot read (array form) must be REPORTED, not
        # silently accepted — the fail-open the pre-#34 version had.
        write(self.dir / "scripts" / "ops-install-set.sh",
              '_OPS_TOOLS=(ops-verdict.sh ops-task.sh)\n')
        self.assertTrue(any("no plain `_OPS_TOOLS" in p for p in self._probs()),
                        self._probs())

    def test_manifest_without_verdict_fires(self):
        # An install set omitting the ledger's single writer is corruption.
        write(self.dir / "scripts" / "ops-install-set.sh",
              '_OPS_TOOLS="ops-task.sh ops-adopt.sh"\n')
        self.assertTrue(any("omits" in p and "ops-verdict.sh" in p
                            for p in self._probs()), self._probs())

    def test_writer_regrowing_inline_literal_fires(self):
        # The drift coming back: a writer declares its own _OPS_TOOLS beside
        # the source line. The check reads code, so the manifest still parses,
        # but the writer's local copy shadows it — two lists again (CR4).
        src = self._real_init.replace(
            '. "$SCRIPT_DIR/ops-install-set.sh"',
            '. "$SCRIPT_DIR/ops-install-set.sh"\n'
            '_OPS_TOOLS="ops-verdict.sh ops-task.sh"', 1)
        self.assertNotEqual(src, self._real_init)  # the mutation landed
        write(self.dir / "scripts" / "ops-init.sh", src)
        self.assertTrue(any("declares its own _OPS_TOOLS literal" in p
                            for p in self._probs()), self._probs())

    def test_writer_not_sourcing_manifest_fires(self):
        src = self._real_init.replace('. "$SCRIPT_DIR/ops-install-set.sh"',
                                      ': no-source-here', 1)
        self.assertNotEqual(src, self._real_init)
        write(self.dir / "scripts" / "ops-init.sh", src)
        self.assertTrue(any("does not source ops-install-set.sh" in p
                            for p in self._probs()), self._probs())

    def test_writer_looping_inline_list_fires(self):
        # Sourcing the manifest but looping a hand-written list: the declared
        # set and the installed set are two different lists (F30).
        src = self._real_init.replace("for tool in $_OPS_TOOLS",
                                      "for tool in ops-verdict.sh ops-task.sh", 1)
        self.assertNotEqual(src, self._real_init)
        write(self.dir / "scripts" / "ops-init.sh", src)
        self.assertTrue(any("does not iterate $_OPS_TOOLS" in p
                            for p in self._probs()), self._probs())


class GitignoreParityTest(unittest.TestCase):
    """check_gitignore_parity: the v2 allowlist body is written by ops-init.sh
    AND ops-sessionstart-hook.sh. Drift means a project's tracked set depends on
    which path migrated it — and the silent direction is an allow line present in
    one and missing in the other, which un-tracks a ledger. Mutates the REAL
    scripts (not a stub) so the test cannot pass a body the shipped code lacks.
    """

    def setUp(self):
        self.dir = pathlib.Path(tempfile.mkdtemp())
        make_good_tree(self.dir)
        root = pathlib.Path(__file__).resolve().parent.parent
        self._real_init = (root / "scripts" / "ops-init.sh").read_text(encoding="utf-8")
        self._real_ssh = (root / "scripts" / "ops-sessionstart-hook.sh").read_text(encoding="utf-8")
        write(self.dir / "scripts" / "ops-init.sh", self._real_init)
        write(self.dir / "scripts" / "ops-sessionstart-hook.sh", self._real_ssh)

    def tearDown(self):
        shutil.rmtree(self.dir, ignore_errors=True)

    def _probs(self):
        probs = []
        vp.check_gitignore_parity(self.dir, probs)
        return probs

    def test_shipped_scripts_are_in_parity(self):
        self.assertEqual(self._probs(), [])

    def test_dropping_an_allow_line_from_one_writer_fires(self):
        # The realistic silent failure: one writer stops admitting a ledger.
        write(self.dir / "scripts" / "ops-sessionstart-hook.sh",
              self._real_ssh.replace("!DECISIONS.md\n", "", 1))
        probs = self._probs()
        self.assertTrue(any("missing allow line" in p for p in probs), probs)
        self.assertTrue(any("drift" in p for p in probs), probs)

    def test_dropping_the_bare_star_fires(self):
        # The `*` is what makes this an ALLOWLIST. Drop it and the file inverts
        # to a v1 blocklist: bin/, pending/, .lock/ and every compressor spill
        # ship TRACKED, which is the failure v2 exists to end. This went
        # unpinned while the docstring called `*` "the load-bearing half" —
        # dropping it left the build green (Copilot review, PR #12). Both
        # writers are mutated independently: a check that only covers one is
        # the same half-applied guard it is meant to catch.
        for name, real in (("ops-init.sh", self._real_init),
                           ("ops-sessionstart-hook.sh", self._real_ssh)):
            with self.subTest(writer=name):
                write(self.dir / "scripts" / name,
                      real.replace(
                          "# is genuinely evidence a teammate must read.\n*\n!.gitignore",
                          "# is genuinely evidence a teammate must read.\n!.gitignore",
                          1))
                probs = self._probs()
                self.assertTrue(any("no bare `*` line" in p for p in probs), probs)
                write(self.dir / "scripts" / name, real)   # restore for the next subTest
        self.assertEqual(self._probs(), [])

    def test_losing_the_v2_marker_fires(self):
        # Without the marker neither writer can DETECT a v1 file, so a blocklist
        # is appended to instead of replaced — and the two schemes contradict.
        write(self.dir / "scripts" / "ops-init.sh",
              self._real_init.replace("# cc-operator gitignore v2 (allowlist)", "# v2", 1))
        self.assertTrue(any("v2 gitignore marker" in p for p in self._probs()),
                        self._probs())

    def test_losing_only_the_DETECTION_grep_fires(self):
        # EMIT and DETECT are two claims. The heredoc body contains the marker,
        # so a substring test passes even with the migration `grep` deleted —
        # and then every existing v1 project silently stops being detected
        # (Copilot review of PR #12; measured green in both writers before this).
        # One mutation per writer: covering only one leaves the other on the
        # same half-applied guard this check exists to catch.
        for name, real, detect, replacement in (
                ("ops-init.sh", self._real_init,
                 'elif ! grep -qF "$_GI_MARK" "$OPDIR/.gitignore" 2>/dev/null; then',
                 'elif false; then'),
                ("ops-sessionstart-hook.sh", self._real_ssh,
                 "! grep -qF '# cc-operator gitignore v2 (allowlist)' \"$_gi\" 2>/dev/null",
                 "false")):
            with self.subTest(writer=name):
                self.assertIn(detect, real, f"{name}: detection anchor moved")
                write(self.dir / "scripts" / name, real.replace(detect, replacement, 1))
                probs = self._probs()
                self.assertTrue(any("never greps for it" in p for p in probs), probs)
                write(self.dir / "scripts" / name, real)
        self.assertEqual(self._probs(), [])

    def test_migration_without_a_tested_backup_fires(self):
        # The write must be reachable ONLY through a successful backup. The
        # shipped shape was `cp … 2>/dev/null` then an unconditional overwrite,
        # so a failed backup destroyed the user's rules while the notice claimed
        # they were recoverable (measured in BOTH writers, 2026-08-12).
        shipped_init = (
            '  cp "$OPDIR/.gitignore" "$OPDIR/.gitignore.v1.bak" 2>/dev/null\n'
            '  _gi_write\n')
        start = self._real_init.index("  # BACKUP FIRST")
        end = self._real_init.index("  fi\nfi\n", start) + len("  fi\nfi\n")
        write(self.dir / "scripts" / "ops-init.sh",
              self._real_init[:start] + shipped_init + "fi\n" + self._real_init[end:])
        probs = self._probs()
        self.assertTrue(any("without testing whether the copy" in p for p in probs), probs)
        self.assertTrue(any("non-regular entry at .gitignore.v1.bak" in p
                            for p in probs), probs)

    def test_fragment_allow_line_is_pinned(self):
        # verdicts.d/*.md is what merge=union operates on: un-tracking it breaks
        # the clean-merge property the whole fragment scheme exists for.
        write(self.dir / "scripts" / "ops-init.sh",
              self._real_init.replace("!verdicts.d/*.md\n", "", 1))
        self.assertTrue(any("verdicts.d/*.md" in str(p) for p in self._probs()),
                        self._probs())


class GuardParityVacuityTest(unittest.TestCase):
    """Every check_guard_parity pin must survive the COMMENT-ONLY mutation.

    The pins search a script for a guard's literal (`*.exempt`, `[[:space:]]`,
    `check_bare_name()`, `.*)`). Searching `read_text()` makes the comment that
    EXPLAINS the guard satisfy the pin, so deleting the guard while leaving its
    comment keeps the validator green — and that is the realistic regression,
    because a careless edit removes the code and keeps the prose.

    Measured 2026-08-14, before `shell_code()` existed: `*.exempt` removed from
    ops-stop-hook.sh's reject-set with its two comment lines intact left the
    validator at "all contracts hold" AND the bash suite at 590/0. Both gates
    blind, on the F1 guard. Two of the seven sites were flagged by the Copilot
    review of PR #56; the other five had the same hole.

    This class exists rather than a pin on `shell_code()`'s existence because a
    helper nobody calls is the same vacuity one level up. Each case mutates a
    REAL script the way a regression would and asserts the check fires. A new
    guard pin added without a case here is not covered — add one.
    """

    # (script, the guard's code line, the comment-safe replacement that removes it)
    CASES = (
        # All three readers now share ONE shape: ownership is the filename, so
        # the reject set guards a name split rather than a body parse. The pin
        # is unchanged in purpose — a planted name must not pose as an owner.
        # (The statusline's own parser copy is gone: it sources the lib, and
        # the lib's parser is the case above. The bar keeps a HANDOFF-MARK
        # tail scanner of its own — pinned by check_decisions_schema's
        # source-pin, not by a reject-set literal.)
        # F15's PREV set — the fifth copy, and the one whose pin was file-wide
        # until this round. ops-adopt.sh carries *.exempt at the WRITER too, so
        # the pin must read this arm specifically or the writer satisfies it.
        # Not an *.exempt case: the whitespace arm the readers' parser needs
        # so an owner that can never equal a real session id cannot make a task
        # permanently non-blocking. Different literal, same vacuity shape.
        ("lib/partition.sh",
         r'''"" | */* | .* | *"|"* | *[[:space:]]*) printf '\n'; return 0 ;;''',
         r'''"" | */* | .* | *"|"*) printf '\n'; return 0 ;;''',
         "[[:space:]]"),
        # The leading-dot rule, one per writer CLI: a dotfile sentinel is
        # invisible to the Stop hook's glob, so the gate never sees the task.
        ("ops-task.sh",
         """.*) die "$1 must not start with '.'""",
         """.__NOPE__) die "$1 must not start with '.'""",
         ".*)"),
    )

    def setUp(self):
        self.dir = pathlib.Path(tempfile.mkdtemp())
        make_good_tree(self.dir)
        self.real = pathlib.Path(__file__).resolve().parent.parent / "scripts"

    def tearDown(self):
        shutil.rmtree(self.dir, ignore_errors=True)

    def _probs(self):
        probs = []
        vp.check_guard_parity(self.dir, probs)
        return probs

    def _install_real(self):
        """Copy the real CLIs in — the pins must hold against shipped code."""
        for n in ("ops-task.sh", "ops-verdict.sh", "ops-adopt.sh",
                  "ops-stop-hook.sh", "statusline.sh", "lib/partition.sh"):
            src = self.real / n
            if src.is_file():
                dest = self.dir / "scripts" / n
                dest.parent.mkdir(parents=True, exist_ok=True)
                write(dest, src.read_text(encoding="utf-8"))

    def test_the_real_tree_is_clean(self):
        self._install_real()
        self.assertEqual(self._probs(), [])

    def _mutate(self, script, guard, without):
        """Delete a guard from the real script; return (leftover_text, problems)."""
        self._install_real()
        p = self.dir / "scripts" / script
        text = p.read_text(encoding="utf-8")
        self.assertIn(guard, text, f"{script}: anchor moved — update CASES")
        mutated = text.replace(guard, without, 1)
        write(p, mutated)
        return mutated, self._probs()

    def test_every_pin_fires_when_its_guard_is_deleted(self):
        """The base question, asked of ALL seven pins: does removing the guard
        from the CODE make check_guard_parity complain? A pin that stays silent
        here pins nothing at all — which is how ops-adopt.sh's PREV set was
        found (its file-wide search was satisfied by the writer-side guard in
        the same file, so gutting the parser left validator AND bash both
        green; measured 2026-08-14, the F1 hole reopened one site over)."""
        for script, guard, without, literal in self.CASES:
            with self.subTest(script=script, literal=literal):
                _, probs = self._mutate(script, guard, without)
                self.assertTrue(
                    any(script in str(x) for x in probs),
                    f"{script}: the {literal} guard was deleted from the CODE "
                    f"and check_guard_parity stayed SILENT — this pin is "
                    f"vacuous. Scope it (see _function_body / the PREV arm) "
                    f"so a sibling copy of the literal cannot satisfy it")

    def test_a_surviving_comment_does_not_satisfy_a_pin(self):
        """The comment-blindness question, asked only where it is ASKABLE: a
        case qualifies when the literal still appears after the mutation, i.e.
        a comment (or another line) still mentions it. Split from the test
        above because conflating the two rejected sound cases — ops-task.sh's
        `.*)` and the stop-hook's `[[:space:]]` each appear exactly ONCE, in
        code, with no comment quoting them, so there is nothing to be blind to
        and the base test is the whole story for them."""
        asked = 0
        for script, guard, without, literal in self.CASES:
            leftover = None
            self._install_real()
            p = self.dir / "scripts" / script
            text = p.read_text(encoding="utf-8")
            if literal not in text.replace(guard, without, 1):
                continue          # nothing survives to be blind to — not askable
            with self.subTest(script=script, literal=literal):
                asked += 1
                leftover, probs = self._mutate(script, guard, without)
                self.assertIn(literal, leftover)
                self.assertTrue(
                    any(script in str(x) and literal in str(x) for x in probs),
                    f"{script}: {literal} survives elsewhere in the file after "
                    f"the guard was deleted, and the pin was satisfied by it — "
                    f"reading raw text, or scoped too widely")
        self.assertGreater(asked, 0,
                           "no case exercised comment/sibling blindness — the "
                           "CASES table lost every literal that appears twice")

    def test_shell_code_ignores_a_comment_only_mention(self):
        # The helper itself, directly: a file whose ONLY mention is a comment
        # must read as absent.
        f = self.dir / "scripts" / "probe.sh"
        write(f, "#!/usr/bin/env bash\n# we reject *.exempt here\necho hi\n")
        self.assertNotIn("*.exempt", vp.shell_code(f))
        write(f, "#!/usr/bin/env bash\ncase $x in *.exempt) :;; esac\n")
        self.assertIn("*.exempt", vp.shell_code(f))

    def test_indented_comment_is_stripped_too(self):
        # Guards live inside functions, so their comments are indented — a
        # stripper anchored at column 0 would still read them as code.
        f = self.dir / "scripts" / "probe.sh"
        write(f, "#!/usr/bin/env bash\nf() {\n    # rejects *.exempt\n    :\n}\n")
        self.assertNotIn("*.exempt", vp.shell_code(f))


class ReleaseGateCoverageTest(unittest.TestCase):
    """check_release_gates_cover_validate: the job that PUBLISHES must gate at
    least as much as the job that does not.

    #38: release.yml ran a strict subset of validate.yml — both node suites
    (148 cases over the workflow layer and the compressor) were absent from
    every tag build, while release.yml's header claimed "full validation".
    """

    VALIDATE = (
        "jobs:\n  validate:\n    steps:\n"
        "      - run: python3 scripts/validate_plugin.py\n"
        "      - run: python3 -m unittest discover -s tests\n"
        "      - run: bash tests/test-scripts.sh\n"
        "      - run: node tests/test_workflows.mjs\n"
        "      - run: node tests/test_compress.mjs\n"
    )
    RELEASE_FULL = (
        "jobs:\n  release:\n    steps:\n"
        "      - run: python3 scripts/validate_plugin.py\n"
        "      - run: python3 -m unittest discover -s tests\n"
        "      - run: bash tests/test-scripts.sh\n"
        "      - run: node tests/test_workflows.mjs\n"
        "      - run: node tests/test_compress.mjs\n"
    )

    def setUp(self):
        self.dir = pathlib.Path(tempfile.mkdtemp())
        (self.dir / ".github" / "workflows").mkdir(parents=True)

    def tearDown(self):
        shutil.rmtree(self.dir, ignore_errors=True)

    def _write(self, validate=None, release=None):
        wf = self.dir / ".github" / "workflows"
        if validate is not None:
            write(wf / "validate.yml", validate)
        if release is not None:
            write(wf / "release.yml", release)

    def _probs(self):
        probs = []
        vp.check_release_gates_cover_validate(self.dir, probs)
        return probs

    def test_superset_passes(self):
        self._write(self.VALIDATE, self.RELEASE_FULL)
        self.assertEqual(self._probs(), [])

    def test_missing_node_suites_fire(self):
        # The exact #38 shape: release.yml drops both node steps.
        subset = self.RELEASE_FULL.replace(
            "      - run: node tests/test_workflows.mjs\n", "").replace(
            "      - run: node tests/test_compress.mjs\n", "")
        self._write(self.VALIDATE, subset)
        probs = self._probs()
        self.assertEqual(len(probs), 2, probs)
        self.assertTrue(all("gates less" in p for p in probs), probs)

    def test_extra_release_step_is_fine(self):
        # release.yml legitimately runs MORE (release_gate.py, gh release
        # create). Only the missing direction is a finding.
        self._write(self.VALIDATE,
                    self.RELEASE_FULL + "      - run: python3 scripts/release_gate.py v1\n")
        self.assertEqual(self._probs(), [])

    def test_no_workflows_at_all_is_skipped(self):
        # A plugin tree without CI is not a half-configured one. This is the
        # only legitimate skip, and it is what the validator's own fixtures
        # build — a check that fired here would fail every good-tree test.
        self.assertEqual(self._probs(), [])

    def test_one_workflow_missing_is_reported(self):
        # Half-configured CI: reported, not skipped. Silence here is how a
        # publishing job with no counterpart to compare against goes unnoticed.
        self._write(validate=self.VALIDATE)
        probs = self._probs()
        self.assertTrue(any("release.yml is missing" in p for p in probs), probs)

    def test_real_workflows_are_covered(self):
        probs = []
        vp.check_release_gates_cover_validate(ROOT, probs)
        self.assertEqual(probs, [])



