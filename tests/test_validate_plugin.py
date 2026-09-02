"""Each validate_plugin check must FIRE on a broken fixture and PASS on a good
tree. We build a minimal valid repo in a tmpdir, assert it is clean, then break
one contract at a time and assert the specific failure surfaces.
"""
import json
import pathlib
import re
import shutil
import sys
import tempfile
import textwrap
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
import validate_plugin as vp  # noqa: E402


# The charter bounds per-line length (F19); the fixture matches it.
_CLI_SENTENCE = " — run [DOC:spec-D4]:\n" + "\n".join(
    f"`.operator/bin/{c}`" for c in vp.CHARTER_REQUIRED_CLIS)

# The dispatch packet (#57, check_handout_packet); written out rather than derived
# from vp.HANDOUT_PACKET_SPINE so this fixture stays clean-by-construction only.
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


# Stub scripts that SATISFY every guardrail check in vp.CHECKS, not just the
# manifest-shaped ones. 0.10: hook + bar share one partition-lib implementation;
# the gate CLIs keep their own copies, pinned by check_guard_parity.
GOOD_PARTITION_LIB = (
    "#!/usr/bin/env bash\n"
    # LC_ALL=C in scope: `read -n N` counts CHARACTERS outside it, so the
    # byte caps below are up to 4x looser than they read (Copilot, PR #87).
    "_r() { local LC_ALL=C; :; }\n"
    "sentinel_owner_of_name() {\n"
    "  case \"$_o\" in \"\" | */* | .* | *\"|\"* | *[[:space:]]*) printf '\\n'; return 0 ;;\n"
    "    *'$'* | *'`'* | *\"'\"* | *'\"'* | *\\\\*) printf '\\n'; return 0 ;; esac\n"
    "}\n"
    # The deviation gate's kind scan, in CODE: check_decisions_schema reads the
    # comment-stripped view since audit F127, so a comment naming the enum no
    # longer satisfies it.
    "case \"$dkind\" in DEVIATION|ESCALATION|GATE-EXCEPTION) :;; HANDOFF-MARK) :;; esac\n"
    "while IFS= read -r -n 512 dline; do :; done < \"$decisions\"\n"
    "[ ! -L \"$decisions\" ] || exit 0\n")
# #85: the auto-arm rule. Every literal here is one check_autobar pins, and each pin
# exists because its regression is silent — see scripts/lib/autobar.sh.
GOOD_AUTOBAR_LIB = (
    "#!/usr/bin/env bash\n"
    "autobar_count_changed() {\n"
    "  git -C \"$root\" rev-parse --git-dir >/dev/null 2>&1 || return 0\n"
    "  while IFS= read -r -d '' rec; do n=$((n+1)); done "
    "< <(git -C \"$root\" status --porcelain -z -uall -- ':(exclude).operator' 2>/dev/null)\n"
    "}\n"
    "autobar_already_armed() { [ -f \"$opdir/.autobar/$sess\" ]; }\n"
    "autobar_mark_armed() { : > \"$opdir/.autobar/$sess\"; }\n"
    "autobar_decide() {\n"
    "  autobar_already_armed \"$2\" \"$3\" && return 0\n"
    "  autobar_count_changed \"$1\"\n"
    "}\n")
GOOD_STATUSLINE = (
    "#!/usr/bin/env bash\n"
    "_r() { local LC_ALL=C; :; }\n"
    '. lib/partition.sh\n'
    "[ ! -L \"$decisions\" ] || exit 0\n"
    "while IFS= read -r -n 512 dline; do :; done < \"$decisions\"\n"
    "while IFS= read -r -n 512 dline; do :; done < \"$decisions\"\n"
    "while IFS= read -r -n 512 dline; do :; done < \"$decisions\"\n")

# A json_get() with the bool coercion the three hooks must agree on (F14 pin).
# JSON null maps to "" here, matching the real hooks.
JSON_GET = (
    "# json_get python3 branch carries the bool coercion (F14 parity pin)\n"
    "json_get() { printf '%s' \"$input\" | python3 -c 'import sys,json; "
    "v=json.load(sys.stdin).get(sys.argv[1],\"\"); "
    "print(\"true\" if isinstance(v, bool) and v else \"false\" if isinstance(v, bool) "
    "else \"\" if v is None else v)' \"$1\"; }\n")

# Carries every CANONICAL_LOCK property, because parity alone is F30's shape:
# two copies that drift TOGETHER are trivially in parity, and inflating the
# holder read to 999999999 in BOTH passed (audited 2026-08-25).
GOOD_LOCK_BLOCK = (
    "# >>> LOCK BLOCK\n"
    "lock_holder_live() {\n"
    "  { IFS= read -r -n 128 LOCK_HOLDER_REC < \"$LOCKDIR/holder\"; } 2>/dev/null || true\n"
    "  IFS= read -r -n 128 FALLBACK_REC < \"$FALLBACK_DIR/holder\" 2>/dev/null || true\n"
    "  kill -0 \"$pid\" 2>/dev/null && return 0\n"
    "}\n"
    "lock_acquire() {\n"
    "  while ! mkdir \"$LOCKDIR\" 2>/dev/null; do\n"
    "    if mkdir \"$LOCKDIR.reclaim\" 2>/dev/null; then rmdir \"$LOCKDIR.reclaim\"; fi\n"
    "  done\n"
    "}\n"
    "lock_release() { rm -f \"$LOCKDIR/holder\"; rmdir \"$LOCKDIR\"; }\n"
    "# <<< LOCK BLOCK\n")

# The #95 project-root walk (check_root_parity): byte-identical across the
# three gate CLIs, and it must CD rather than merely compute an absolute OPDIR.
GOOD_ROOT_BLOCK = (
    "# >>> PROJECT ROOT BLOCK\n"
    "_ops_cd_project_root() {\n"
    "  _walk=\"$(pwd -P 2>/dev/null)\" || _walk=\"\"\n"
    "  while [ -n \"$_walk\" ]; do\n"
    "    if [ -d \"$_walk/.operator\" ]; then\n"
    "      cd \"$_walk\" 2>/dev/null || die \"could not cd\"\n"
    "      return 0\n"
    "    fi\n"
    "    [ -e \"$_walk/.git\" ] && break\n"
    "    [ \"$_walk\" = \"/\" ] && break\n"
    "    _walk=\"${_walk%/*}\"; [ -n \"$_walk\" ] || _walk=\"/\"\n"
    "  done\n"
    "  return 1\n"
    "}\n"
    "_ops_cd_project_root || :\n"
    "# <<< PROJECT ROOT BLOCK\n")

# The U10 source-state stamp (check_source_stamp): resolver, markers, the
# `.operator` dirty-exclusion, the 4-cell row, and stamp-before-lock_acquire.
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


# audit F136: the task-half filter every `*__<id>` lookup carries; used by the
# good tree AND the private reader stubs below (check_guard_parity pins it).
def f136_lookup(fn):
    return (fn + "() {\n  local _t=\"$1\" _f _n\n"
            "  for _f in \"$OPDIR/pending/$_t\" \"$OPDIR/pending\"/*__\"$_t\"; do\n"
            "    _n=\"${_f##*/}\"; [ \"${_n#*__}\" = \"$_t\" ] || continue\n"
            "    [ -e \"$_f\" ] && { printf '%s\\n' \"$_f\"; break; }\n"
            "  done\n}\n")


F136_DUPLOOP = ("for _dup in \"$OPDIR/pending\"/*__\"$ID\"; do\n"
                "  _dn=\"${_dup##*/}\"; [ \"${_dn#*__}\" = \"$ID\" ] || continue\n"
                "done\n")


def make_good_tree(root):
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
    # Every [DOC:spec-<key>] in the charter needs a `### spec-<key>` entry in
    # the tag index (#76 step E) — the fixture cites spec-D4.
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
        }
    }))
    write(root / ".claude-plugin" / "statusline.json", json.dumps({
        "name": "cc-operator", "render": "scripts/statusline.sh", "order": 30,
    }))
    # Both .operator/.gitignore writers must carry the v2 allowlist body,
    # byte-equal (check_gitignore_parity).
    gitignore_v2 = ("# cc-operator gitignore v2 (allowlist)\n"
                    "*\n"
                    "!.gitignore\n!.gitattributes\n"
                    "!VERDICTS.md\n!DECISIONS.md\n!tiers.env\n"
                    "!verdicts.d/\n!verdicts.d/*.md\n"
                    # Evidence, not machine state (#30).
                    "!handoff-*.md\n")
    # Both writers must detect a v1 file, emit the v2 body, and refuse to
    # overwrite without a verified backup. The install set lives in one
    # manifest (#76 step 3); check_install_set_parity pins both writers
    # sourcing it and iterating $_OPS_TOOLS.
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
          # ATOMIC: temp + same-dir mv (audit F137 pins init's swap like the hook's)
          "cat > \"$OPDIR/.gitignore.v2.tmp\" <<'EOF'\n" + gitignore_v2 + "EOF\n"
          "mv -f \"$OPDIR/.gitignore.v2.tmp\" \"$OPDIR/.gitignore\"\n"
          "  fi\nfi\n"
          "echo ok\n")
    # SessionStart clears the compressor's session-scoped artifacts and migrates
    # a v1 gitignore behind the same verified backup.
    write(root / "scripts" / "ops-sessionstart-hook.sh",
          "#!/usr/bin/env bash\nset -eu\n" + _install_loop + JSON_GET +
          # The shipped WIPE-LOOP form, not a flat rm: check_compressor reads
          # the `for _cdir in …; do` word list, because emptying that list and
          # leaving the names in a trailing comment satisfied the old raw-text
          # test while nothing was cleared (audited 2026-08-25).
          "for _cdir in \"$cwd/.operator/.compress-spill\" \"$cwd/.operator/.compress-state\"; do\n"
          "  [ -d \"$_cdir\" ] && rm -rf \"$_cdir\" 2>/dev/null\n"
          "done\n"
          "rm -rf \"$cwd/.operator/.autobar\"\n"
          # the legacy-sentinel migration's reject-set: the #89 metacharacter
          # arm is pinned at the MIGRATION site too (audit F128, Copilot
          # review on PR #97 — a body reading `session_id: $S` migrated to a
          # name both parsers read as a valid foreign owner).
          "for _s in \"$cwd/.operator/pending\"/*; do\n"
          "  case \"$_sid\" in\n"
          "    *'$'* | *'`'* | *\"'\"* | *'\"'* | *\\\\*) continue ;;\n"
          "  esac\n"
          "done\n"
          "if ! grep -qF '# cc-operator gitignore v2 (allowlist)' \"$_gi\" 2>/dev/null; then\n"
          "  if [ -e \"$_gi.v1.bak\" ] && [ ! -f \"$_gi.v1.bak\" ]; then\n"
          "    _gi_backup_failed=1\n"
          "  elif ! cp \"$_gi\" \"$_gi.v1.bak\" 2>/dev/null; then\n"
          "    _gi_backup_failed=1\n"
          # ATOMIC, like the real hook: heredoc into the temp, marker-confirmed,
          # then a same-dir `mv -f`. The stub used to write straight onto `$_gi`
          # and the validator excused it, because the CONFIRMATION pin was gated
          # on `".v2.tmp" in text` — the exact vacuity PR #104's review found.
          # With the atomic pin unconditional, a good tree must BE atomic.
          "  elif cat > \"$_gi.v2.tmp\" 2>/dev/null <<'EOF'\n" + gitignore_v2 + "EOF\n"
          # The THIRD state: backup written, overwrite failed. Two flags cannot
          # express three outcomes, and the missing one reported nothing at all.
          "  then\n"
          "    if grep -qF '# cc-operator gitignore v2 (allowlist)' \"$_gi.v2.tmp\" 2>/dev/null \\\n"
          "       && mv -f \"$_gi.v2.tmp\" \"$_gi\" 2>/dev/null; then\n"
          "      _gi_migrated=1\n"
          "    else\n"
          "      rm -f \"$_gi.v2.tmp\" 2>/dev/null\n"
          "      _gi_write_failed=1\n"
          "    fi\n"
          "  else\n"
          "    _gi_write_failed=1\n"
          "  fi\nfi\n"
          "if [ \"$_gi_write_failed\" = 1 ]; then echo FAILED PARTWAY; fi\n"
          "echo ok\n")
    # Reader/CLI bodies must satisfy the byte-bound, guard-parity and
    # lock-parity checks.
    guards = ("check_bare_name() { case \"$2\" in .*) die x ;; *__*) die x ;; esac; }\n"
              "check_owner_name() { case \"$1\" in *[[:space:]]*) die x ;; *'$'* | *'`'* | *\"'\"* | *'\"'* | *\\\\*) die x ;; esac; }\n")
    bounded = "while IFS= read -r -n 512 line; do :; done < \"$1\"\n"
    # every sentinel touchpoint carries the -L symlink rejection (F65/F66)
    nolink = "[ ! -L \"$1\" ] || exit 0\n"
    # audit F136: every `*__<id>` lookup filters on the TASK HALF of the match
    # (check_guard_parity pins the literal per site).
    lookup, duploop = f136_lookup, F136_DUPLOOP
    # autobar.sh sourced AFTER partition.sh: it calls sentinel_owner_of_name.
    write(root / "scripts" / "ops-stop-hook.sh",
          "#!/usr/bin/env bash\n. lib/partition.sh\n. lib/autobar.sh\n" + JSON_GET)
    write(root / "scripts" / "ops-task.sh",
          "#!/usr/bin/env bash\n" + guards + nolink + lookup("sentinel_for") + duploop
          + GOOD_ROOT_BLOCK)
    write(root / "scripts" / "ops-verdict.sh",
          "#!/usr/bin/env bash\n" + "_r() { local LC_ALL=C; :; }\n" + guards + nolink +
          lookup("sentinel_path") +
          "sentinel_owner_of_name() {\n"
          "  case \"$_o\" in \"\" | */* | .* | *\"|\"* | *[[:space:]]*) printf '\\n'; return 0 ;;\n"
    "    *'$'* | *'`'* | *\"'\"* | *'\"'* | *\\\\*) printf '\\n'; return 0 ;; esac\n"
          "}\n" +
          "# F2: refuse a symlink fragment before the write + skip on both reads\n"
          '[ -L "$FRAGDIR/$who.md" ] && exit 1\n'
          '[ -f "$frag" ] && [ ! -L "$frag" ] && :;\n'
          '[ -f "$frag" ] && [ ! -L "$frag" ] && :;\n'
          "# F17: both verdicts.d fragment scanners use the same 1MiB read bound\n"
          "while IFS= read -r -n 1048576 row; do :; done < \"$frag\"\n"
          "while IFS= read -r -n 1048576 line; do :; done < \"$frag\"\n" +
          # --mark-handoff EMITS the marker (audit F127: the pin reads a
          # printf line in code, not a mention in a comment).
          "printf '%s | HANDOFF-MARK | [sid:%s]\\n' \"$d\" \"$MOWNER\" >> \"$DEC\"\n" +
          GOOD_LOCK_BLOCK + GOOD_SOURCE_STAMP + GOOD_ROOT_BLOCK)
    write(root / "scripts" / "ops-adopt.sh",
          "#!/usr/bin/env bash\n" + guards + nolink + lookup("sentinel_path") +
          "# PREV reject-set (F15): carries *.exempt like the sentinel_owner parsers\n"
          'case "${PREV:-}" in */* | .* | *"|"* | *[[:space:]]* | *[[:cntrl:]]* | *.exempt) PREV="<invalid>" ;; esac\n'
          + GOOD_LOCK_BLOCK + GOOD_ROOT_BLOCK)
    # ops-claims.sh: check_claims pins its PROTECTED literal and requires
    # matches_protected applied to $p.
    write(root / "scripts" / "ops-claims.sh",
          "#!/usr/bin/env bash\n"
          'PROTECTED="scripts/validate_plugin.py tests/ .operator/bin/ hooks/ '
          'scripts/ops-*.sh scripts/statusline.sh backlog/"\n'
          # A compliant matcher body: audit F129 pins the `*/)` prefix branch
          # and the `[[ $p == $pat ]]` glob application, not just the call site.
          # …and audit F140 EXECUTES it: the stub takes its path as $1 like the
          # real matcher (the old stub read the caller's loop variable).
          "matches_protected() {\n"
          '  local p="$1" pat\n'
          "  set -f\n"
          "  for pat in $PROTECTED; do\n"
          '    case "$pat" in\n'
          '      */) [ "${p#"$pat"}" != "$p" ] && return 0 ;;\n'
          "      *)  [[ $p == $pat ]] && return 0 ;;\n"
          "    esac\n"
          "  done\n"
          "  set +f\n"
          "  return 1\n"
          "}\n"
          'for p in $ACTUAL; do matches_protected "$p"; done\n')
    # ops-backlog.sh: in check_scripts (bash -n) but not a gate CLI.
    write(root / "scripts" / "ops-backlog.sh",
          "#!/usr/bin/env bash\n"
          'if [ "${1:-}" = "--census" ]; then echo "files: 0"; exit 0; fi\n')
    (root / "scripts" / "lib").mkdir(exist_ok=True)
    write(root / "scripts" / "lib" / "partition.sh", GOOD_PARTITION_LIB)
    write(root / "scripts" / "lib" / "autobar.sh", GOOD_AUTOBAR_LIB)
    write(root / "scripts" / "statusline.sh", GOOD_STATUSLINE)
    # Every shipped slash command: frontmatter plus plugin-root script paths
    # (a bare scripts/ path resolves only inside this repo).
    for name in ("start", "handoff"):
        write(root / "commands" / f"{name}.md", textwrap.dedent(f"""\
            ---
            description: d
            argument-hint: []
            allowed-tools: Bash(bash:*), Read, Write, Edit
            ---
            Run `bash "${{CLAUDE_PLUGIN_ROOT}}/scripts/ops-init.sh"`.
            """))
    # Two workflow fixtures carrying the shared tier-guard invariants identically
    # (BAD_CHARSET byte-equal, DEFAULT_TIERS aliases) so check_workflows,
    # check_workflow_parity, and check_workflow_default_tiers pass.
    # Both stubs carry check_routable and TIER_NAMES since resolver and renderer
    # parse the same tiers.env (check_resolver_renderer_parity).
    # The stub tracks the LENS_NAMESPACES guard's structure since #35.
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
          '_r() { local LC_ALL=C; :; }\n'
          'while IFS= read -r -n 512 line; do :; done < "$1"\n')
    # ops-render.sh: a bounded-read stub satisfies check_scripts and
    # check_reader_bounds.
    write(root / "scripts" / "ops-render.sh",
          ROUTABLE_STUB +
          '# stub renderer\n'
          '_r() { local LC_ALL=C; :; }\n'
          'while IFS= read -r -n 256 line; do :; done\n')
    # The compressor is hook-wired, so the good tree must carry it or
    # check_compressor fires; the guard checks call sites (F48), so the stub
    # carries both declarations and applications.
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
          # scrub's ANSI regexes carry the literal \x1b anchors (audit F120's
          # guardrail pin — without them the OSC pattern destroys output).
          'function scrub(text) {\n'
          '  let out = text.replace(/\\x1b\\][^]*?(?:\\x07|\\x1b\\\\)/g, "")\n'
          '    .replace(/\\x1b\\[[0-9;?]*[A-Za-z]/g, "");\n'
          '  return out;\n'
          '}\n'
          'function compress(tool, cmd) {\n'
          # The reachability anchor: the guards below must sit at the SAME brace
          # depth as this line, which is how a dead `if (false) { … }` wrapper is
          # caught (Copilot, PR #87).
          '  const tool = payload.tool_name;\n'
          '  if (NEVER_COMPRESS.has(tool)) return null;\n'
          '  if (tool.startsWith("mcp__")) return null;\n'
          '  const losslessOnly = LOSSLESS_ONLY.has(tool);\n'
          '  if (LEDGER_PATHS.some((p) => cmd.includes(p))) return null;\n'
          '  if (GATE_CLIS.some((c) => cmd.includes(c))) return null;\n'
          '  return losslessOnly;\n'
          '}\n')

    # default.tmpl must carry a model: line or check_render_templates fires.
    write(root / "agents" / "_templates" / "default.tmpl",
          '---\nname: op-NAME\nmodel: MODEL\ntools: Read\n---\nbody\n')
    # No ROUTABLE since 0.8.3: an id-shape catalogue is a finding, not a
    # requirement; BAD_CHARSET is the guard.
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
    # plan.js is separate because check_northstar REPORTS a missing plan.js
    # rather than skipping (#58): read without a fallback, refused when absent
    # or missing `Missed if:`, interpolated into exactly one prompt.
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
        # Iterate vp.CHECKS rather than re-listing checks here — a hand-copied
        # list had silently fallen three checks behind the build.
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
        # Strip the bool coercion from one hook's json_get; check_guard_parity
        # must report the drift.
        p = self.dir / "scripts" / "ops-sessionstart-hook.sh"
        p.write_text(p.read_text(encoding="utf-8").replace(
            "isinstance(v, bool)", "isinstance(v, wasbool)"), encoding="utf-8")
        self.assertFires("json_get() has no REACHABLE isinstance(v, bool)")

    # --- #85: the auto-arm rule (check_autobar) ---
    # Every mutation below is one a maintainer would plausibly make as a
    # "simplification", and every one of them leaves the armer silently broken.
    # The fixture was TAUGHT about autobar.sh when this shipped, so these cases
    # exist to prove the checker still fires — a fixture edited only to go green
    # would otherwise disable the check with the suite passing (F30's shape).
    def _autobar(self):
        return self.dir / "scripts" / "lib" / "autobar.sh"

    def _mutate_autobar(self, old, new):
        p = self._autobar()
        text = p.read_text(encoding="utf-8")
        self.assertIn(old, text)
        p.write_text(text.replace(old, new, 1), encoding="utf-8")

    def test_autobar_command_substitution_fires(self):
        # `$( )` DELETES NUL bytes (measured, bash 3.2.57: a three-entry -z
        # porcelain counted 0), so the armer silently never fires.
        self._mutate_autobar("< <(git -C", '<<< "$(git -C')
        self.assertFires("process substitution")

    def test_autobar_missing_z_flag_fires(self):
        # Without -z a path with a space is QUOTED and a rename is one line.
        self._mutate_autobar("--porcelain -z", "--porcelain")
        self.assertFires("`-z`")

    def test_autobar_missing_uall_flag_fires(self):
        # audit F132: -uall is as load-bearing as -z and had no pin —
        # porcelain's default collapses an untracked directory into ONE
        # record, so N new files under a new dir count 1 and the >=2-paths
        # threshold never trips on the common multi-file shape being gated.
        self._mutate_autobar("--porcelain -z -uall", "--porcelain -z")
        self.assertFires("`-uall`")

    def test_autobar_missing_repo_check_fires(self):
        # Process substitution carries no exit status: without this call
        # "not a repo" and "clean repo" both arrive as zero records.
        self._mutate_autobar("git -C \"$root\" rev-parse --git-dir >/dev/null 2>&1 || return 0", ":")
        self.assertFires("rev-parse")

    def test_autobar_missing_marker_fires(self):
        # No once-per-session marker → re-arms after every verdict, forever.
        self._mutate_autobar("autobar_mark_armed()", "autobar_mark_armedX()")
        self.assertFires("autobar_mark_armed")

    def test_autobar_decide_skips_already_armed_fires(self):
        self._mutate_autobar('autobar_already_armed \"$2\" \"$3\" && return 0', ":")
        self.assertFires("never calls autobar_already_armed")

    def test_autobar_suppression_readded_fires(self):
        # INVERTED from the pin that shipped with #85. Foreign-presence
        # suppression was removed because an OPEN foreign sentinel means
        # "working OR died" and nothing here can tell those apart, so one
        # abandoned sentinel (crash, kill, /clear mid-task) disarmed the gate
        # permanently. Re-adding it is the reflex fix when a shared worktree
        # arms an innocent session, and it trades a bounded self-clearing false
        # positive for a permanent silent disarm.
        p = self._autobar()
        p.write_text(p.read_text(encoding="utf-8").replace(
            "autobar_decide() {\n",
            "autobar_decide() {\n  autobar_foreign_activity \"$2\" \"$3\"\n", 1),
            encoding="utf-8")
        self.assertFires("calls autobar_foreign_activity")

    def test_autobar_lib_missing_fires(self):
        self._autobar().unlink()
        self.assertFires("scripts/lib/autobar.sh is missing")

    def test_autobar_hook_not_sourcing_fires(self):
        p = self.dir / "scripts" / "ops-stop-hook.sh"
        p.write_text(p.read_text(encoding="utf-8").replace(". lib/autobar.sh\n", ""),
                     encoding="utf-8")
        self.assertFires("does not SOURCE lib/autobar.sh")

    def test_autobar_hook_mentioning_not_sourcing_fires(self):
        # The pin was `"autobar.sh" in hcode` and this exact mutation shipped 0
        # problems (#86 review) while the hook died at runtime: set -u aborts on
        # autobar_arm one line later, and exit 1 is not exit 2, so the Stop is
        # ALLOWED and the deviation gate below never runs either. A mention is
        # not a source.
        p = self.dir / "scripts" / "ops-stop-hook.sh"
        p.write_text(p.read_text(encoding="utf-8").replace(
            ". lib/autobar.sh\n", "echo 'autobar.sh disabled for now'\n"),
            encoding="utf-8")
        self.assertFires("does not SOURCE lib/autobar.sh")

    def test_autobar_commented_out_source_fires(self):
        # Same class, the other reflex spelling: commenting the line out leaves
        # the filename in the file.
        p = self.dir / "scripts" / "ops-stop-hook.sh"
        p.write_text(p.read_text(encoding="utf-8").replace(
            ". lib/autobar.sh\n", "# . lib/autobar.sh\n"), encoding="utf-8")
        self.assertFires("does not SOURCE lib/autobar.sh")

    def test_autobar_count_redefined_is_NAMED_not_misattributed(self):
        # #86 review: _function_body returned an empty sentinel and the promised
        # check_no_redefinitions existed nowhere, so a duplicated function
        # produced THREE confident, individually-worded, FALSE problems — every
        # one of those properties present in the live definition — while the
        # real defect went unnamed. The diagnostic was computed (.fn/.n) and
        # discarded, this repo's own prior bug shape. Assert the redefinition is
        # named AND the false three are gone: naming it while still emitting
        # them would satisfy a bare "is it reported" check.
        p = self._autobar()
        c = p.read_text(encoding="utf-8")
        i = c.index("autobar_count_changed() {")
        j = c.index("\n}\n", i) + 3
        p.write_text(c[:j] + c[i:j] + c[j:], encoding="utf-8")
        probs = self.problems()
        self.assertTrue(any("is defined 2 times" in x for x in probs), probs)
        for false_claim in ("does not pass `-z`",
                            "does not read through process substitution",
                            "no separate `git rev-parse`"):
            self.assertFalse(any(false_claim in x for x in probs),
                             f"misattributed {false_claim!r} survived: {probs}")

    def test_autobar_decide_redefined_is_NAMED(self):
        # The second _function_body call site in check_autobar. Both need the
        # branch; fixing one leaves the other reporting the wrong thing.
        p = self._autobar()
        c = p.read_text(encoding="utf-8")
        i = c.index("autobar_decide() {")
        j = c.index("\n}\n", i) + 3
        p.write_text(c[:j] + c[i:j] + c[j:], encoding="utf-8")
        probs = self.problems()
        self.assertTrue(any("autobar_decide() is defined 2 times" in x
                            for x in probs), probs)
        self.assertFalse(any("never calls autobar_already_armed" in x
                             for x in probs), probs)

    def test_autobar_sourced_before_partition_fires(self):
        # Order is still pinned, but NOT for the reason this test shipped with:
        # autobar stopped calling sentinel_owner_of_name at e839490 and the two
        # libs share no symbol today (`grep -c` in autobar.sh → 0). What the
        # order protects is the hook's own seam — autobar_decide runs before
        # scan_pending, so a sentinel armed here is read by the existing
        # mine-pending branch in the same fire.
        p = self.dir / "scripts" / "ops-stop-hook.sh"
        p.write_text(p.read_text(encoding="utf-8").replace(
            ". lib/partition.sh\n. lib/autobar.sh\n",
            ". lib/autobar.sh\n. lib/partition.sh\n"), encoding="utf-8")
        self.assertFires("sourced before")

    def test_autobar_sessionstart_wipe_missing_fires(self):
        # A stale marker for a reused id disarms a future session permanently.
        p = self.dir / "scripts" / "ops-sessionstart-hook.sh"
        p.write_text(p.read_text(encoding="utf-8").replace(
            'rm -rf "$cwd/.operator/.autobar"\n', ""), encoding="utf-8")
        self.assertFires("does not wipe .operator/.autobar/")

    # --- the U10 source-state stamp (check_source_stamp) ---
    # The last two mutations matter most: neither changes observable output.
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
        # be off (#21's vacuous-guard class).
        self._mutate_verdict(" -- ':(exclude).operator'", "")
        self.assertFires("must exclude")

    def test_source_stamp_fifth_cell(self):
        self._mutate_verdict("| %s | %s | %s @%s | %s |",
                             "| %s | %s | %s | @%s | %s |")
        self.assertFires("four cells")

    def test_source_stamp_resolved_but_never_applied(self):
        # F30: declared and not applied — resolver exists, row carries none of it.
        self._mutate_verdict("SOURCE_STAMP", "UNUSED_STAMP")
        self.assertFires("never applied to the row")

    def test_source_stamp_dropped_from_the_row_argument_only(self):
        # The narrower mutation: `SOURCE_STAMP="$(source_stamp)"` stays (so
        # `"SOURCE_STAMP" in code` is true) but the row's own argument becomes
        # a literal. "Applied" means the printf carries it.
        self._mutate_verdict('"$E" "$SOURCE_STAMP" "$V"', '"$E" "BOGUS" "$V"')
        self.assertFires('does not pass "$SOURCE_STAMP"')

    def test_source_stamp_row_site_missing_is_reported(self):
        # Not-found must be a reported problem, never a silent skip.
        self._mutate_verdict('ROW="$(printf ', 'ROW2="$(printf ')
        self.assertFires("check_source_stamp cannot verify")

    def test_source_stamp_resolved_inside_the_lock(self):
        # PLAYBOOK's step-3 hazard: git work inside the critical section. First
        # draft split on an already-stripped comment marker and silently skipped.
        self._mutate_verdict(
            "SOURCE_STAMP=\"$(source_stamp)\"\nlock_acquire",
            "lock_acquire\nSOURCE_STAMP=\"$(source_stamp)\"")
        self.assertFires("sit AFTER lock_acquire")

    def test_source_stamp_second_call_APPENDED_inside_the_lock(self):
        # The pin read `next(...)` — the FIRST source_stamp line — so keeping
        # the correct call and APPENDING a second one after lock_acquire left
        # stamp_at < lock_at true and the check satisfied, while an unbounded
        # git status ran in the critical section: the exact hazard the message
        # names, at a site the pin could not see. Measured green through the
        # validator, 193 python and 683 bash (#86 pin audit, SN5).
        #
        # Appending is the PLAUSIBLE mutation — a maintainer wanting a fresher
        # stamp adds a line rather than moving one — and it is #81's
        # first-vs-last shape a third time: fixed for assignments
        # (_single_assignment), for definitions (_function_body), never for
        # ORDER until now.
        self._mutate_verdict(
            "lock_acquire\nROW=",
            "lock_acquire\nSOURCE_STAMP=\"$(source_stamp)\"\nROW=")
        probs = self.problems()
        self.assertTrue(any("sit AFTER lock_acquire" in p for p in probs), probs)
        # The count must be reported: "1 of 2" is what tells a maintainer a
        # correct call still exists and a second one was added, which is a
        # different repair from "the only call is in the wrong place".
        self.assertTrue(any("1 of 2 source_stamp" in p for p in probs), probs)

    def test_source_stamp_verdict_path_marker_lost(self):
        # Not-found must be a reported problem, never a silent skip.
        self._mutate_verdict("# --- Verdict path ---", "# --- verdict stuff ---")
        self.assertFires("Verdict path")

    # --- the handout packet pin (check_handout_packet, F69 + #57) ---
    # The full packet spine, written once rather than derived from
    # vp.HANDOUT_PACKET_SPINE (a derived test asserts self-consistency, not
    # correctness). FENCED, because check_handout_packet extracts the ``` block
    # rather than searching the whole document (Copilot, PR #72).
    _PACKET = ("```\n"
               "TASK / TEXT / SCENE / INPUTS / FORBIDDEN / DONE / REACH (entry "
               "point + proof) / REPORT (status, SHA, CHANGED: <paths>|none)\n"
               "```\n")

    # The spine's fields, hardcoded rather than looped from vp.HANDOUT_PACKET_SPINE:
    # deriving the loop's expectation from the module under test let a dropped
    # field (REACH) stay green while the guard lost it — measured, 3 passed with
    # REACH deleted from the spine. `_EXPECTED_SPINE` is the independent copy.
    _EXPECTED_SPINE = ("TASK / TEXT / SCENE", "REACH", "CHANGED: <paths>|none")

    def test_spine_matches_expected(self):
        # The one place the two copies are compared; a field added to the product
        # spine without being added here fails HERE, loudly.
        self.assertEqual(
            tuple(vp.HANDOUT_PACKET_SPINE), self._EXPECTED_SPINE,
            "HANDOUT_PACKET_SPINE changed — update _EXPECTED_SPINE too, and check "
            "that templates/OPERATOR.md and docs/HANDOUT.md carry the new field")

    def test_handout_packet_pin(self):
        # No handout: the handout half must skip (prose is optional). The charter
        # half is unconditional.
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
        # F69, measured: the handout dropped CHANGED — exercises the missing-FIELD
        # path (distinct from the missing-BLOCK path below).
        write(h, "packet:\n```\nTASK / TEXT / SCENE / INPUTS / DONE / REACH / REPORT\n```\n")
        self.assertFires("the dispatch packet is missing")
        # The missing-block path: an unfenced packet is REPORTED, not skipped.
        write(h, "packet:\nTASK / TEXT / SCENE / INPUTS / DONE / REACH / CHANGED: <paths>|none\n")
        self.assertFires("no fenced dispatch-packet block found")

    def test_handout_packet_pin_fires_per_field(self):
        # Every field must be independently load-bearing — the original pin held
        # only the FIRST and LAST fragments, so REACH going in the MIDDLE (0.8.4)
        # was invisible. One assertion per field.
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
        # Parity between handout and charter passes perfectly when the CHARTER is
        # what lost the field (F30); with no packet at all, every field must fire.
        c = self.dir / "templates" / "OPERATOR.md"
        stripped = c.read_text().replace(_PACKET_SENTENCE, "")
        self.assertNotIn("REACH", stripped, "the strip did not take — this case would be vacuous")
        write(c, stripped)
        probs = []
        vp.check_handout_packet(self.dir, probs)
        # Stripping the whole stanza removes the FENCE too, so the finding is the
        # missing block, not N missing fields.
        self.assertTrue(
            any("OPERATOR.md" in p for p in probs),
            f"a charter with no dispatch packet produced no finding at all: {probs}")
        self.assertTrue(
            any("no fenced dispatch-packet block found" in p for p in probs),
            f"expected the missing-block finding, got: {probs}")
        # The per-FIELD half, on a charter that still has a packet but lost one
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
        # A [DOC:spec-*] tag with no `### spec-*` entry in docs/spec/TAGS.md must
        # fail — the index is where DOC tags resolve in a clone (#76 step E).
        write(self.dir / "templates" / "OPERATOR.md",
              GOOD_CHARTER.replace("[DOC:spec-D4]", "[DOC:spec-D4] [DOC:spec-ghost]", 1))
        self.assertFires("[DOC:spec-ghost] has no `### spec-ghost` entry")

    def test_charter_doc_tags_with_missing_index_fires(self):
        (self.dir / "docs" / "spec" / "TAGS.md").unlink()
        self.assertFires("docs/spec/TAGS.md: missing")

    def test_charter_orphan_index_entry_is_not_a_finding(self):
        # The reverse direction is deliberately unchecked: a surviving entry for a
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
        # ops-adopt.sh is the /clear recovery path.
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
        # Drop HANDOFF-MARK from the enum — check_decisions_schema pins every kind.
        write(self.dir / "templates" / "DECISIONS-header.md",
              "# Decisions\n"
              "# gated: DEVIATION | ESCALATION | GATE-EXCEPTION\n"
              "# record: DECISION | DEFERRED-VERDICT\n")
        self.assertFires("missing 'HANDOFF-MARK'")

    def test_decisions_enum_missing_split_fires(self):
        # All kinds present but no gated/record split (issue #9).
        write(self.dir / "templates" / "DECISIONS-header.md",
              "# <ISO-date> | <eng> | "
              "<DEVIATION|ESCALATION|GATE-EXCEPTION|DECISION|DEFERRED-VERDICT"
              "|HANDOFF-MARK> | <what> | <why>\n")
        self.assertFires("does not distinguish gated from record kinds")

    def test_decisions_reader_missing_handoff_mark_fires(self):
        # A deviation-gate reader that never matches HANDOFF-MARK never clears
        # (F30 call-site half); the shared scan lives in lib/partition.sh.
        p = self.dir / "scripts" / "lib" / "partition.sh"
        write(p, p.read_text().replace("HANDOFF-MARK", "NO-SUCH-MARK"))
        self.assertFires("does not reference HANDOFF-MARK")

    def test_decisions_reader_gated_literal_drift_fires(self):
        # A reader counting a kind the gate should ignore (issue #9); mutate the
        # shared lib's gated literal so only this check fires.
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
        # opens unowned and blocks every concurrent session.
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
        self.assertFires("SessionStart command must be exactly")

    def test_hook_command_prefixed_with_true_fires(self):
        """`true # ` names the script, resolves the plugin root, and runs
        NOTHING — the whole evidence gate off, with both old substring tests
        satisfied (audited 2026-08-25)."""
        p = self.dir / "hooks" / "hooks.json"
        d = json.loads(p.read_text())
        d["hooks"]["Stop"][0]["hooks"][0]["command"] = \
            'true # bash "${CLAUDE_PLUGIN_ROOT}/scripts/ops-stop-hook.sh"'
        write(p, json.dumps(d))
        self.assertFires("Stop command must be exactly")

    def test_hook_appended_second_entry_fires(self):
        """The check reads entry [0]; an APPENDED `exit 0` decides Stop's
        verdict after ours and was invisible."""
        p = self.dir / "hooks" / "hooks.json"
        d = json.loads(p.read_text())
        d["hooks"]["Stop"][0]["hooks"].append({"type": "command", "command": "exit 0"})
        write(p, json.dumps(d))
        self.assertFires("exactly 1 is expected")

    def test_hook_second_matcher_group_fires(self):
        """The first fix read `[event][0]["hooks"]` and counted the INNER list,
        so appending a second MATCHER GROUP registered an unreviewed hook one
        level up with the build green (Copilot, PR #87) — index-zero blindness
        in the fix written against index-zero blindness."""
        p = self.dir / "hooks" / "hooks.json"
        d = json.loads(p.read_text())
        d["hooks"]["Stop"].append({"hooks": [{"type": "command", "command": "exit 0"}]})
        write(p, json.dumps(d))
        self.assertFires("matcher group(s); exactly 1 is expected")

    def test_hook_non_string_command_reports_not_raises(self):
        """A JSON-valid non-string reached `.strip()` and raised
        AttributeError, aborting the validator instead of reporting."""
        p = self.dir / "hooks" / "hooks.json"
        d = json.loads(p.read_text())
        d["hooks"]["Stop"][0]["hooks"][0]["command"] = None
        write(p, json.dumps(d))
        self.assertFires("not a string")

    def test_hook_non_command_type_fires(self):
        """The harness runs a hook by its `type`. An entry carrying the exact
        expected command string under another type passes every string test and
        executes nothing."""
        p = self.dir / "hooks" / "hooks.json"
        d = json.loads(p.read_text())
        d["hooks"]["Stop"][0]["hooks"][0]["type"] = "prompt"
        write(p, json.dumps(d))
        self.assertFires("not 'command'")

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
    # cc-status discovers the segment only through this manifest and skips an
    # unresolvable renderer silently — nothing else would notice.

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
        # A lost byte bound on the ~300ms-timer segment is a permanently wedged
        # bar (6.20s per parse on a 64MB sentinel, measured), not merely slow.
        write(self.dir / "scripts" / "statusline.sh",
              '#!/usr/bin/env bash\nwhile IFS= read -r line; do :; done < "$1"\n')
        self.assertFires("scripts/statusline.sh")

    # --- 9/10. audit guardrails: reader bounds + guard parity ---
    # These enforce cross-file couplings that were prose in CLAUDE.md and were
    # still violated.

    def _write_readers(self, verdict_body=None, adopt_body=None, hook_body=None):
        """Install minimal but realistic reader scripts into the fixture tree."""
        good_hook = (
            "#!/usr/bin/env bash\n"
            "_r() { local LC_ALL=C; :; }\n"
            ". lib/partition.sh\n"
            "[ ! -L \"$1\" ] || exit 0\n" + JSON_GET)
        good_verdict = (
            "#!/usr/bin/env bash\n"
            "_r() { local LC_ALL=C; :; }\n"
            "check_bare_name() { case \"$2\" in .*) die x ;; *__*) die x ;; esac; }\n"
            "check_owner_name() { case \"$1\" in *[[:space:]]*) die x ;; *'$'* | *'`'* | *\"'\"* | *'\"'* | *\\\\*) die x ;; esac; }\n"
            "[ ! -L \"$f\" ] || exit 0\n" + f136_lookup("sentinel_path") +
            "sentinel_owner_of_name() {\n"
          "  case \"$_o\" in \"\" | */* | .* | *\"|\"* | *[[:space:]]*) printf '\\n'; return 0 ;;\n"
    "    *'$'* | *'`'* | *\"'\"* | *'\"'* | *\\\\*) printf '\\n'; return 0 ;; esac\n"
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
            "_r() { local LC_ALL=C; :; }\n"
            "check_bare_name() { case \"$2\" in .*) die x ;; *__*) die x ;; esac; }\n"
            "check_owner_name() { case \"$1\" in *[[:space:]]*) die x ;; *'$'* | *'`'* | *\"'\"* | *'\"'* | *\\\\*) die x ;; esac; }\n"
            "[ ! -L \"$F\" ] || exit 0\n" + f136_lookup("sentinel_path") +
            # PREV reject-set (F15): the owner now arrives in the sentinel name,
            # so adoption reads no file at all.
            'case "${PREV:-}" in */* | .* | *"|"* | *[[:space:]]* | *[[:cntrl:]]* | *.exempt) PREV="<invalid>" ;; esac\n')
        write(self.dir / "scripts" / "ops-stop-hook.sh", hook_body or good_hook)
        write(self.dir / "scripts" / "ops-verdict.sh", verdict_body or good_verdict)
        write(self.dir / "scripts" / "ops-adopt.sh", adopt_body or good_adopt)
        write(self.dir / "scripts" / "ops-task.sh",
              "#!/usr/bin/env bash\n"
              "check_bare_name() { case \"$2\" in .*) die x ;; *__*) die x ;; esac; }\n"
              "check_owner_name() { case \"$1\" in *[[:space:]]*) die x ;; *'$'* | *'`'* | *\"'\"* | *'\"'* | *\\\\*) die x ;; esac; }\n"
              "[ ! -L \"$F\" ] || exit 0\n" + f136_lookup("sentinel_for") + F136_DUPLOOP)
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
            "check_owner_name() { case \"$1\" in *[[:space:]]*) die x ;; *'$'* | *'`'* | *\"'\"* | *'\"'* | *\\\\*) die x ;; esac; }\n"
            "while IFS= read -r line; do :; done < \"$f\"\n"
            "while IFS= read -r -n 512 row; do :; done < \"$frag\"\n"))
        probs = self.bounds_problems()
        self.assertTrue(any("unbounded `read -r`" in p for p in probs), probs)

    # Audited 2026-08-25: the check counted OCCURRENCES of `read -r -n \d+` and
    # never read N, never asked where the text was, and exempted every `-d`
    # form. Three escapes, all green against the hottest reader in the plugin.

    def test_inflated_read_bound_fires(self):
        """A 256MB "bound" is not a bound: the file is still read whole."""
        self._write_readers(verdict_body=(
            "#!/usr/bin/env bash\n"
            "check_bare_name() { case \"$2\" in .*) die x ;; *__*) die x ;; esac; }\n"
            "check_owner_name() { case \"$1\" in *[[:space:]]*) die x ;; *'$'* | *'`'* | *\"'\"* | *'\"'* | *\\\\*) die x ;; esac; }\n"
            "while IFS= read -r -n 268435456 row; do :; done < \"$frag\"\n"))
        probs = self.bounds_problems()
        self.assertTrue(any("is not a bound" in p for p in probs), probs)

    def test_read_bound_in_prose_does_not_count(self):
        """The counter was satisfied by the STRING `read -r -n 512` in a helper
        while the real loop had lost its bound — MENTION, not ACTION."""
        self._write_readers(verdict_body=(
            "#!/usr/bin/env bash\n"
            "check_bare_name() { case \"$2\" in .*) die x ;; *__*) die x ;; esac; }\n"
            "check_owner_name() { case \"$1\" in *[[:space:]]*) die x ;; *'$'* | *'`'* | *\"'\"* | *'\"'* | *\\\\*) die x ;; esac; }\n"
            "_doc() { echo \"use read -r -n 512 here\"; }\n"))
        probs = self.bounds_problems()
        self.assertTrue(any("lost its bound" in p for p in probs), probs)

    def test_read_d_newline_is_not_the_payload_exemption(self):
        """`read -r -d $'\\n'` is a line-delimited read wearing the stdin-slurp
        exemption's clothes — same unbounded behaviour as a plain `read -r`."""
        self._write_readers(verdict_body=(
            "#!/usr/bin/env bash\n"
            "check_bare_name() { case \"$2\" in .*) die x ;; *__*) die x ;; esac; }\n"
            "check_owner_name() { case \"$1\" in *[[:space:]]*) die x ;; *'$'* | *'`'* | *\"'\"* | *'\"'* | *\\\\*) die x ;; esac; }\n"
            "while IFS= read -r -d $'\\n' row; do :; done < \"$frag\"\n"))
        probs = self.bounds_problems()
        self.assertTrue(any("unbounded `read -r`" in p for p in probs), probs)

    def test_missing_lc_all_fires(self):
        """A byte cap is only a byte cap in the C locale: bash `read -n N`
        counts CHARACTERS outside it, so a 512-"char" read is up to 2048 bytes
        (measured, bash 3.2.57 and 5.2.15: 512 chars of "é" = 1024 bytes) and
        every cap is 4x looser than it reads (Copilot, PR #87)."""
        self._write_readers(verdict_body=(
            "#!/usr/bin/env bash\n"
            "check_bare_name() { case \"$2\" in .*) die x ;; *__*) die x ;; esac; }\n"
            "check_owner_name() { case \"$1\" in *[[:space:]]*) die x ;; *'$'* | *'`'* | *\"'\"* | *'\"'* | *\\\\*) die x ;; esac; }\n"
            "while IFS= read -r -n 1048576 row; do :; done < \"$frag\"\n"))
        probs = self.bounds_problems()
        self.assertTrue(any("LC_ALL=C" in p for p in probs), probs)

    def test_bare_payload_slurp_still_exempt(self):
        """CONTROL: the real `read -r -d ''` payload slurp must stay exempt, or
        every gate CLI reports a false unbounded read."""
        self._write_readers(verdict_body=(
            "#!/usr/bin/env bash\n"
            "check_bare_name() { case \"$2\" in .*) die x ;; *__*) die x ;; esac; }\n"
            "check_owner_name() { case \"$1\" in *[[:space:]]*) die x ;; *'$'* | *'`'* | *\"'\"* | *'\"'* | *\\\\*) die x ;; esac; }\n"
            "IFS= read -r -d '' PAYLOAD || true\n"
            "while IFS= read -r -n 1048576 row; do :; done < \"$frag\"\n"))
        probs = self.bounds_problems()
        self.assertFalse(any("unbounded `read -r`" in p for p in probs), probs)

    # The NUL probe (_np … le 40) must carry a chunk cap — an uncapped probe still
    # detects a late NUL but walks a newline-less multi-MB file first (66-70s on
    # 64MB vs 0.11s capped, bash 3.2.57). These pin the parity F59 established.

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
        # The exact drift F59 prevented: a probe looping whole-file with no
        # _np counter.
        write(self.dir / "scripts" / "ops-render.sh",
              "#!/usr/bin/env bash\n"
              "while IFS= read -r -n 512 line; do :; done < \"$1\"\n"
              + self._UNCAPPED_PROBE)
        probs = []
        vp.check_reader_bounds(self.dir, probs)
        self.assertTrue(any("chunk cap" in p for p in probs), probs)

    def test_missing_symlink_guard_fires(self):
        # The F65 -L guard is a reader coupling across task/verdict/adopt CLIs,
        # the statusline, and lib/partition.sh.
        p = self.dir / "scripts" / "lib" / "partition.sh"
        write(p, p.read_text().replace('[ ! -L "$decisions" ] || exit 0', ":"))
        probs = self.bounds_problems()
        self.assertTrue(any("symlink" in p and "lib/partition.sh" in p
                            for p in probs), probs)

    def test_probe_cap_raised_to_substring_superset_fires(self):
        # The first chunk-cap check was a substring test ("le 40" in window), so
        # `-le 400000` passed as if it were 40 (code-review of f4cae1a).
        write(self.dir / "scripts" / "ops-tiers.sh",
              "#!/usr/bin/env bash\n"
              "while IFS= read -r -n 512 line; do :; done < \"$1\"\n"
              + self._CAPPED_PROBE.replace("-le 40 ", "-le 400000 "))
        probs = []
        vp.check_reader_bounds(self.dir, probs)
        self.assertTrue(any("chunk cap" in p for p in probs), probs)

    def test_probe_variable_rename_does_not_evade_the_check(self):
        # The probe detector was keyed to the literal variable name _nulprobe;
        # any `read -r -d '' -n N <var>` loop must carry the cap regardless of name.
        write(self.dir / "scripts" / "ops-tiers.sh",
              "#!/usr/bin/env bash\n"
              "while IFS= read -r -n 512 line; do :; done < \"$1\"\n"
              + self._UNCAPPED_PROBE.replace("_nulprobe", "_chunk"))
        probs = []
        vp.check_reader_bounds(self.dir, probs)
        self.assertTrue(any("chunk cap" in p for p in probs), probs)

    def test_comments_mentioning_read_do_not_fire(self):
        # A checker that fires on its own documentation trains the maintainer to
        # ignore the build.
        self._write_readers(adopt_body=(
            "#!/usr/bin/env bash\n"
            "# `read -r` is bounded by LINES, not bytes — discussion only.\n"
            "#    a plain read -r would slurp the whole line first\n"
            "check_bare_name() { case \"$2\" in .*) die x ;; *__*) die x ;; esac; }\n"
            "check_owner_name() { case \"$1\" in *[[:space:]]*) die x ;; *'$'* | *'`'* | *\"'\"* | *'\"'* | *\\\\*) die x ;; esac; }\n"
            "[ ! -L \"$F\" ] || exit 0\n"
            "while IFS= read -r -n 512 line; do :; done < \"$F\"\n"
            + f136_lookup("sentinel_path") +
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
    # Empty frontmatter, a missing key, or a bare scripts/ path are silent
    # shipping bugs.

    def test_a_new_permission_guard_fires(self):
        # #21: a permission test is inert for uid 0, so a new one must not enter
        # a gate script unreviewed.
        real = (self.dir / "scripts" / "ops-task.sh").read_text(encoding="utf-8")
        write(self.dir / "scripts" / "ops-task.sh",
              real.replace("#!/usr/bin/env bash\n",
                           '#!/usr/bin/env bash\n[ -w /tmp ] || true\n', 1))
        probs = self.problems()
        self.assertTrue(any("permission test" in p and "ops-task.sh" in p
                            for p in probs), probs)

    def test_test_spelled_permission_guard_fires(self):
        """`test -w "$PWD"` has identical semantics to `[ -w … ]` and walked
        past the bracket-only regex (audited 2026-08-25)."""
        real = (self.dir / "scripts" / "ops-task.sh").read_text(encoding="utf-8")
        write(self.dir / "scripts" / "ops-task.sh",
              real.replace("#!/usr/bin/env bash\n",
                           '#!/usr/bin/env bash\nif test -w "$PWD"; then :; fi\n', 1))
        probs = self.problems()
        self.assertTrue(any("permission test" in p and "ops-task.sh" in p
                            for p in probs), probs)

    def test_permission_guard_in_scripts_lib_fires(self):
        """scripts/lib/ is sourced BY the gate, so a permission test there is a
        permission test in the gate. The docstring said "anywhere in scripts/";
        the glob said `scripts/*.sh` and missed both load-bearing libs."""
        p = self.dir / "scripts" / "lib" / "partition.sh"
        write(p, p.read_text(encoding="utf-8") + '\nif [ -w "$PWD" ]; then :; fi\n')
        probs = self.problems()
        self.assertTrue(any("permission test" in q and "lib/partition.sh" in q
                            for q in probs), probs)

    def test_commands_dir_optional(self):
        # A plugin that ships only agents need not have commands/; absence is
        # "not applicable", not a defect.
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
        # The layout-independent form must not fire — the check steers toward it,
        # not forbid script invocation outright.
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
    # check_workflows validates the tier-guard infrastructure per file; BAD_CHARSET
    # keeps JS and shell agreeing on the model-id charset (audit F01).

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

    # The exact tail make_good_tree ships (WF_SHARED), so an F133 meta case
    # trips ONLY the meta pin while parity/default-tiers stay green.
    _WF_TAIL = (
        'const BAD_CHARSET = /[^\\w./:@[\\]-]/;\n'
        'const DEFAULT_TIERS = { JUDGMENT: "opus" };\n'
        'for (const [n, id] of Object.entries(DEFAULT_TIERS)) {\n'
        '  if (BAD_CHARSET.test(id)) throw new Error("bad");\n'
        '}\n'
    )

    def test_workflow_template_literal_meta_fires(self):
        # audit F133: a template literal (`x ${y}`) is the OTHER computed-meta
        # spelling — the harness rejects it at launch exactly like a
        # concatenation, and the `+`-shaped pin could not see it.
        write(self.dir / "workflows" / "review.js",
              'export const meta = {\n'
              '  name: "review",\n'
              '  description: `x ${y}`,\n'
              '};\n' + self._WF_TAIL)
        self.assertFires("template literal")

    def test_workflow_call_expression_meta_fires(self):
        # audit F141 (2026-09-02): the `+` and backtick pins enumerate two
        # spellings of "computed"; `String("x").trim()` passed both AND every
        # suite while the harness refuses it at launch. Structural pin: only
        # literal values may remain once strings are stripped.
        write(self.dir / "workflows" / "review.js",
              'export const meta = {\n'
              '  name: String("review").trim(),\n'
              '  description: "d",\n'
              '};\n' + self._WF_TAIL)
        self.assertFires("not a PURE literal")

    def test_workflow_identifier_meta_value_fires(self):
        write(self.dir / "workflows" / "review.js",
              'const D = "d";\n'
              'export const meta = {\n'
              '  name: "review",\n'
              '  description: D,\n'
              '};\n' + self._WF_TAIL)
        probs = self.problems()
        self.assertTrue(any("not a PURE literal" in p for p in probs), probs)

    def test_workflow_literal_meta_with_nested_phases_is_clean(self):
        # CONTROL for F141: the shipped shape — nested arrays/objects, numbers,
        # booleans, a backtick and a colon INSIDE strings — is a pure literal.
        write(self.dir / "workflows" / "review.js",
              'export const meta = {\n'
              '  name: "review",\n'
              '  description: "resolve with `/cc-operator:tiers` first: then run",\n'
              '  // a comment with a call() and an identifier\n'
              '  phases: [{ title: "Panel", detail: "x" }, { title: "B", detail: "y", n: 2, on: true, z: null }],\n'
              '};\n' + self._WF_TAIL)
        probs = self.problems()
        self.assertEqual([p for p in probs if "PURE literal" in p], [], probs)

    def test_partition_source_line_with_a_trailing_comment_is_not_a_miss(self):
        # audit F142 (2026-09-02): `. "$_libdir/partition.sh"  # comment` is
        # legal shell (bash -n rc 0) and failed the build as "does not SOURCE"
        # — a false message on the load-bearing source pin. Both the partition
        # and the autobar source pins tolerate a trailing comment now; the
        # `echo "partition.sh"` and `fakepartition.sh` escapes still fire.
        hook = self.dir / "scripts" / "ops-stop-hook.sh"
        hook.write_text(hook.read_text(encoding="utf-8").replace(
            ". lib/partition.sh\n", ". lib/partition.sh  # the shared partition\n", 1)
            .replace(". lib/autobar.sh\n", ". lib/autobar.sh  # after partition\n", 1),
            encoding="utf-8")
        probs = self.problems()
        self.assertEqual([p for p in probs if "does not SOURCE" in p], [], probs)
        hook.write_text(hook.read_text(encoding="utf-8").replace(
            ". lib/partition.sh  # the shared partition\n", 'echo "partition.sh"\n', 1),
            encoding="utf-8")
        self.assertFires("does not SOURCE lib/partition.sh")

    def test_a_hash_glued_to_the_sourced_filename_is_not_a_comment(self):
        # Copilot review on PR #105: `\s*(?:#.*)?$` let `. lib/partition.sh#x`
        # pass — bash sources a file named `partition.sh#x`, which does not
        # exist, so the hook ran with no partition while the pin read a
        # trailing comment. A comment needs whitespace in front of it; both
        # source pins require it.
        hook = self.dir / "scripts" / "ops-stop-hook.sh"
        real = hook.read_text(encoding="utf-8")
        hook.write_text(real.replace(". lib/partition.sh\n", ". lib/partition.sh#not-a-comment\n", 1),
                        encoding="utf-8")
        self.assertFires("does not SOURCE lib/partition.sh")
        hook.write_text(real.replace(". lib/autobar.sh\n", '. "lib/autobar.sh"#not-a-comment\n', 1),
                        encoding="utf-8")
        self.assertFires("does not SOURCE lib/autobar.sh")

    def test_workflow_backtick_inside_meta_string_is_clean(self):
        # CONTROL for F133: shipped metas legitimately quote markdown code in
        # backticks INSIDE a double-quoted string (debate/dispatch/plan all
        # do) — the pin must strip string contents before judging backticks.
        write(self.dir / "workflows" / "review.js",
              'export const meta = {\n'
              '  name: "review",\n'
              '  description: "resolve ids with `/cc-operator:tiers` first",\n'
              '};\n' + self._WF_TAIL)
        probs = []
        vp.check_workflows(self.dir, probs)
        self.assertEqual([p for p in probs if "template literal" in p], [], probs)

    def test_workflow_reintroduced_routable_fires(self):
        # The inverse of the pre-0.8.3 case: an id-shape catalogue used to be
        # required; it's now a finding — operator does not judge model ids.
        write(self.dir / "workflows" / "review.js",
              self._wf("review", 'const ROUTABLE = /^glm-|^claude-/;\n'))
        self.assertFires("must not come back")

    def test_workflow_routable_in_a_comment_is_not_a_reintroduction(self):
        # ROUTABLE check reads raw text on purpose: prose about the removed guard
        # (which shipped workflows and this file's own comments carry) must not fire.
        write(self.dir / "workflows" / "review.js",
              self._wf("review", "// ROUTABLE was removed in 0.8.3; see check_workflows (c).\n"))
        probs = []
        vp.check_workflows(self.dir, probs)
        self.assertEqual([p for p in probs if "must not come back" in p], [])

    def test_workflow_uniform_bad_charset_drift_fires(self):
        # check_workflow_parity compares copies to EACH OTHER, so neutering
        # BAD_CHARSET in ALL of them at once passed every gate — uniform drift is
        # the realistic failure; only a canonical pin catches it.
        # Derived from the tree, not a hardcoded pair, so "uniform" means every copy.
        for f in sorted((self.dir / "workflows").glob("*.js")):
            write(f, f.read_text(encoding="utf-8").replace(
                "const BAD_CHARSET = /[^\\w./:@[\\]-]/;",
                "const BAD_CHARSET = /(?!)/;"))
        probs = []
        vp.check_workflow_parity(self.dir, probs)
        self.assertEqual(probs, [], "parity alone cannot see uniform drift")
        self.assertFires("BAD_CHARSET regex is")

    def test_workflow_bad_charset_never_applied_fires(self):
        # A declared-but-unused BAD_CHARSET guards nothing: deleting only the
        # `.test(id)` call site leaves parity and the canonical pin both passing.
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
        # F48/F57 class: a `.test(` call site moved into a `//` comment satisfies
        # the raw-text regex while the real guard is gone; only a comment-stripped
        # read catches it.
        write(self.dir / "workflows" / "review.js",
              self._wf("review").replace(
                  "  if (BAD_CHARSET.test(id)) throw new Error(\"x\");",
                  "  // if (BAD_CHARSET.test(id)) throw new Error(\"x\");"))
        self.assertFires("BAD_CHARSET is declared but never applied")

    def test_workflow_block_comment_neuters_bad_charset_fires(self):
        # Same class through block comments (/* */), an idiom in the workflows.
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
    # A workflow agentType resolves against the plugin registry; crawl.js shipped
    # dispatching op-scout while claiming op-crawler, which didn't exist.

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
        # dispatch.js resolves agentType from a SEATS table and passes the
        # shorthand `agentType,`; a KEY-anchored regex matched nothing there —
        # measured, all six seat values retyped to a nonexistent agent shipped
        # green. Matching the VALUE covers a table entry and a call site alike.
        write(self.dir / "workflows" / "review.js",
              'export const meta = { name: "review", description: "d" };\n'
                            'const SEATS = { scout: "cc-operator:op-ghost" };\n'
              'agent("x", { agentType: SEATS[s] });\n')
        probs = []
        vp.check_workflow_agent_types(self.dir, probs)
        self.assertTrue(any("op-ghost" in p and "names no shipped agent" in p
                            for p in probs), probs)

    def test_workflow_agent_type_in_a_comment_is_not_a_finding(self):
        # The value-form regex reads a comment-stripped view because
        # dispatch.js's own comment quotes `"cc-operator:op-" + seat` while
        # arguing against concatenating it.
        write(self.dir / "workflows" / "review.js",
              'export const meta = { name: "review", description: "d" };\n'
                            '// never write "cc-operator:op-ghost" as a computed string\n'
              '/* nor "cc-operator:op-phantom" in a block comment */\n'
              'agent("x", { agentType: "cc-operator:op-author" });\n')
        probs = []
        vp.check_workflow_agent_types(self.dir, probs)
        self.assertEqual(probs, [])

    # --- charter byte bounds (F19) ---
    # The 150-line cap bounds always-on tokens; a line-count-only gate is
    # gameable by packing prose into one long line.

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
    # workflows no longer declare which tier names exist; the alias pin catches
    # a vendor model id pasted back into DEFAULT_TIERS as the reflex fix that
    # recreates the old catalogue one file at a time.

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
        # Absence is a reshape, not a valid state — the locator must report,
        # never silently skip.
        write(self.dir / "workflows" / "review.js",
              'export const meta = { name: "review", description: "d" };\n')
        probs = []
        vp.check_workflow_default_tiers(self.dir, probs)
        self.assertTrue(any("no `const DEFAULT_TIERS" in p for p in probs), probs)

    def test_workflow_default_tiers_in_comment_only_fires(self):
        # Code-only view: a commented-out declaration must read as missing.
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
    # render_to()'s awk anchors on /^---$/; `---\r` doesn't match, so a CRLF
    # source skipped every substitution and shipped a stale model: at exit 0.

    def test_crlf_template_fires(self):
        (self.dir / "agents" / "_templates" / "default.tmpl").write_bytes(
            b"---\r\nname: op-NAME\r\nmodel: haiku\r\n---\r\nbody\r\n")
        probs = []
        vp.check_render_templates(self.dir, probs)
        self.assertTrue(any("contains CR" in p for p in probs), probs)

    def test_crlf_plugin_root_agent_fires(self):
        # agents/op-*.md is the first body source render_to tries (F14).
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
    # `stat -f %m F || stat -c %Y F` isn't portable — GNU -f prints a filesystem
    # block and exits 1, so the fallback output concatenates onto garbage.


class LockParityTest(unittest.TestCase):
    """The shared lock block must be identical in both writers.

    The guardrail exists because "keep the two implementations identical" was
    prose for the whole 0.4.0 cycle, and prose does not hold couplings — the
    same lesson `check_reader_bounds` was written for.
    """

    # Carries every CANONICAL_LOCK property: the check now pins CONTENT as
    # well as parity, because two copies drifting together are trivially in
    # parity — F30, measured against this very check on 2026-08-25 (the holder
    # read inflated to 999999999 in BOTH files, build green).
    BLOCK = (
        "# >>> LOCK BLOCK\n"
        "LOCK_SPINS=300\n"
        "lock_holder_live() {\n"
        '  { IFS= read -r -n 128 LOCK_HOLDER_REC < "$LOCKDIR/holder"; } 2>/dev/null || true\n'
        '  IFS= read -r -n 128 FALLBACK_REC < "$FALLBACK_DIR/holder" 2>/dev/null || true\n'
        '  kill -0 "$pid" 2>/dev/null && return 0\n'
        "}\n"
        "lock_acquire() {\n"
        '  while ! mkdir "$LOCKDIR" 2>/dev/null; do\n'
        '    mkdir "$LOCKDIR.reclaim" 2>/dev/null && rmdir "$LOCKDIR.reclaim"\n'
        "  done\n"
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

    def test_uniform_drift_fires(self):
        """F30, committed inside the check whose docstring teaches it: the
        holder read inflated to 999999999 in BOTH copies left them perfectly
        in parity with the ledger's mutual exclusion reading unbounded.
        Measured 2026-08-25; the bash suite did not see it either."""
        broke = self.BLOCK.replace("read -r -n 128", "read -r -n 999999999")
        self._write(verdict=broke.replace("TOOL:", "ops-verdict:"),
                    adopt=broke.replace("TOOL:", "ops-adopt:"))
        probs = self.problems()
        self.assertFalse(any("drifted" in p for p in probs),
                         "uniform drift IS in parity — that is the point")
        self.assertTrue(any("no longer contains" in p for p in probs), probs)

    def test_canonical_lock_in_a_comment_does_not_count(self):
        """The content pin searched the RAW block, so commenting out the real
        `while ! mkdir` and leaving the identical text in a comment satisfied
        it in both copies while the lock was a test-then-create race (Copilot,
        PR #87) — MENTION-not-ACTION inside the pin added to close it."""
        broke = self.BLOCK.replace(
            '  while ! mkdir "$LOCKDIR" 2>/dev/null; do',
            '  # while ! mkdir "$LOCKDIR" 2>/dev/null; do\n  while [ -d "$LOCKDIR" ]; do')
        self._write(verdict=broke.replace("TOOL:", "ops-verdict:"),
                    adopt=broke.replace("TOOL:", "ops-adopt:"))
        probs = self.problems()
        self.assertTrue(any("atomic primitive" in p for p in probs), probs)

    def test_uniform_loss_of_atomic_mkdir_fires(self):
        """A test-then-create is a race, not a lock — and applying it to both
        copies is the realistic edit, since they are maintained by copy-paste."""
        broke = self.BLOCK.replace('while ! mkdir "$LOCKDIR" 2>/dev/null; do',
                                   'while [ -d "$LOCKDIR" ]; do')
        self._write(verdict=broke.replace("TOOL:", "ops-verdict:"),
                    adopt=broke.replace("TOOL:", "ops-adopt:"))
        probs = self.problems()
        self.assertTrue(any("atomic primitive" in p for p in probs), probs)
        self.assertFalse(any("drifted" in p for p in probs),
                         "identically-broken copies are in parity — content is what catches this")

    def test_missing_markers_fire(self):
        self._write(adopt="lock_acquire() { :; }\n")
        probs = self.problems()
        self.assertTrue(any("LOCK BLOCK" in p for p in probs), probs)

    def test_real_scripts_are_in_parity(self):
        # Guards the shipped tree, not just a fixture.
        probs = []
        vp.check_lock_parity(ROOT, probs)
        self.assertEqual(probs, [])


class RootParityTest(unittest.TestCase):
    """The three gate CLIs must resolve the project the same way, and it must
    be the right way (#95).

    Until 0.11.3 OPDIR was relative to the caller's cwd, so every CLI worked
    from the project root and nowhere else — including through the ABSOLUTE
    path the Stop hook prescribes, which is how it was found: the 0.11.2
    release test pasted that command from `apps/viewer/` and got "missing
    .operator/DECISIONS.md".
    """

    BLOCK = (
        "# >>> PROJECT ROOT BLOCK\n"
        "_ops_cd_project_root() {\n"
        '  _walk="$(pwd -P 2>/dev/null)" || _walk=""\n'
        '  while [ -n "$_walk" ]; do\n'
        '    if [ -d "$_walk/.operator" ]; then\n'
        '      cd "$_walk" 2>/dev/null || die "TOOL: could not cd"\n'
        "      return 0\n"
        "    fi\n"
        '    [ -e "$_walk/.git" ] && break\n'
        '    [ "$_walk" = "/" ] && break\n'
        '    _walk="${_walk%/*}"; [ -n "$_walk" ] || _walk="/"\n'
        "  done\n"
        "  return 1\n"
        "}\n"
        "_ops_cd_project_root || :\n"
        "# <<< PROJECT ROOT BLOCK\n"
    )

    def setUp(self):
        self.dir = pathlib.Path(tempfile.mkdtemp())
        (self.dir / "scripts").mkdir(parents=True)

    def tearDown(self):
        shutil.rmtree(self.dir, ignore_errors=True)

    def _write(self, **over):
        for name in ("ops-task.sh", "ops-verdict.sh", "ops-adopt.sh"):
            key = name[:-3].replace("-", "_")
            body = over.get(key, self.BLOCK.replace("TOOL:", name[:-3] + ":"))
            write(self.dir / "scripts" / name, "#!/usr/bin/env bash\n" + body)

    def problems(self):
        probs = []
        vp.check_root_parity(self.dir, probs)
        return probs

    def test_identical_blocks_pass(self):
        self._write()
        self.assertEqual(self.problems(), [])

    def test_drifted_copy_fires(self):
        self._write(ops_adopt=self.BLOCK.replace("TOOL:", "ops-adopt:")
                    .replace('_walk=""', '_walk="/"'))
        probs = self.problems()
        self.assertTrue(any("drifted" in p for p in probs), probs)

    def test_uniform_loss_of_cd_fires(self):
        """The REFLEX fix: make OPDIR absolute instead of cd'ing. Every ledger
        path then looks right, and only the source stamp breaks — its
        `git status -- ':(exclude).operator'` pathspec is REPO-relative, so
        every row written from a subdirectory reads +dirty. Measured: the bash
        suite's two stamp CONTROLs are the only cases that fall over."""
        broke = self.BLOCK.replace('      cd "$_walk" 2>/dev/null || die "TOOL: could not cd"',
                                   '      OPDIR="$_walk/.operator"')
        self._write(ops_task=broke.replace("TOOL:", "ops-task:"),
                    ops_verdict=broke.replace("TOOL:", "ops-verdict:"),
                    ops_adopt=broke.replace("TOOL:", "ops-adopt:"))
        probs = self.problems()
        self.assertFalse(any("drifted" in p for p in probs),
                         "uniform drift IS in parity — that is the point")
        self.assertTrue(any("REPO-relative" in p for p in probs), probs)

    def test_uniform_loss_of_git_boundary_fires(self):
        """Without the .git stop a CLI run inside a vendored repo walks out and
        writes into the OUTER project's ledger."""
        broke = self.BLOCK.replace('    [ -e "$_walk/.git" ] && break\n', "")
        self._write(ops_task=broke.replace("TOOL:", "ops-task:"),
                    ops_verdict=broke.replace("TOOL:", "ops-verdict:"),
                    ops_adopt=broke.replace("TOOL:", "ops-adopt:"))
        probs = self.problems()
        self.assertTrue(any("nested repo" in p for p in probs), probs)

    def test_walk_in_a_comment_does_not_count(self):
        """MENTION-not-ACTION, the shape that already defeated the lock pin
        once (Copilot, PR #87): commenting the cd out leaves the literal in the
        block, so the content pin must read CODE only."""
        broke = self.BLOCK.replace(
            '      cd "$_walk" 2>/dev/null || die "TOOL: could not cd"',
            '      # cd "$_walk" 2>/dev/null || die "TOOL: could not cd"\n      :')
        self._write(ops_task=broke.replace("TOOL:", "ops-task:"),
                    ops_verdict=broke.replace("TOOL:", "ops-verdict:"),
                    ops_adopt=broke.replace("TOOL:", "ops-adopt:"))
        probs = self.problems()
        self.assertTrue(any("REPO-relative" in p for p in probs), probs)

    def test_missing_markers_fire(self):
        self._write(ops_task="OPDIR='.operator'\n")
        probs = self.problems()
        self.assertTrue(any("PROJECT ROOT BLOCK" in p for p in probs), probs)

    def test_real_scripts_are_in_parity(self):
        probs = []
        vp.check_root_parity(ROOT, probs)
        self.assertEqual(probs, [])


class ResolverRendererParityTest(unittest.TestCase):
    """ops-tiers.sh and ops-render.sh parse the same tiers.env, so they must
    refuse the same ids and gate on the same tier set.

    Both couplings were prose in CLAUDE.md with nothing enforcing them, while
    the two neighbouring duplications (the bash lock, the workflow regexes) each
    got a parity check after the same lesson.
    """

    # A minimal but structurally current guard: the id-shape arms and
    # $LENS_NAMESPACES allowlist were deleted from check_routable in 0.8.3, so
    # what the parity check pins now is the charset reject alone.
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
    # Kept as an empty string rather than deleted: every ROUTABLE+LENS+TIERS
    # call site below stays readable.
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
        # signature comment; neither is semantic.
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
        # Equality alone is satisfied by two identically gutted copies —
        # CANONICAL_BAD_CHARSET closes that hole for the workflow regexes.
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
        # A fifth tier added to the resolver leaves the renderer's is_tier_name
        # gating a stale namespace.
        self._write(tiers=self.ROUTABLE + self.LENS +
                    'TIER_NAMES="JUDGMENT IMPLEMENT MECHANICAL RECON EXTRA"\n')
        probs = self.problems()
        self.assertTrue(any("does not match the resolver's" in p
                            for p in probs), probs)

    def test_missing_tier_names_fires(self):
        self._write(render=self.ROUTABLE + self.LENS)
        self.assertTrue(any("no `TIER_NAMES" in p
                            for p in self.problems()), self.problems())

    # The three LENS_NAMESPACES cases that lived here went with the allowlist in
    # 0.8.3 — good tests of a bad idea, no replacement owed.

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

    def test_pinned_default_moved_to_a_comment_fires(self):
        # audit F134: the defaults pin searched RAW src, so a comment quoting
        # the old value satisfied it while the code shipped a different
        # number — the replay suite then asserted numbers the file no longer
        # had. The pin must read the comment-stripped view.
        src = self._real_comp.replace(
            "MIN_SHRINK: 64,", "MIN_SHRINK: 32, // was MIN_SHRINK: 64", 1)
        self.assertNotEqual(src, self._real_comp)
        probs = self._probs(src)
        self.assertTrue(any("MIN_SHRINK=64" in p for p in probs), probs)

    def test_scrub_regexes_without_esc_anchor_fire(self):
        # audit F120 guardrail: the 0.10.0 debloat stripped the raw ESC bytes
        # out of scrub's two ANSI regexes and the OSC pattern then matched
        # from the first bare `]` to end-of-terminator — a 3KB log came back
        # as ONE character: the scrub became a destroyer. Pin the fixed
        # literals `\x1b\]` and `\x1b\[`.
        src = (self._real_comp
               .replace("\\x1b\\]", "\\]", 1)
               .replace("\\x1b\\[", "\\[", 1))
        self.assertNotEqual(src, self._real_comp)
        probs = self._probs(src)
        self.assertTrue(any("OSC regex" in p for p in probs), probs)
        self.assertTrue(any("CSI regex" in p for p in probs), probs)

    def test_mcp_exclusion_deletion_fires(self):
        src = re.sub(r'if\s*\(tool\.startsWith\(\s*"mcp__"\s*\)\s*\)\s*return null;',
                     '', self._real_comp, count=1)
        self.assertTrue(any("mcp__" in p for p in self._probs(src)),
                        self._probs(src))

    def test_mcp_exclusion_noop_body_fires(self):
        # A neutered body `{ /* no-op */ }` skips the exclusion without deleting
        # the call site; the guard requires the `return null` body.
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
        # The realistic drift: dropping ONE name (NotebookEdit) while the rest
        # stay — a hardcoded-"Read" check missed this, so it's per-tool now.
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
        # Delete both .some() lines by line, not a greedy regex to EOF (the
        # first draft's regex deleted 3.6KB and produced a non-parsing mutant).
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
        # Dropping a path from the array, not the .some call — the first draft
        # only checked `.some(` existed.
        src = self._real_comp.replace('  ".operator/DECISIONS.md",\n', '', 1)
        self.assertTrue(any("DECISIONS" in p for p in self._probs(src)), self._probs(src))

    def test_never_compress_read_dropped_fires(self):
        # Drop Read itself — the tool the first draft hardcoded; the strongest
        # regression pin for F48.
        src = self._real_comp.replace(
            '"Read", "Edit", "Write", "NotebookEdit"',
            '"Edit", "Write", "NotebookEdit"', 1)
        probs = self._probs(src)
        self.assertTrue(any('`Read`' in p for p in probs), probs)

    def test_gate_cli_dropped_from_literal_fires(self):
        # Same partial-drain class on GATE_CLIS: drop one CLI, leave the
        # .some() call intact.
        src = self._real_comp.replace(', "ops-adopt.sh"', '', 1)
        probs = self._probs(src)
        self.assertTrue(any("ops-adopt.sh" in p for p in probs), probs)

    def test_lossless_only_callsite_neutered_fires(self):
        # LOSSLESS_ONLY's call-site counterpart: remove the .has(tool) use while
        # "Agent" stays in the set.
        src = self._real_comp.replace(
            'LOSSLESS_ONLY.has(tool)', 'false /* neutered */', 1)
        probs = self._probs(src)
        self.assertTrue(any("LOSSLESS_ONLY" in p for p in probs), probs)

    def test_callsite_in_block_comment_fires(self):
        # The F48 class through block comments: the first strip was `//`-only,
        # so a call site moved into /* */ still matched every guard regex.
        src = self._real_comp.replace(
            'if (NEVER_COMPRESS.has(tool)) return null;',
            '/* if (NEVER_COMPRESS.has(tool)) return null; */', 1)
        probs = self._probs(src)
        self.assertTrue(any("return null" in p for p in probs), probs)

    def test_callsite_in_trailing_line_comment_fires(self):
        # F48 class through a trailing // comment: delete the real call site and
        # relocate its text into a trailing comment on a dead line.
        src = self._real_comp.replace(
            'if (NEVER_COMPRESS.has(tool)) return null;',
            'const _x = 1; // NEVER_COMPRESS.has(tool)) return null;', 1)
        probs = self._probs(src)
        self.assertTrue(any("return null" in p for p in probs), probs)

    def test_never_compress_tool_in_elidable_fires(self):
        # ELIDABLE decides what gets elided; the first draft never checked it,
        # so a never-compress tool could be added to it.
        src = self._real_comp.replace(
            '"Bash", "WebFetch", "WebSearch", "Grep", "Glob"',
            '"Bash", "WebFetch", "WebSearch", "Grep", "Glob", "Read"', 1)
        probs = self._probs(src)
        self.assertTrue(any("ELIDABLE" in p for p in probs), probs)

    def test_elidable_mutated_after_the_literal_fires(self):
        """A Set literal is not a Set's contents: `ELIDABLE.add("Read")` puts a
        never-compress tool in the allowlist while every literal pin above
        stays green. Measured 2026-08-25 — the 90-case replay suite missed it
        too, and the compressor is the only component that rewrites what the
        model reads."""
        src = self._real_comp + '\nELIDABLE.add("Read");\n'
        probs = self._probs(src)
        self.assertTrue(any("mutates the set" in p for p in probs), probs)

    def test_never_compress_call_site_in_dead_branch_fires(self):
        """`if (false) if (NEVER_COMPRESS.has(tool)) return null;` — declared,
        present, unreachable. The unanchored search accepted it."""
        src = self._real_comp.replace(
            "if (NEVER_COMPRESS.has(tool)) return null;",
            "if (false) if (NEVER_COMPRESS.has(tool)) return null;", 1)
        probs = self._probs(src)
        self.assertTrue(any("head of its own" in p for p in probs), probs)

    def test_multiline_dead_branch_around_a_guard_fires(self):
        """The anchor rejected only the ONE-LINE `if (false) if (…)`. Wrapping
        the same call site in a multiline `if (false) { … }` left every guard
        declared, matched, and unreachable (Copilot, PR #87) — so reachability
        is now brace-depth against the anchor, which a substring cannot see."""
        src = self._real_comp.replace(
            "    if (NEVER_COMPRESS.has(tool)) return null;",
            "    if (false) {\n    if (NEVER_COMPRESS.has(tool)) return null;\n    }", 1)
        probs = self._probs(src)
        self.assertTrue(any("brace depth" in p for p in probs), probs)

    def test_multiline_dead_branch_around_the_carveout_fires(self):
        """Same shape on the I2 carve-out: the ledger exemption is what keeps
        the evidence gate's own output out of the compressor."""
        src = self._real_comp.replace(
            "    if (LEDGER_PATHS.some((p) => cmd.includes(p))) return null;",
            "    if (false) {\n    if (LEDGER_PATHS.some((p) => cmd.includes(p))) return null;\n    }", 1)
        probs = self._probs(src)
        self.assertTrue(any("brace depth" in p for p in probs), probs)

    def test_missing_reachability_anchor_reports(self):
        """If the anchor line is renamed, the check can prove nothing — it must
        say so rather than silently passing every guard."""
        src = self._real_comp.replace("const tool = payload.tool_name", "const t2 = payload.tool_name", 1)
        probs = self._probs(src)
        self.assertTrue(any("no anchor" in p for p in probs), probs)

    def test_array_length_write_fires(self):
        """`GATE_CLIS.length = 0` empties the carve-out while the literal and
        the `.some()` call site stay green (Copilot, PR #87)."""
        probs = self._probs(self._real_comp + "\nGATE_CLIS.length = 0;\n")
        self.assertTrue(any("writes into the array" in p for p in probs), probs)

    def test_array_indexed_write_fires(self):
        probs = self._probs(self._real_comp + '\nLEDGER_PATHS[0] = "nope";\n')
        self.assertTrue(any("writes into the array" in p for p in probs), probs)

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
        # Drop scripts/statusline.sh from the literal — the F66 amendment.
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

    def _gut(self, first_line):
        # Insert a control-flow line as the FIRST body line of matches_protected,
        # leaving every pinned literal in place below it.
        src, n = re.subn(r"^(matches_protected\(\)\s*\{[^\n]*\n)",
                         lambda m: m.group(1) + first_line + "\n", self._real,
                         count=1, flags=re.M)
        self.assertEqual(n, 1, "matches_protected head moved")
        return src

    def test_early_return_gutting_fires_when_EXECUTED(self):
        # audit F140 (2026-09-02): the exact escape F129's comment names —
        # `matches_protected` gutted to `return 1` with its body intact —
        # shipped "all contracts hold": both F129 pins are substring tests on
        # the body and an early return is invisible to them (pin-auditor,
        # re-run by hand). The pin now RUNS the shipped matcher.
        probs = self._probs(self._gut("  return 1"))
        self.assertTrue(any("does not MATCH" in p and "executed" in p for p in probs), probs)

    def test_match_everything_fires_on_the_unprotected_probe(self):
        # The other polarity: a matcher that returns 0 for everything makes
        # every claimed path a trespass — the unprotected probe must fire.
        probs = self._probs(self._gut("  return 0"))
        self.assertTrue(any("MATCHES 'src/app.py'" in p for p in probs), probs)

    def test_callsite_neutered_fires(self):
        # The literal is declared but matches_protected isn't applied to $p
        # (F30 call-site half); replace the call site with `false`.
        src = self._real.replace('if matches_protected "$p"; then',
                                 'if false; then', 1)
        self.assertTrue(any("not applied" in p for p in self._probs(src)),
                        self._probs(src))

    def test_callsite_renamed_fires(self):
        # Rename the matcher: the literal stays but nothing calls it.
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
        # A reshape the regex can't read (array form) must be reported, not
        # silently accepted.
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
        # The drift coming back: a writer declares its own _OPS_TOOLS beside the
        # source line, shadowing the manifest (CR4).
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
        # Sourcing the manifest but looping a hand-written list: two lists (F30).
        src = self._real_init.replace("for tool in $_OPS_TOOLS",
                                      "for tool in ops-verdict.sh ops-task.sh", 1)
        self.assertNotEqual(src, self._real_init)
        write(self.dir / "scripts" / "ops-init.sh", src)
        self.assertTrue(any("does not iterate $_OPS_TOOLS" in p
                            for p in self._probs()), self._probs())

    def test_extra_word_grafted_onto_ops_tools_fires(self):
        # audit F130: the unanchored regex accepted `for tool in $_OPS_TOOLS
        # statusline.sh; do` — a second word-list grafted onto the manifest's,
        # the inline-list drift wearing the manifest as a prefix. Nothing may
        # sit between the variable and `; do`.
        src = self._real_init.replace(
            "for tool in $_OPS_TOOLS; do",
            "for tool in $_OPS_TOOLS statusline.sh; do", 1)
        self.assertNotEqual(src, self._real_init)
        write(self.dir / "scripts" / "ops-init.sh", src)
        self.assertTrue(any("does not iterate $_OPS_TOOLS alone" in p
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

    def test_removing_the_third_state_flag_fires(self):
        # The escape this pin was written against: F119 checked `cat`'s exit
        # status but the flag set stayed at two, so a SUCCEEDED backup with a
        # FAILED write reported neither MIGRATED nor REFUSED. Measured
        # 2026-08-31 on a 0444 .gitignore: hook rc 0, no gitignore line at all.
        src = self._real_ssh.replace("_gi_write_failed=1", "true", 1)
        src = src.replace("_gi_write_failed=1", "true")
        self.assertNotIn("_gi_write_failed=1", src)
        write(self.dir / "scripts" / "ops-sessionstart-hook.sh", src)
        probs = self._probs()
        self.assertTrue(any("SUCCEEDED backup with a FAILED write" in p
                            for p in probs), probs)

    def test_setting_the_flag_without_reporting_it_fires(self):
        # SET and REPORT are two claims. A flag assigned and never read is the
        # exact silence the third state was found in, and is the shape a
        # narrower pin (assignment only) would ship green.
        src = self._real_ssh.replace('if [ "$_gi_write_failed" = 1 ]; then',
                                     'if [ "$_gi_write_failed" = 999 ]; then', 1)
        self.assertNotEqual(src, self._real_ssh)
        write(self.dir / "scripts" / "ops-sessionstart-hook.sh", src)
        probs = self._probs()
        self.assertTrue(any("never REPORTED" in p for p in probs), probs)

    def test_dropping_the_bare_star_fires(self):
        # The `*` is what makes this an ALLOWLIST; drop it and the file inverts
        # to a v1 blocklist, shipping bin/, pending/, .lock/ and every compressor
        # spill TRACKED. Both writers are mutated independently.
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
        # Without the marker neither writer can detect a v1 file, so a blocklist
        # is appended to instead of replaced.
        write(self.dir / "scripts" / "ops-init.sh",
              self._real_init.replace("# cc-operator gitignore v2 (allowlist)", "# v2", 1))
        self.assertTrue(any("v2 gitignore marker" in p for p in self._probs()),
                        self._probs())

    def test_losing_EVERY_marker_grep_fires(self):
        # EMIT and DETECT are two claims: the heredoc body contains the marker,
        # so a substring test passes even with the migration grep deleted, and
        # every existing v1 project silently stops being detected.
        #
        # This case removes EVERY marker grep from a writer — the blunt end of
        # the range. It used to be named for the DETECTION grep and could not
        # actually isolate one: the hook's two greps carry identical text, so a
        # single-occurrence mutation left the confirmation grep satisfying the
        # pin, and the mutation had to be widened to both (2026-08-31). #102
        # made the pin target-aware, so each grep is now knocked out on its own
        # in the two cases below; this one keeps the coarse mutation, which is
        # still a distinct claim (a writer with no marker read at all).
        for name, real, detect, replacement in (
                ("ops-init.sh", self._real_init,
                 'elif ! grep -qF "$_GI_MARK" "$OPDIR/.gitignore" 2>/dev/null; then',
                 'elif false; then'),
                # the anchor is the grep PREFIX shared by both hook greps;
                # `false` ignores the dangling path argument.
                ("ops-sessionstart-hook.sh", self._real_ssh,
                 "grep -qF '# cc-operator gitignore v2 (allowlist)'",
                 "false")):
            with self.subTest(writer=name):
                self.assertIn(detect, real, f"{name}: detection anchor moved")
                write(self.dir / "scripts" / name, real.replace(detect, replacement))
                probs = self._probs()
                self.assertTrue(any("never greps for it on the LIVE" in p
                                    for p in probs), probs)
                write(self.dir / "scripts" / name, real)
        self.assertEqual(self._probs(), [])

    def test_removing_only_the_DETECTION_grep_fires(self):
        # #102, and the reason the case above had to knock out BOTH greps: the
        # hook carries two greps for the same marker, differing only in their
        # TARGET — detection reads the live `$_gi`, confirmation reads
        # `$_gi.v2.tmp`. The old pattern matched either, so this mutation —
        # which is the one that actually breaks migration, since without
        # detection a v1 blocklist is never replaced at all — reported green.
        # The confirmation grep is left INTACT on purpose: that is precisely
        # the shape that satisfied the old pin.
        detect = ("if [ -f \"$_gi\" ] && ! grep -qF "
                  "'# cc-operator gitignore v2 (allowlist)' \"$_gi\" 2>/dev/null; then")
        self.assertIn(detect, self._real_ssh, "detection anchor moved")
        mutated = self._real_ssh.replace(detect, 'if [ -f "$_gi" ] && false; then', 1)
        # Control on the mutation itself: the confirmation grep must survive it,
        # or this is just the both-greps mutation the case above already runs.
        self.assertIn("grep -qF '# cc-operator gitignore v2 (allowlist)' "
                      "\"$_gi.v2.tmp\"", mutated)
        write(self.dir / "scripts" / "ops-sessionstart-hook.sh", mutated)
        probs = self._probs()
        self.assertTrue(any("never greps for it on the LIVE" in p for p in probs),
                        probs)
        write(self.dir / "scripts" / "ops-sessionstart-hook.sh", self._real_ssh)
        self.assertEqual(self._probs(), [])

    def test_removing_only_the_CONFIRMATION_grep_fires(self):
        # The other half of the same asymmetry (#102). Detection stays intact:
        # a pin that cannot tell the two apart is satisfied by whichever
        # survives, in either direction.
        confirm = ("    if grep -qF '# cc-operator gitignore v2 (allowlist)' "
                   "\"$_gi.v2.tmp\" 2>/dev/null \\\n")
        self.assertIn(confirm, self._real_ssh, "confirmation anchor moved")
        mutated = self._real_ssh.replace(confirm, "    if true \\\n", 1)
        self.assertIn("grep -qF '# cc-operator gitignore v2 (allowlist)' \"$_gi\"",
                      mutated, "detection must survive this mutation")
        write(self.dir / "scripts" / "ops-sessionstart-hook.sh", mutated)
        probs = self._probs()
        self.assertTrue(any("confirmed by grepping the marker in the `.v2.tmp`" in p
                            for p in probs), probs)
        write(self.dir / "scripts" / "ops-sessionstart-hook.sh", self._real_ssh)
        self.assertEqual(self._probs(), [])

    def _non_atomic_write(self, reword_notice):
        # The two-place mutation from the PR #104 review: drop the temp file
        # ENTIRELY (heredoc straight onto the live path — the pre-0.11.4 F119
        # shape), keeping the write-failed flag reachable so the third-state
        # pins stay satisfied. `reword_notice` additionally removes the ONE
        # remaining mention of `.gitignore.v2.tmp`, which lives in user-facing
        # prose, not code.
        src = self._real_ssh
        start = src.index('  elif [ -L "$_gi.v2.tmp" ]')
        end = src.index('    _gi_write_failed=1\n  fi\n', start) + len('    _gi_write_failed=1\n  fi\n')
        block = src[start:end]
        heredoc = block[block.index("<<'EOF'"):block.index("EOF\n  then") + 4]
        mut = ('  elif cat > "$_gi" 2>/dev/null ' + heredoc +
               '\n  then\n    _gi_migrated=1\n  else\n    _gi_write_failed=1\n  fi\n')
        src = src[:start] + mut + src[end:]
        if reword_notice:
            src = src.replace(
                "or something that is not a regular file at .operator/.gitignore.v2.tmp)",
                "or something that is not a regular file at .operator/.gitignore)")
            self.assertNotIn(".v2.tmp", src, "the mutation must leave NO trace of the temp")
        return src

    def test_a_non_atomic_write_fires_even_with_the_notice_reworded(self):
        # Measured on the 0.11.5 tree (PR #104 review): with the temp removed
        # from the CODE the confirmation pin still fired — but only because the
        # notice text mentioned `.gitignore.v2.tmp` and the pin was gated on
        # `".v2.tmp" in text`. Rewording that one prose line made the validator
        # report "all contracts hold" over a non-atomic write. The atomic pin
        # keys on the `mv -f` itself, so it fires on both shapes.
        for reword in (False, True):
            with self.subTest(notice_reworded=reword):
                write(self.dir / "scripts" / "ops-sessionstart-hook.sh",
                      self._non_atomic_write(reword))
                probs = self._probs()
                self.assertTrue(any("not ATOMIC" in p for p in probs), probs)
                # …and the confirmation pin is UNCONDITIONAL now: it fires too.
                self.assertTrue(any("confirmed by grepping the marker in the `.v2.tmp`" in p
                                    for p in probs), probs)
        write(self.dir / "scripts" / "ops-sessionstart-hook.sh", self._real_ssh)
        self.assertEqual(self._probs(), [])

    def test_a_non_atomic_INIT_write_fires(self):
        # audit F137 (2026-09-02): the atomic pin above covered the HOOK only.
        # Reverting ops-init's _gi_write to the pre-review shape (heredoc
        # straight onto the live file, no temp, no mv) reported "all contracts
        # hold" — measured on a scratch copy of 0.11.5. Both writers were made
        # atomic in the same review; only one got the pin.
        src = self._real_init.replace(
            'cat > "$OPDIR/.gitignore.v2.tmp" <<EOF', 'cat > "$OPDIR/.gitignore" <<EOF', 1)
        src = src.replace('  mv -f "$OPDIR/.gitignore.v2.tmp" "$OPDIR/.gitignore"\n', '', 1)
        self.assertNotEqual(src, self._real_init, "init anchors moved")
        self.assertNotIn('mv -f "$OPDIR/.gitignore.v2.tmp"', src)
        write(self.dir / "scripts" / "ops-init.sh", src)
        probs = self._probs()
        self.assertTrue(any("ops-init.sh" in p and "not ATOMIC" in p for p in probs), probs)
        write(self.dir / "scripts" / "ops-init.sh", self._real_init)
        self.assertEqual(self._probs(), [])

    def test_the_atomic_pin_is_not_satisfied_by_a_non_temp_mv(self):
        # Control on the pin's shape: an `mv -f` from somewhere ELSE onto the
        # live path is not the same-dir temp swap. The pin must read the temp
        # name, not just "an mv exists".
        src = self._real_ssh.replace('mv -f "$_gi.v2.tmp" "$_gi"', 'mv -f "$_gi.new" "$_gi"', 1)
        self.assertNotEqual(src, self._real_ssh, "mv anchor moved")
        write(self.dir / "scripts" / "ops-sessionstart-hook.sh", src)
        probs = self._probs()
        self.assertTrue(any("not ATOMIC" in p for p in probs), probs)
        write(self.dir / "scripts" / "ops-sessionstart-hook.sh", self._real_ssh)
        self.assertEqual(self._probs(), [])

    def test_migration_without_a_tested_backup_fires(self):
        # The write must be reachable only through a successful backup — the
        # shipped shape overwrote unconditionally on a failed backup (2026-08-12).
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
        # verdicts.d/*.md is what merge=union operates on; un-tracking it breaks
        # the clean-merge property the fragment scheme exists for.
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

    # audit F136 (2026-09-02): the four `*__<id>` lookups. (script, function or
    # None for the ops-task dup loop, the exact filter line the pin reads.)
    TASK_HALF_SITES = (
        ("ops-task.sh", "sentinel_for",
         '    _n="${_f##*/}"; [ "${_n#*__}" = "$_t" ] || continue\n'),
        ("ops-verdict.sh", "sentinel_path",
         '    _n="${_f##*/}"; [ "${_n#*__}" = "$_t" ] || continue\n'),
        ("ops-adopt.sh", "sentinel_path",
         '    _n="${_f##*/}"; [ "${_n#*__}" = "$_t" ] || continue\n'),
        ("ops-task.sh", None,
         '      _dn="${_dup##*/}"; [ "${_dn#*__}" = "$ID" ] || continue\n'),
    )

    def test_a_redefined_reader_parser_in_the_lib_is_reported(self):
        # audit F143 (2026-09-02): a second sentinel_owner_of_name() appended
        # to lib/partition.sh (bash resolves the LAST — no reject set at all)
        # reported nothing; the reader-arm pin's `pass` claimed another site
        # reports it, and none did for the lib. The bash suite caught it (26
        # red), the validator said "all contracts hold".
        self._install_real()
        lib = self.dir / "scripts" / "lib" / "partition.sh"
        lib.write_text(lib.read_text(encoding="utf-8") +
                       "\nsentinel_owner_of_name() { printf '%s\\n' \"${1%%__*}\"; }\n",
                       encoding="utf-8")
        probs = self._probs()
        self.assertTrue(any("lib/partition.sh" in q and "sentinel_owner_of_name() is defined 2 times" in q
                            for q in probs), probs)

    def test_dropping_the_task_half_filter_from_any_lookup_fires(self):
        # The glob `*__<id>` lets `*` span a `__`, so a planted `A__B__C`
        # resolved as task `C` at every CLI while the hook called it MALFORMED
        # (audit F136): "already open" for a task never opened, and ops-adopt
        # RENAMING the malformed file into a well-formed one. The filter is a
        # guard like any other — one site without it is the drift that ships
        # green, so each of the four is knocked out on its own.
        for script, fn, needle in self.TASK_HALF_SITES:
            with self.subTest(script=script, site=fn or "dup-loop"):
                self._install_real()
                path = self.dir / "scripts" / script
                src = path.read_text(encoding="utf-8")
                self.assertIn(needle, src, f"{script}: filter anchor moved")
                write(path, src.replace(needle, "", 1))
                probs = self._probs()
                self.assertTrue(any(script in q and "task half" in q for q in probs), probs)
                # control: the shipped tree is clean again
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
        # The helper itself, directly: a file whose only mention is a comment
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


class AuditPinRemediationTest(unittest.TestCase):
    """Audit F126-F129 (2026-08-31): four pins confirmed VACUOUS by running
    their mutations against the shipped validator — each stayed green while
    the guarded behavior was gone (raw-text searches satisfied by comments or
    sibling mentions; presence pins blind to a neutered effect). Each case
    re-runs the exact escape against the REAL shipped scripts and asserts the
    fixed check fires; the controls are the unmutated real scripts staying
    clean under the same check.
    """

    def setUp(self):
        self.dir = pathlib.Path(tempfile.mkdtemp())
        make_good_tree(self.dir)
        self.real = ROOT / "scripts"

    def tearDown(self):
        shutil.rmtree(self.dir, ignore_errors=True)

    def _install(self, *names):
        for n in names:
            dest = self.dir / "scripts" / n
            dest.parent.mkdir(parents=True, exist_ok=True)
            write(dest, (self.real / n).read_text(encoding="utf-8"))

    def _mutate(self, name, old, new):
        p = self.dir / "scripts" / name
        text = p.read_text(encoding="utf-8")
        self.assertIn(old, text, f"{name}: mutation anchor moved — update it")
        write(p, text.replace(old, new, 1))

    def _run(self, check):
        probs = []
        check(self.dir, probs)
        return probs

    # --- F126: the partition-source pin was satisfied by a MENTION ---------

    def test_f126_consumer_mentioning_not_sourcing_fires(self):
        # audit F126: `"partition.sh" in s` accepted a comment or an echo
        # naming the file, so this exact mutation shipped green while the
        # consumer ran without the partition (sentinel ownership AND the
        # deviation gate) at all. Both consumers, each mutation-checked.
        for name in ("ops-stop-hook.sh", "statusline.sh"):
            with self.subTest(consumer=name):
                self._install(name, "lib/partition.sh", "ops-verdict.sh")
                self._mutate(name, '. "$_libdir/partition.sh"',
                             'echo "partition.sh unavailable" >/dev/null')
                probs = self._run(vp.check_decisions_schema)
                self.assertTrue(
                    any(f"scripts/{name}" in q
                        and "SOURCE lib/partition.sh" in q for q in probs),
                    f"{name}: source line replaced by an echo and "
                    f"check_decisions_schema stayed silent — {probs}")

    def test_f126_f127_control_real_scripts_are_clean(self):
        self._install("ops-stop-hook.sh", "statusline.sh", "ops-verdict.sh",
                      "lib/partition.sh")
        self.assertEqual(self._run(vp.check_decisions_schema), [])

    # --- F127: gated-kind / HANDOFF-MARK pins satisfied by comments --------

    def test_f127_gated_arm_shrunk_with_enum_in_comment_fires(self):
        # audit F127: shrink the shared scan's case arm to DEVIATION) while
        # the full enum survives in a whole-line comment — the raw-text pin
        # accepted the comment while two kinds silently stopped gating.
        self._install("lib/partition.sh")
        self._mutate("lib/partition.sh",
                     "DEVIATION|ESCALATION|GATE-EXCEPTION)",
                     "# gated set was: DEVIATION|ESCALATION|GATE-EXCEPTION\n"
                     "      DEVIATION)")
        probs = self._run(vp.check_decisions_schema)
        self.assertTrue(any("does not count the gated kinds" in q
                            for q in probs), probs)

    def test_f127_handoff_mark_printf_typo_fires(self):
        # audit F127 (writer half): typo the printf's marker while comments
        # AND the check_owner_name die message keep "HANDOFF-MARK" in the
        # file — a mention is not an emit.
        self._install("ops-verdict.sh")
        self._mutate("ops-verdict.sh",
                     "HANDOFF-MARK | [sid:", "HANDOFF-MRK | [sid:")
        leftover = (self.dir / "scripts" / "ops-verdict.sh").read_text(
            encoding="utf-8")
        self.assertIn("HANDOFF-MARK", leftover,
                      "mutation should leave mentions behind, or this case "
                      "no longer tests mention-blindness")
        probs = self._run(vp.check_decisions_schema)
        self.assertTrue(any("ops-verdict.sh" in q and "HANDOFF-MARK" in q
                            for q in probs), probs)

    # --- F128: guard presence pinned, guard EFFECT not ---------------------

    _GUARD_SCRIPTS = ("ops-task.sh", "ops-verdict.sh", "ops-adopt.sh",
                      "statusline.sh", "lib/partition.sh")

    def test_f128_check_owner_name_gutted_fires(self):
        # audit F128: `check_owner_name() { :; }` keeps every presence pin
        # green (the function exists) while the whitespace arm and the #89
        # metacharacter arm are gone — a literal $S then reads as a valid
        # FOREIGN session at every reader.
        self._install(*self._GUARD_SCRIPTS)
        p = self.dir / "scripts" / "ops-task.sh"
        text = p.read_text(encoding="utf-8")
        mutated = re.sub(r"check_owner_name\(\) \{.*?\n\}",
                         "check_owner_name() { :; }", text,
                         count=1, flags=re.S)
        self.assertNotEqual(mutated, text, "gut mutation did not land")
        write(p, mutated)
        probs = self._run(vp.check_guard_parity)
        self.assertTrue(any("ops-task.sh" in q and "*[[:space:]]*" in q
                            for q in probs), probs)
        self.assertTrue(any("ops-task.sh" in q and "#89" in q
                            for q in probs), probs)

    def test_f128_leading_dot_arm_neutered_fires(self):
        # audit F128: the `.*)` presence pin is satisfied by a `.*) : ;;` arm
        # that waves the dotfile through — the gate then never sees the task.
        self._install(*self._GUARD_SCRIPTS)
        self._mutate("ops-task.sh",
                     '.*) die "$1 must not start with \'.\' — a dotfile '
                     'sentinel is invisible to the Stop hook\'s glob" ;;',
                     ".*) : ;;")
        probs = self._run(vp.check_guard_parity)
        self.assertTrue(any("ops-task.sh" in q and "does not invoke die" in q
                            for q in probs), probs)

    def test_f128_control_real_clis_are_clean(self):
        self._install(*self._GUARD_SCRIPTS)
        self.assertEqual(self._run(vp.check_guard_parity), [])

    # --- F128 reader/migration half (Copilot review on PR #97): the arm
    # belongs at all SIX sites — the writer pins alone left the reader
    # parsers and the SessionStart migration unpinned, recreating the exact
    # measured bypass (a planted `$S__task` read as a valid foreign owner,
    # Stop rc 0 on a real open task).

    _READER_ARM = "*'$'* | *'`'* | *\"'\"* | *'\"'* | *\\\\*) printf '\\n'; return 0 ;;"

    def test_f128_reader_metachar_arm_removed_fires(self):
        for name in ("lib/partition.sh", "ops-verdict.sh"):
            with self.subTest(reader=name):
                self._install(*self._GUARD_SCRIPTS)
                # the READER arm (degrade-to-unowned), never the writer's die
                # arm — ops-verdict.sh carries both shapes.
                self._mutate(name, self._READER_ARM, "")
                probs = self._run(vp.check_guard_parity)
                self.assertTrue(
                    any(name in q and "degrading to unowned" in q
                        for q in probs),
                    f"{name}: reader metachar arm removed and "
                    f"check_guard_parity stayed silent — {probs}")

    def test_f128_migration_metachar_arm_removed_fires(self):
        self._install(*self._GUARD_SCRIPTS, "ops-sessionstart-hook.sh")
        self._mutate("ops-sessionstart-hook.sh",
                     "*'$'* | *'`'* | *\"'\"* | *'\"'* | *\\\\*) continue ;;",
                     "")
        probs = self._run(vp.check_guard_parity)
        self.assertTrue(any("ops-sessionstart-hook.sh" in q
                            and "migration" in q for q in probs), probs)

    def test_f128_migration_control_is_clean(self):
        self._install(*self._GUARD_SCRIPTS, "ops-sessionstart-hook.sh")
        self.assertEqual(self._run(vp.check_guard_parity), [])

    def test_partial_metachar_arm_fires_at_every_site(self):
        # Copilot review on PR #97: the arm pins required only the `$`
        # alternative, so a uniform edit dropping backtick/quote/backslash
        # while keeping `*'$'*` stayed green at all six sites. Drop ONLY the
        # backtick alternative (leaving `$` intact) at a writer, a reader,
        # and the migration — each must fire.
        for name in ("ops-task.sh", "lib/partition.sh",
                     "ops-sessionstart-hook.sh"):
            with self.subTest(site=name):
                self._install(*self._GUARD_SCRIPTS, "ops-sessionstart-hook.sh")
                self._mutate(name, "*'$'* | *'`'* | ", "*'$'* | ")
                probs = self._run(vp.check_guard_parity)
                self.assertTrue(
                    any(name in q and ("complete" in q or "all five" in q)
                        for q in probs),
                    f"{name}: backtick alternative dropped with `$` kept and "
                    f"check_guard_parity stayed silent — {probs}")

    # --- source pins are FILENAME-anchored (Copilot review on PR #97):
    # `\S*partition\.sh` was suffix-satisfiable, so sourcing a renamed
    # `fakepartition.sh` kept the validator green with the shared lib gone.

    def test_suffix_named_partition_lib_does_not_satisfy_the_source_pin(self):
        self._install("ops-stop-hook.sh", "statusline.sh", "ops-verdict.sh",
                      "lib/partition.sh")
        self._mutate("ops-stop-hook.sh", '. "$_libdir/partition.sh"',
                     '. "$_libdir/fakepartition.sh"')
        probs = self._run(vp.check_decisions_schema)
        self.assertTrue(any("ops-stop-hook.sh" in q
                            and "SOURCE lib/partition.sh" in q
                            for q in probs), probs)

    def test_suffix_named_autobar_lib_does_not_satisfy_the_source_pin(self):
        self._install("ops-stop-hook.sh", "lib/partition.sh", "lib/autobar.sh")
        self._mutate("ops-stop-hook.sh", '. "$_libdir/autobar.sh"',
                     '. "$_libdir/fakeautobar.sh"')
        probs = self._run(vp.check_autobar)
        self.assertTrue(any("SOURCE lib/autobar.sh" in q for q in probs),
                        probs)

    # --- F129: check_claims never read matches_protected's body ------------

    def test_f129_matcher_gutted_fires(self):
        # audit F129: `matches_protected() { return 1; }` keeps the literal
        # pinned AND the call site applied while nothing ever matches — the
        # gate-trespass check runs and always says clean.
        self._install("ops-claims.sh")
        p = self.dir / "scripts" / "ops-claims.sh"
        text = p.read_text(encoding="utf-8")
        mutated = re.sub(r"matches_protected\(\) \{.*?\n\}",
                         "matches_protected() { return 1; }", text,
                         count=1, flags=re.S)
        self.assertNotEqual(mutated, text, "gut mutation did not land")
        write(p, mutated)
        probs = self._run(vp.check_claims)
        self.assertTrue(any("*/)" in q for q in probs), probs)
        self.assertTrue(any("[[ $p == $pat ]]" in q for q in probs), probs)

    def test_f129_dir_branch_dropped_fires(self):
        # audit F129: drop only the `*/)` prefix branch — every protected
        # DIRECTORY (tests/, hooks/, .operator/bin/, backlog/) silently
        # leaves the set while the glob branch keeps the check looking alive.
        self._install("ops-claims.sh")
        p = self.dir / "scripts" / "ops-claims.sh"
        text = p.read_text(encoding="utf-8")
        mutated = re.sub(r"^\s*\*/\).*\n.*?;;\n", "", text,
                         count=1, flags=re.M)
        self.assertNotEqual(mutated, text, "branch-drop mutation did not land")
        write(p, mutated)
        probs = self._run(vp.check_claims)
        self.assertTrue(any("*/)" in q for q in probs), probs)
        self.assertFalse(any("[[ $p == $pat ]]" in q for q in probs),
                         f"the glob pin misfired on a dir-branch drop: {probs}")

    def test_f129_control_real_claims_is_clean(self):
        self._install("ops-claims.sh")
        self.assertEqual(self._run(vp.check_claims), [])


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

    def _write(self, validate=None, release=None, base=".github"):
        wf = self.dir / base / "workflows"
        wf.mkdir(parents=True, exist_ok=True)
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
        # release.yml legitimately runs more; only the missing direction is a
        # finding.
        self._write(self.VALIDATE,
                    self.RELEASE_FULL + "      - run: python3 scripts/release_gate.py v1\n")
        self.assertEqual(self._probs(), [])

    def test_no_workflows_at_all_is_skipped(self):
        # A plugin tree without CI is not half-configured — the only legitimate
        # skip.
        self.assertEqual(self._probs(), [])

    def test_one_workflow_missing_is_reported(self):
        # Half-configured CI is reported, not skipped.
        self._write(validate=self.VALIDATE)
        probs = self._probs()
        self.assertTrue(any("release.yml is missing" in p for p in probs), probs)

    def test_commented_out_step_does_not_count(self):
        """A YAML comment contains the suite name, and a raw substring test
        accepted it — the tag build reads as gated in a diff and runs nothing
        (audited 2026-08-25)."""
        subset = self.RELEASE_FULL.replace(
            "      - run: node tests/test_workflows.mjs\n",
            "      # - run: node tests/test_workflows.mjs\n")
        self._write(self.VALIDATE, subset)
        probs = self._probs()
        self.assertTrue(any("test_workflows.mjs" in p and "LIVE" in p for p in probs), probs)

    def test_if_false_step_does_not_count(self):
        """Present but skipped is not run — same reading in a diff, same zero
        coverage at the tag."""
        subset = self.RELEASE_FULL.replace(
            "      - run: node tests/test_workflows.mjs\n",
            "      - if: false\n        run: node tests/test_workflows.mjs\n")
        self._write(self.VALIDATE, subset)
        probs = self._probs()
        self.assertTrue(any("test_workflows.mjs" in p and "LIVE" in p for p in probs), probs)

    def test_forgejo_release_is_checked_too(self):
        """`.forgejo/` is the job that actually publishes on this LAN, and the
        check had never looked at it: gutting every suite from the forge
        release job was green. The two forges' files cannot be identical
        (host-qualified `uses:` on Forgejo, which act cannot parse), which is
        why nothing else pins them."""
        self._write(self.VALIDATE, self.RELEASE_FULL)                       # GitHub: fine
        self._write(self.VALIDATE, "jobs:\n  release:\n    steps:\n      - run: true\n",
                    base=".forgejo")
        probs = self._probs()
        self.assertTrue(probs, "the forge release job gates nothing and must be reported")
        self.assertTrue(all(".forgejo" in p for p in probs),
                        f"only the forge job is at fault here; got {probs}")
        self.assertTrue(any("Forgejo" in p for p in probs), probs)

    def test_forgejo_superset_passes(self):
        """CONTROL: a forge job that runs everything is silent — the check must
        not fire merely because a second forge exists."""
        self._write(self.VALIDATE, self.RELEASE_FULL)
        self._write(self.VALIDATE, self.RELEASE_FULL, base=".forgejo")
        self.assertEqual(self._probs(), [])

    def test_job_level_if_false_fires(self):
        """`live()` groups STEPS, so a job-level `if: false` sits outside every
        step and the suites inside a disabled publishing job still counted as
        coverage (Copilot, PR #87)."""
        disabled = self.RELEASE_FULL.replace(
            "jobs:\n  release:\n", "jobs:\n  release:\n    if: false\n")
        self._write(self.VALIDATE, disabled)
        probs = self._probs()
        self.assertTrue(any("job- or workflow-level" in p for p in probs), probs)

    def test_step_level_if_false_is_not_reported_as_job_level(self):
        """CONTROL: a step-level `if:` is legitimate for a conditional step and
        is handled by the grouping — it must not be reported as a disabled job,
        or the message sends a maintainer to the wrong line."""
        subset = self.RELEASE_FULL.replace(
            "      - run: node tests/test_workflows.mjs\n",
            "      - if: false\n        run: node tests/test_workflows.mjs\n")
        self._write(self.VALIDATE, subset)
        probs = self._probs()
        self.assertFalse(any("job- or workflow-level" in p for p in probs), probs)
        self.assertTrue(any("LIVE" in p for p in probs), probs)

    def test_real_workflows_are_covered(self):
        probs = []
        vp.check_release_gates_cover_validate(ROOT, probs)
        self.assertEqual(probs, [])



