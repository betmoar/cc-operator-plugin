#!/usr/bin/env bash
# ops-sessionstart-hook.sh — tell the operator its own session id.
#
# CLAUDE_SESSION_ID is NOT in the Bash tool env; only hooks receive session_id.
# Everything downstream (sentinel ownership, the mine/foreign partition,
# ops-adopt) keys on `--owner <sid>`, so this injection is the mechanism's root.
#
# Contract: always exit 0, advisory only; silent outside operator projects and
# without a JSON parser.
set -u

input=""
IFS= read -r -d '' input || true

if command -v jq >/dev/null 2>&1; then
  PARSER=jq
elif command -v python3 >/dev/null 2>&1; then
  PARSER=python3
else
  exit 0   # silent: no parser, nothing to say
fi

json_get() { # json_get <field> → value on stdout ("" if absent)
  case "$PARSER" in
    jq)
      printf '%s' "$input" | jq -r --arg k "$1" '.[$k] // empty' 2>/dev/null
      ;;
    python3)
      printf '%s' "$input" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
v = d.get(sys.argv[1], "")
if isinstance(v, bool):
    print("true" if v else "false")
elif v is None:
    print("")
else:
    print(v)
' "$1" 2>/dev/null
      ;;
  esac
}

session="$(json_get session_id)"
[ -n "$session" ] || exit 0

# SessionStart payloads carry cwd; fall back to the hook's own cwd rather than
# going silent — a missing banner costs the whole mechanism.
cwd="$(json_get cwd)"
[ -n "$cwd" ] || cwd="$PWD"

# Everything below operates ON .operator/ — a project without one has nothing
# to upgrade, migrate, or clean.
#
# Resolve the project by WALKING UP from the payload cwd, exactly like the Stop
# hook (audit F101): the exact-match `$cwd/.operator` was the F01 class on this
# hook's side — a session launched in a subdirectory got NO id banner, NO
# legacy-sentinel migration, NO bin/ upgrade and NO ephemera wipes, all
# silently, while the Stop hook from the same cwd walked up and blocked.
# Bounded the same way: a .git boundary (a nested repo is its own project) and
# the filesystem root; `cd -P` resolves symlinks.
_ssroot=""
_sswalk="$(cd -P "$cwd" 2>/dev/null && pwd)" || _sswalk=""
while [ -n "$_sswalk" ]; do
  if [ -d "$_sswalk/.operator" ]; then _ssroot="$_sswalk"; break; fi
  [ -e "$_sswalk/.git" ] && break
  [ "$_sswalk" = "/" ] && break
  _sswalk="${_sswalk%/*}"; [ -n "$_sswalk" ] || _sswalk="/"
done
[ -n "$_ssroot" ] || exit 0
# Every later `$cwd/.operator` reference now points at the resolved project.
cwd="$_ssroot"

# --- legacy sentinel migration (ownership moved into the filename) -----------
# A pre-0.9 sentinel carries session_id in its BODY and reads as UNOWNED
# (blocking — safe, but it strands its owner). Rename what we can read, leave
# what we cannot; ops-adopt.sh remains the deliberate way out. pending/ entries
# are UNTRUSTED: the read is BOUNDED and symlinks are refused BEFORE -f (which
# follows them; a link is never ours — F65).
_MIG_MAX_LINES=20
_MIG_MAX_BYTES=4096
if [ -d "$cwd/.operator/pending" ]; then
  for _s in "$cwd/.operator/pending"/*; do
    [ ! -L "$_s" ] || continue                    # a symlink is never ours (F65)
    [ -f "$_s" ] || continue                      # dirs etc. are not ours
    case "${_s##*/}" in *__*) continue ;; esac    # already migrated
    # byte bound first: a line counter alone reads a single-line file to EOF
    [ "$(wc -c < "$_s" 2>/dev/null || echo 999999)" -le "$_MIG_MAX_BYTES" ] || continue
    _sid=""
    _n=0
    while IFS= read -r _l || [ -n "$_l" ]; do
      _n=$((_n+1)); [ "$_n" -le "$_MIG_MAX_LINES" ] || break
      case "$_l" in session_id:\ *) _sid="${_l#session_id: }"; break ;; esac
    done < "$_s"
    [ -n "$_sid" ] || continue                    # genuinely unowned: leave it
    # the writers' reject-set (check_owner_name) plus `__`: a stamped sid
    # containing it would build a name the writers refuse. The metacharacter
    # arm is #89's, and it is load-bearing HERE for a different reason than at
    # the writers: a body reading `session_id: $S` migrated to `$S__planted`,
    # which both parsers then read as a valid FOREIGN owner — so the open task
    # stopped blocking anyone (measured: Stop rc 0, "planted owned by $S").
    # The writers' guard cannot reach this path; the body is untrusted input.
    case "$_sid" in
      "" | */* | .* | *"|"* | *[[:space:]]* | *[[:cntrl:]]* | *__*) continue ;;
      *'$'* | *'`'* | *"'"* | *'"'* | *\\*) continue ;;
    esac
    mv "$_s" "$cwd/.operator/pending/${_sid}__${_s##*/}" 2>/dev/null || true
  done
fi

# --- automated upgrade path (version-gated) ----------------------------------
# .operator/bin/ holds COPIES of the gate CLIs; without this, a project keeps
# yesterday's CLIs until someone re-runs /cc-operator:start while the charter
# references the new ones. Best-effort: never cost the banner.
case "${BASH_SOURCE[0]}" in
  */*) _ssdir="${BASH_SOURCE[0]%/*}" ;;   # resolve the plugin-root scripts/ dir
  *)   _ssdir="." ;;
esac
_plugin_json="$_ssdir/../.claude-plugin/plugin.json"
_newver=""
if [ -f "$_plugin_json" ]; then
  _newver="$(grep -m1 '"version"' "$_plugin_json" 2>/dev/null \
             | sed 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')"
fi
_stamp="$cwd/.operator/.version"
_oldver=""
[ -f "$_stamp" ] && _oldver="$(cat "$_stamp" 2>/dev/null)"

# The install set: ONE shared manifest (#76 step 3), same file ops-init.sh
# sources (CR4). Missing manifest fails OPEN — skip, warn, retry next session:
# a die here bricks unattended startup; ops-init is the writer that dies loud.
_OPS_TOOLS=""
if [ -f "$_ssdir/ops-install-set.sh" ]; then
  # shellcheck source=/dev/null
  . "$_ssdir/ops-install-set.sh"
fi
if [ -z "$_OPS_TOOLS" ]; then
  echo "cc-operator sessionstart: scripts/ops-install-set.sh missing or empty — skipping the bin/ upgrade this session (installed CLIs left as-is; reinstall the plugin or run /cc-operator:start to repair)" >&2
fi

# Staleness probe (#34): a version-string test alone misses every intra-version
# fix — the charter points at .operator/bin/, so THAT copy is the gate a
# session runs. `-nt` is also true when the destination is ABSENT (the
# never-installed case); mtime beats cmp on this every-session hot path.
#
# #82: a manifest-named CLI with NO shipped file is STALE, not skippable. The
# old `|| continue` made an absent source unobservable here while the copy loop
# below skipped it and still stamped .version — so version == stamp forever and
# the probe, the only retry trigger, never fired. The two halves have to agree:
# whatever the loop cannot copy, this must report.
_bin_stale() {
  local _t
  for _t in $_OPS_TOOLS; do
    [ -f "$_ssdir/$_t" ] || return 0
    [ "$_ssdir/$_t" -nt "$cwd/.operator/bin/$_t" ] && return 0
  done
  return 1
}

# BOTH clauses (#34): version differs OR shipped CLIs newer — the second is
# what makes a hotfix reach the project. `-n "$_OPS_TOOLS"` is load-bearing:
# an empty set would copy NOTHING yet re-stamp, unretried forever.
if [ -n "$_OPS_TOOLS" ] && [ -n "$_newver" ] && { [ "$_newver" != "$_oldver" ] || _bin_stale; }; then
  # mkdir first (else a bin-less project stamps itself current installing
  # nothing); re-stamp ONLY if every copy succeeded, so a partial refresh is
  # retried, never kept as "current" (CR3/H2). ATOMIC REPLACE (F5): temp +
  # same-dir mv swaps the inode, so a bash mid-execution of the OLD file keeps
  # its open fd — an in-place O_TRUNC cp races that reader. chmod before mv;
  # temp removed on any failure.
  _upgrade_ok=1
  if [ -d "$_ssdir" ] && mkdir -p "$cwd/.operator/bin" 2>/dev/null; then
    for _tool in $_OPS_TOOLS; do
      # #82: a manifest-named CLI with no shipped file is a FAILED upgrade, not
      # a skip. The comment below reasoned about an EMPTY set re-stamping
      # unretried and guarded it; an INCOMPLETE one did exactly the same thing
      # through this line, silently — 2 of 3 copied, stamped current, no
      # warning, never retried, because _bin_stale carried the same skip.
      if [ ! -f "$_ssdir/$_tool" ]; then
        _upgrade_ok=0
        echo "operator: warning — $_tool is named by the install set but not shipped; bin/ left partial and NOT stamped current (will retry next session)" >&2
        continue
      fi
      _tmp="$cwd/.operator/bin/.$_tool.tmp.$$"
      if cp "$_ssdir/$_tool" "$_tmp" 2>/dev/null \
         && chmod +x "$_tmp" 2>/dev/null \
         && mv -f "$_tmp" "$cwd/.operator/bin/$_tool" 2>/dev/null; then
        :
      else
        rm -f "$_tmp" 2>/dev/null
        _upgrade_ok=0
        echo "operator: warning — upgrade copy of $_tool failed; will retry next session" >&2
      fi
    done
  else
    _upgrade_ok=0
  fi
  # Re-stamp ONLY if every copy succeeded; a failure leaves the old stamp so
  # the next session retries.
  if [ "$_upgrade_ok" = 1 ]; then
    printf '%s\n' "$_newver" > "$_stamp" 2>/dev/null
  fi
fi

# Compressor ephemera wipe, every fire INCLUDING compact: the dedup marker's
# justification is "already in context", which compaction falsifies. /clear
# rotates the sid, so the whole tree goes, not just this session's. Best-effort.
for _cdir in "$cwd/.operator/.compress-spill" "$cwd/.operator/.compress-state"; do
  [ -d "$_cdir" ] && rm -rf "$_cdir" 2>/dev/null
done

# Auto-arm markers (#85): one file per sid recording "this session was armed",
# so the Stop hook arms ONCE instead of re-arming after every verdict. /clear
# and /compact rotate or reuse the id, and a marker for a session that no
# longer exists would keep a future session with the SAME id from ever arming.
# Wiped on every fire for the same reason as the compressor ephemera above:
# this hook is the only thing that knows a session boundary was crossed.
[ -d "$cwd/.operator/.autobar" ] && rm -rf "$cwd/.operator/.autobar" 2>/dev/null

# Stop-hook own-block markers (#116): the loop guard distinguishes "my own
# continuation" from another hook's by this directory, so a marker for a
# session that is gone must not survive into a future one with the same id
# (same reasoning as .autobar above — one stale marker = the gate stands down
# for one stop, which is the pre-#116 behaviour, but wiped is better).
[ -d "$cwd/.operator/.stopguard" ] && rm -rf "$cwd/.operator/.stopguard" 2>/dev/null

# v1→v2 gitignore migration, every session (this is what carries a project
# that never re-runs /cc-operator:start). The schemes contradict, so REPLACE,
# keeping .gitignore.v1.bak; body pinned identical to ops-init's _gi_write
# (check_gitignore_parity). IT MUST SAY SO (#32): the overwrite is destructive
# and the backup is hidden by the new `*` — the notice goes to
# additionalContext, the hook's one channel the model sees.
_gi="$cwd/.operator/.gitignore"
_gi_migrated=0
_gi_backup_failed=0
_gi_write_failed=0
if [ -f "$_gi" ] && ! grep -qF '# cc-operator gitignore v2 (allowlist)' "$_gi" 2>/dev/null; then
  # BACKUP FIRST, overwrite ONLY on success, set the notice flag only AFTER
  # the replacement — the old order destroyed rules with no backup while
  # reporting success (#32, one layer down). No set -e: a dying hook costs the
  # id injection. Symlink backup path refused: -f follows links, so cp would
  # overwrite the target instead of writing a backup.
  #
  # The replacement is ATOMIC — heredoc into a temp, mv on success (Copilot
  # review on PR #97): a cat that died mid-write (ENOSPC, EIO) left the LIVE
  # .gitignore truncated with no marker and no flag set, so the failure was
  # silent AND the next session's retry copied the truncated file over the
  # good .v1.bak — destroying the recovery copy the notice promises. With the
  # temp+mv the live file is always either the old v1 or the complete v2, so
  # a retry's backup re-copy is the same intact v1. The temp path is refused
  # if anything non-regular sits there (a planted symlink would carry the
  # write elsewhere — the same F65 class as the backup path above).
  if [ -L "$_gi.v1.bak" ] || { [ -e "$_gi.v1.bak" ] && [ ! -f "$_gi.v1.bak" ]; }; then
    _gi_backup_failed=1
  elif ! cp "$_gi" "$_gi.v1.bak" 2>/dev/null; then
    _gi_backup_failed=1
  elif [ -L "$_gi.v2.tmp" ] || { [ -e "$_gi.v2.tmp" ] && [ ! -f "$_gi.v2.tmp" ]; }; then
    _gi_write_failed=1
  elif cat > "$_gi.v2.tmp" 2>/dev/null <<'EOF'
# cc-operator gitignore v2 (allowlist)
# Ignore everything under .operator/ by default, then re-admit the evidence.
# New machine state is ignored automatically — that is the point of the
# inversion; do not add ignore lines here, add allow lines only when a NEW file
# is genuinely evidence a teammate must read.
*
!.gitignore
!.gitattributes
!VERDICTS.md
!DECISIONS.md
!tiers.env
!verdicts.d/
!verdicts.d/*.md
!handoff-*.md
EOF
  then
    # notice flag: only after the replacement happened and the backup exists.
    # The marker grep probes the COMPLETE temp (audit F119: `[ -s ]` was true
    # for a partial write), then the same-dir mv swaps it in atomically.
    if grep -qF '# cc-operator gitignore v2 (allowlist)' "$_gi.v2.tmp" 2>/dev/null \
       && mv -f "$_gi.v2.tmp" "$_gi" 2>/dev/null; then
      _gi_migrated=1
    else
      rm -f "$_gi.v2.tmp" 2>/dev/null
      _gi_write_failed=1
    fi
  else
    # A failed temp write is REPORTED, not silent, and under its OWN flag —
    # the backup-refusal notice would claim the backup could not be written,
    # which is false here (the backup landed; the v2 write did not).
    rm -f "$_gi.v2.tmp" 2>/dev/null
    _gi_write_failed=1
  fi
fi

# ABSOLUTE, single-quoted command paths (audit F102 — the #94 shape): the Bash
# tool's cwd persists across calls, so a session sitting in a subdirectory that
# pastes a relative `.operator/bin/...` command gets file-not-found, and #94's
# field history shows the model then misdiagnoses a PRESENT gate as absent.
# The Stop hook's verdict_cmd_for went absolute+quoted for exactly this;
# the charter stays relative on purpose (committed, machine-portable).
_ss_shq() { printf "'%s'" "${1//\'/\'\\\'\'}"; }
_ss_task="$(_ss_shq "$cwd/.operator/bin/ops-task.sh")"
_ss_verdict="$(_ss_shq "$cwd/.operator/bin/ops-verdict.sh")"
_ss_adopt="$(_ss_shq "$cwd/.operator/bin/ops-adopt.sh")"
ctx="cc-operator: this session's id is ${session}. Pass --owner ${session} when opening or closing tracked tasks — ${_ss_task} <id> --owner ${session}, ${_ss_verdict} <id> ... --owner ${session}. Sentinels you open are then yours alone: the Stop hook blocks only on your own open tasks and reports other sessions' as informational. After a /clear your id changes — run ${_ss_adopt} --owner ${session} <id>... to re-claim tasks you are still working."

# The migration notice (#32): name the backup path — the allowlist hides it
# from a bare `git status`.
if [ "$_gi_migrated" = 1 ]; then
  ctx="$ctx

cc-operator: .operator/.gitignore was MIGRATED from the v1 blocklist to the v2 allowlist this session. The two schemes contradict, so the file was REPLACED, not appended — any rule you added by hand is gone from it. Your previous file is kept at .operator/.gitignore.v1.bak, which the new allowlist itself ignores (\`git status\` will not show it; use \`git status --ignored\`). If it carried a rule you still need, re-add it as an allow line (\`!<path>\`) in the v2 file."
fi

# The refusal is as reportable as the migration — silence is what let the
# destructive variant ship.
if [ "$_gi_backup_failed" = 1 ]; then
  ctx="$ctx

cc-operator: .operator/.gitignore is still the v1 blocklist — migration to the v2 allowlist was REFUSED this session because the backup at .operator/.gitignore.v1.bak could not be written (the directory may be read-only, or something that is not a regular file already sits at that path). Nothing was overwritten. Until this is resolved the project keeps v1 semantics, which track machine state (bin/, pending/, .lock/) by default. Fix the path or the permissions and start a new session."
fi

# A failed v2 WRITE is its own notice (Copilot review on PR #97): the backup
# landed and the live file is untouched, so the backup-refusal wording above
# would be false — and silence here is what let the pre-atomic variant strand
# a truncated live file for the next session's retry to copy over the backup.
if [ "$_gi_write_failed" = 1 ]; then
  ctx="$ctx

cc-operator: .operator/.gitignore is still the v1 blocklist — the v2 allowlist could not be written this session (disk full, I/O error, or something that is not a regular file at .operator/.gitignore.v2.tmp). The v1 file is UNCHANGED and the backup at .operator/.gitignore.v1.bak is intact; the migration retries next session."
fi

if [ "$PARSER" = "jq" ]; then
  jq -n --arg c "$ctx" \
    '{hookSpecificOutput:{hookEventName:"SessionStart", additionalContext:$c}}'
else
  printf '%s' "$ctx" | python3 -c '
import sys, json
print(json.dumps({"hookSpecificOutput": {
    "hookEventName": "SessionStart",
    "additionalContext": sys.stdin.read(),
}}))
'
fi
exit 0
