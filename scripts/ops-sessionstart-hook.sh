#!/usr/bin/env bash
# ops-sessionstart-hook.sh — tell the operator its own session id.
#
# The agent cannot discover this any other way: CLAUDE_SESSION_ID is NOT set in
# the Bash tool environment (probed in the field, 2026-07-25). Only hooks receive
# session_id, via the stdin payload. Everything downstream — sentinel ownership,
# the Stop hook's mine/foreign partition, ops-adopt — depends on the agent being
# able to pass `--owner <sid>`, so this injection is the root of the mechanism.
#
# Contract: always exit 0. This hook is advisory; a failure here must never cost
# a session. Stays silent (no output at all) outside operator projects and when
# no JSON parser is available.
#
# Lives in scripts/ (not hooks/) alongside the other gate scripts; hooks.json
# references it via ${CLAUDE_PLUGIN_ROOT}/scripts/, same as the Stop hook.
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

# Scope to operator projects so this never adds noise elsewhere. SessionStart
# payloads carry cwd; if a future payload omits it, fall back to the hook's own
# cwd rather than going silent — a missing banner costs the whole mechanism.
cwd="$(json_get cwd)"
[ -n "$cwd" ] || cwd="$PWD"

# --- tempdir-ephemera cleanup (runs for EVERY project, even one with no -----
# .operator/). The compressor's containment-(B) falls back to a tempdir root
# keyed by sha256(cwd) precisely when .operator/ is ABSENT (a project that never
# ran /cc-operator:start must not have one materialized in it). That copy is
# session-scoped ephemera that accumulates forever if never wiped — and the
# `.operator/` gate below used to make this wipe unreachable for exactly the
# projects that use the tempdir path. So this runs FIRST, before the gate. The
# in-project .operator/.compress-* wipe stays behind the gate (it needs the
# directory it wipes). Key must match ops-compress.mjs:ephemeralRoot.
_ccdir=""
if command -v shasum >/dev/null 2>&1; then
  _ccdir="$(printf '%s' "$cwd" | shasum -a 256 2>/dev/null | cut -c1-16)"
elif command -v sha256sum >/dev/null 2>&1; then
  _ccdir="$(printf '%s' "$cwd" | sha256sum 2>/dev/null | cut -c1-16)"
fi
if [ -n "$_ccdir" ]; then
  # The shared segment carries the uid and is created 0700 by the compressor:
  # `/tmp` is world-writable on Linux and the key is a plain sha256 of cwd, so a
  # uid-less shared root let another local user read pre-scrub tool output or
  # pre-plant a symlink and capture every later spill. This name MUST match
  # ops-compress.mjs:TMP_ROOT_NAME — the two derive the same path independently.
  # The legacy uid-less root is swept too, so an upgrade does not strand the
  # world-readable spills the old version already wrote.
  _ccuid="$(id -u 2>/dev/null || echo nouid)"
  for _croot in "cc-operator-$_ccuid" "cc-operator"; do
    for _cdir in \
      "${TMPDIR:-/tmp}/$_croot/$_ccdir/.compress-spill" \
      "${TMPDIR:-/tmp}/$_croot/$_ccdir/.compress-state"; do
      # Never follow a symlink planted at these paths.
      [ -d "$_cdir" ] && [ ! -L "$_cdir" ] && rm -rf "$_cdir" 2>/dev/null
    done
  done
fi

# Gate everything that operates ON .operator/ (the banner, the bin/ upgrade, the
# in-project ephemera wipe, the gitignore migration): a project without one has
# nothing to upgrade or migrate. The tempdir wipe above is the exception — it
# serves precisely the projects that fail this gate.
[ -d "$cwd/.operator" ] || exit 0

# --- legacy sentinel migration (ownership moved into the filename) -----------
# A sentinel written before this change carries `session_id: <id>` in its BODY
# and a bare task-id as its NAME, which every reader now interprets as UNOWNED —
# it blocks every session instead of only its owner. That is fail-closed, so the
# gate stays sound either way, but it strands the owner behind a block it cannot
# distinguish from someone else's.
#
# Rename what we can read, leave what we cannot. An unmigrated sentinel keeps the
# unowned (blocking) reading, which is the safe direction, and `ops-adopt.sh`
# remains the deliberate way out.
#
# pending/ entries are UNTRUSTED: this loop reads a body our CLIs have never
# validated, so the read is BOUNDED (a multi-MB newline-less planted file must
# not stall SessionStart behind an unbounded `read`) and symlinks are refused
# BEFORE `-f` (which follows them — a link to a huge regular file reads the
# target; a link is never a sentinel our CLIs wrote, same F65 rule as every
# other reader). PR #77 review (Copilot + test-analyzer), both findings on the
# same ten lines.
_MIG_MAX_LINES=20
_MIG_MAX_BYTES=4096
if [ -d "$cwd/.operator/pending" ]; then
  for _s in "$cwd/.operator/pending"/*; do
    [ ! -L "$_s" ] || continue                    # a symlink is never ours (F65)
    [ -f "$_s" ] || continue                      # dirs etc. are not ours
    case "${_s##*/}" in *__*) continue ;; esac    # already migrated
    # byte bound first: `read` has no total-size cap, a 4 GiB single-line file
    # would be read to its end even under a line counter
    [ "$(wc -c < "$_s" 2>/dev/null || echo 999999)" -le "$_MIG_MAX_BYTES" ] || continue
    _sid=""
    _n=0
    while IFS= read -r _l || [ -n "$_l" ]; do
      _n=$((_n+1)); [ "$_n" -le "$_MIG_MAX_LINES" ] || break
      case "$_l" in session_id:\ *) _sid="${_l#session_id: }"; break ;; esac
    done < "$_s"
    [ -n "$_sid" ] || continue                    # genuinely unowned: leave it
    # the SAME reject-set the writers enforce (check_owner_name) plus the
    # migration's own separators: a `__` in a stamped sid would build the
    # ambiguous name the writers now refuse, and control chars have no honest
    # source in a body our CLIs wrote
    case "$_sid" in
      "" | */* | .* | *"|"* | *[[:space:]]* | *[[:cntrl:]]* | *__* | *.exempt) continue ;;
    esac
    mv "$_s" "$cwd/.operator/pending/${_sid}__${_s##*/}" 2>/dev/null || true
  done
fi

# --- automated upgrade path (version-gated) ----------------------------------
# A target project's .operator/bin/ holds COPIES of the plugin's gate CLIs
# (the model's shell has no ${CLAUDE_PLUGIN_ROOT}), refreshed by ops-init on
# /cc-operator:start. But a project on an OLD operator version keeps its old
# bin/ CLIs until the operator re-runs start — so the new ops-claims.sh, the new
# --mark-handoff, etc. would be command-not-found or missing-feature at the very
# moment the updated plugin's charter references them. SessionStart fires every
# session; this makes the upgrade automatic: if the installed plugin's version
# is newer than the stamp, refresh bin/ once and re-stamp. (User request
# 2026-08-04.)
#
# PLUGIN_ROOT = the hook's own dir's parent (hooks.json invokes this as
# ${CLAUDE_PLUGIN_ROOT}/scripts/ops-sessionstart-hook.sh). plugin.json lives one
# level above scripts/. Best-effort: a failure here must never cost the banner.
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

# The install set, declared once — the loop below and the staleness probe must
# agree, or a CLI is checked for freshness and never copied (or vice versa).
_OPS_TOOLS="ops-verdict.sh ops-task.sh ops-adopt.sh ops-claims.sh ops-backlog.sh"

# Is any installed CLI older than the plugin's copy? A version-string test alone
# is NOT enough, and this is issue #34, measured live by the replay charter on
# 2026-08-12: `.operator/bin/ops-verdict.sh` was byte-identical to a commit two
# ahead of it in the log — every intra-version fix to a gate CLI stayed
# invisible because plugin.json still said 0.7.0 and the stamp already agreed.
# The charter points the model at `.operator/bin/...`, so THAT copy is the gate
# a session actually runs: a stale bin/ means the project runs a fixed CLI's
# broken predecessor while every test in the plugin tree passes.
#
# `-nt` is also true when the destination is ABSENT, which is the "never
# installed" case and equally deserves a copy. Content compare (cmp) would be
# stricter, but mtime is enough here and costs one stat per tool on a hot path
# that runs at every session start.
_bin_stale() {
  local _t
  for _t in $_OPS_TOOLS; do
    [ -f "$_ssdir/$_t" ] || continue
    [ "$_ssdir/$_t" -nt "$cwd/.operator/bin/$_t" ] && return 0
  done
  return 1
}

# Refresh when the version differs (newer, older, or the stamp is absent) OR
# when the shipped CLIs are simply newer than what is installed. The second
# clause is what makes a hotfix — and any development tree, where the version
# legitimately does not move between commits — actually reach the project.
if [ -n "$_newver" ] && { [ "$_newver" != "$_oldver" ] || _bin_stale; }; then
  # Refresh the bin/ CLIs the way ops-init does (always-refresh: generated
  # artifacts tracking the installed plugin version). mkdir the bin/ dir first
  # (ops-init does; without it a project whose .operator/bin was never created
  # stamps itself current while installing nothing). Track whether EVERY copy
  # succeeded and ONLY re-stamp then: a failed/truncated copy (ENOSPC, quota)
  # must leave the OLD stamp so the next session retries — a partial refresh is
  # retried, not silently kept as "current" with truncated CLIs (CR3/H2, code-
  # review 2026-08-04). Best-effort for the banner; the stamp is the contract.
  #
  # ATOMIC REPLACE (F5): each CLI is written to a temp file then `mv`-ed over
  # the target — never an in-place `cp` into `.operator/bin/<tool>`. `mv` swaps
  # the inode, so a bash concurrently mid-execution of the OLD file keeps
  # reading the old inode from its open fd and is not truncated (an in-place
  # O_TRUNC cp races that reader: truncation between LOCK_HELD=1 and the EXIT
  # trap in ops-verdict.sh leaves the lock held with no cleanup). The temp lives
  # in the same .operator/bin/ dir so the rename is same-filesystem; the mode
  # cp produced is preserved because mv keeps the temp's mode, and chmod +x is
  # applied to the temp BEFORE the rename. The temp is removed on any failure so
  # no `.tmp.$$` litter survives a partial refresh.
  _upgrade_ok=1
  if [ -d "$_ssdir" ] && mkdir -p "$cwd/.operator/bin" 2>/dev/null; then
    for _tool in $_OPS_TOOLS; do
      [ -f "$_ssdir/$_tool" ] || continue
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
  # (The compressor-ephemera append that used to sit here is gone with the v2
  # allowlist; the migration below handles a v1 project, and it runs every
  # session rather than only on the upgrade path.)
  # Re-stamp ONLY if every CLI copy succeeded. A failure leaves the old stamp →
  # next session retries. (gitignore-ensure is best-effort and does not gate.)
  if [ "$_upgrade_ok" = 1 ]; then
    printf '%s\n' "$_newver" > "$_stamp" 2>/dev/null
  fi
fi

# Compressor artifact cleanup (spec I2.3 + the dedup state contract). Both are
# session-scoped ephemera, and both MUST be cleared on every SessionStart fire
# INCLUDING `compact`: compaction can prune the prior output from context, and
# "the content is already in context" is the dedup marker's entire
# justification — a stale hash after a compact collapses output the model can no
# longer see. A /clear rotates the session id, so old directories would
# otherwise accumulate forever; the whole tree goes, not just this session's.
# Best-effort by design: a cleanup failure must never cost the session its
# banner, so every branch swallows and continues.
for _cdir in "$cwd/.operator/.compress-spill" "$cwd/.operator/.compress-state"; do
  [ -d "$_cdir" ] && rm -rf "$_cdir" 2>/dev/null
done
# The tempdir-root half of this wipe runs EARLY, before the .operator/ gate —
# see the block above. It serves precisely the projects that fail this gate.

# Migrate a v1 (blocklist) .operator/.gitignore to the v2 allowlist BEFORE the
# compressor can recreate its ephemera this session. ops-init does this too, but
# only on re-init; this runs every session, which is what carries a project that
# never re-runs /cc-operator:start. The two schemes contradict — v1 tracks by
# default, v2 ignores by default — so this REPLACES rather than appends, keeping
# the user's file as .gitignore.v1.bak. Best-effort: a write failure must never
# cost the session its banner. Keep the body identical to ops-init.sh's _gi_write
# (validate_plugin.check_gitignore_parity pins the two equal).
#
# IT MUST SAY SO (issue #32). This overwrites a file the user may have edited,
# and the .v1.bak it leaves is itself hidden by the new bare `*` — so a project
# with a hand-added rule lost it with no message anywhere: stdout carried only
# the SessionStart JSON, and `git status` showed no trace of the backup (it
# appears only under --ignored). ops-init.sh echoes a migration notice for the
# identical destructive write; this path — the one that exists precisely to
# carry projects that never re-run /cc-operator:start — was silent by
# construction. The hook's one channel to the model is additionalContext, so the
# notice goes there rather than to stdout, which Claude Code does not surface.
_gi="$cwd/.operator/.gitignore"
_gi_migrated=0
_gi_backup_failed=0
if [ -f "$_gi" ] && ! grep -qF '# cc-operator gitignore v2 (allowlist)' "$_gi" 2>/dev/null; then
  # BACKUP FIRST, AND ONLY OVERWRITE IF IT SUCCEEDED — and set the notice flag
  # only after the replacement is done. The old order set _gi_migrated=1 up
  # front, copied with errors swallowed, then wrote regardless: with `.operator/`
  # unwritable but `.gitignore` still writable, the user's rules were destroyed,
  # NO backup existed, and the context told the model both had succeeded
  # (measured 2026-08-12). That is issue #32's own failure, one layer down.
  # Never `set -e` here: a hook that dies costs the session its id injection,
  # which is worse than an unmigrated gitignore. Hence explicit branching.
  # A symlink must be refused even when it resolves to a regular file: `-f`
  # follows symlinks, so a symlink-to-regular passed this guard and `cp`
  # then overwrote the link's target instead of a real backup.
  if [ -L "$_gi.v1.bak" ] || { [ -e "$_gi.v1.bak" ] && [ ! -f "$_gi.v1.bak" ]; }; then
    _gi_backup_failed=1
  elif ! cp "$_gi" "$_gi.v1.bak" 2>/dev/null; then
    _gi_backup_failed=1
  else
  cat > "$_gi" <<'EOF' 2>/dev/null
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
!armgate.on
EOF
    # The flag is the NOTICE's trigger, so it is set only here — after the
    # replacement actually happened and the backup already exists.
    [ -s "$_gi" ] && _gi_migrated=1
  fi
fi

ctx="cc-operator: this session's id is ${session}. Pass --owner ${session} when opening or closing tracked tasks — .operator/bin/ops-task.sh <id> --owner ${session}, .operator/bin/ops-verdict.sh <id> ... --owner ${session}. Sentinels you open are then yours alone: the Stop hook blocks only on your own open tasks and reports other sessions' as informational. After a /clear your id changes — run .operator/bin/ops-adopt.sh --owner ${session} <id>... to re-claim tasks you are still working."

# Append the migration notice (#32) — a destructive overwrite the operator must
# be told about, naming the backup path because the new allowlist hides it from
# a bare `git status`.
if [ "$_gi_migrated" = 1 ]; then
  ctx="$ctx

cc-operator: .operator/.gitignore was MIGRATED from the v1 blocklist to the v2 allowlist this session. The two schemes contradict, so the file was REPLACED, not appended — any rule you added by hand is gone from it. Your previous file is kept at .operator/.gitignore.v1.bak, which the new allowlist itself ignores (\`git status\` will not show it; use \`git status --ignored\`). If it carried a rule you still need, re-add it as an allow line (\`!<path>\`) in the v2 file."
fi

# The refusal is as reportable as the migration: a project left on v1 tracks
# machine state by default, and silence here is what let the destructive
# variant of this path go unnoticed in the first place.
if [ "$_gi_backup_failed" = 1 ]; then
  ctx="$ctx

cc-operator: .operator/.gitignore is still the v1 blocklist — migration to the v2 allowlist was REFUSED this session because the backup at .operator/.gitignore.v1.bak could not be written (the directory may be read-only, or something that is not a regular file already sits at that path). Nothing was overwritten. Until this is resolved the project keeps v1 semantics, which track machine state (bin/, pending/, .lock/) by default. Fix the path or the permissions and start a new session."
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
