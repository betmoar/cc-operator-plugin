#!/usr/bin/env bash
# cc-operator statusline segment — what the Stop hook will do to you, right now.
#
# Renders  op[2]  when this session owns 2 open tasks (red: your stop is
# blocked), and  op[1+2*]  when 1 is yours and 2 belong to other sessions in the
# same tree (the `*` suffix is dim: informational, they will not block you).
# Prints NOTHING (exit 0) outside operator projects, so the bar stays clean
# everywhere else.
#
# Why it re-implements the partition rather than counting files: a raw count of
# .operator/pending/ is a NUMBER THAT LIES. Since 0.4.0 the Stop hook blocks
# only on sentinels this session owns (or that nobody owns) and merely reports
# foreign ones. A bar reading "3 pending" when none of them are yours tells you
# you are stuck when you are free — and the inverse, showing 0 while an unowned
# sentinel silently gates you, is the failure that actually costs a session.
# So this shares the hook's rule: MINE + UNOWNED are blocking, FOREIGN is not.
#
# CONTRACT: never block, never fail loudly. This runs on every statusline
# render (~every 300ms, per Claude Code's 300ms debounce), which makes it the
# hottest reader in the plugin by three orders of magnitude — the Stop hook
# fires once per turn-end. Everything here is a bash builtin plus one optional
# JSON parser; there is no lock, no write, and no `find`.
#
# It is the FOURTH reader of a sentinel (docs/PLAYBOOK.md, "adding a reader of
# a file"), and follows that procedure: the body is untrusted, parsing is
# bounded in BYTES not lines, and a degenerate body degrades to "" = unowned =
# counted as blocking. Fail toward telling you that you are gated.
#
# Standalone use (without cc-status composing the bar):
#   "statusLine": { "type": "command",
#                   "command": "bash ~/.claude/plugins/.../scripts/statusline.sh" }
set -uo pipefail

# --- read stdin; a TTY means "run by hand", not "wait forever" ----------------
# `cat` on a terminal blocks until EOF that never comes. cc-status always pipes,
# but a maintainer testing this by hand would otherwise hang their shell.
#
# Read with the BUILTIN, not `cat`: on a stripped PATH `cat` is not found, and
# this segment renders ~every 300ms — an external dependency in the hot path is
# the same class of hazard the Stop hook avoids for once-per-turn-end. (Caught
# by testing under PATH=/nonexistent, which printed a bash error where a segment
# should be.) `read -r -d ''` slurps to a NUL that never comes, capturing the
# payload whether or not it ends in a newline; a line loop drops a newline-less
# final line, a bug this plugin has already shipped once.
IN=""
[ -t 0 ] || IFS= read -r -d '' IN || true

# --- locate the project -------------------------------------------------------
# Prefer the payload's own view (workspace.project_dir, then cwd) so this agrees
# with the Stop hook, which judges by the cwd IN the payload and never by $PWD.
PROJ=""
SESSION=""
if [ -n "$IN" ]; then
  if command -v jq >/dev/null 2>&1; then
    PROJ="$(printf '%s' "$IN" | jq -r '.workspace.project_dir // .cwd // empty' 2>/dev/null)"
    SESSION="$(printf '%s' "$IN" | jq -r '.session_id // empty' 2>/dev/null)"
  elif command -v python3 >/dev/null 2>&1; then
    # ONE python3 call (its ~30ms startup is charged every 300ms render, so two
    # would be worse), emitting two newline-separated fields consumed by the
    # `read` BUILTIN. Deliberately not `eval` on an assignment string: the
    # payload is attacker-adjacent input, and eval would re-parse it as shell.
    #
    # `-n 4096` is not about this pipe (python3 emits two short lines); it keeps
    # every `read -r` in the plugin uniformly byte-bounded, so
    # validate_plugin.check_reader_bounds needs no exception for "this one reads
    # a pipe, not a file". A guard with a carve-out is a guard the next
    # maintainer learns to argue with. 4096 also caps a pathological path.
    { IFS= read -r -n 4096 PROJ; IFS= read -r -n 4096 SESSION; } < <(printf '%s' "$IN" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    print(); print(); sys.exit(0)
w = d.get("workspace") if isinstance(d.get("workspace"), dict) else {}
p = w.get("project_dir") or d.get("cwd") or ""
s = d.get("session_id") or ""
# newlines would desynchronize the two-line contract; a path or session id
# containing one is unusable to us anyway.
print(str(p).replace("\n", " "))
print(str(s).replace("\n", " "))
' 2>/dev/null) || true
  fi
fi
[ -n "$PROJ" ] || PROJ="${CLAUDE_PROJECT_DIR:-$PWD}"

# --- resolve .operator/ by walking up, exactly like the Stop hook -------------
# Same bounded walk as ops-stop-hook.sh: nearest ancestor holding .operator/,
# stopping at a .git boundary and at /. If the two disagreed about where the
# project is, the bar would describe a different gate than the one that runs
# (audit F01 was precisely that disagreement, in the hook itself).
OPDIR=""
walk="$(cd -P "$PROJ" 2>/dev/null && pwd)" || walk=""
while [ -n "$walk" ]; do
  if [ -d "$walk/.operator" ]; then OPDIR="$walk/.operator"; break; fi
  [ -e "$walk/.git" ] && break
  [ "$walk" = "/" ] && break
  walk="${walk%/*}"; [ -n "$walk" ] || walk="/"
done
[ -n "$OPDIR" ] || exit 0          # not an operator project -> render nothing

# --- read a sentinel's stamped owner (builtins only) --------------------------
# A deliberate copy of ops-stop-hook.sh:sentinel_owner, minus the opened_at field
# the bar has no room for. Sanitizing happens HERE, at the parser, so every
# consumer is covered by construction.
#
# The byte bound matters more here than anywhere else in the plugin: this is the
# only reader that runs on a 300ms timer. `read -r` is bounded by LINES, and one
# newline-less line is a single line — a 256MB merge artifact measured 8.5s in
# the Stop hook, which fires once per turn-end. On this timer it would stall the
# whole bar continuously. `read -r -n 512` stops at 512 chars OR the newline.
# Never `read -N` (capital): it ignores newlines and returned an empty chunk
# here, which would silently make every sentinel parse as unowned.
sentinel_owner() { # sentinel_owner <path> → owner ("" = unowned)
  local line owner="" n=0
  # A symlink is never a sentinel our CLIs wrote (F65): `-f` alone FOLLOWS it,
  # so a planted link would read its target's session_id: and render as
  # foreign. Degrade to unowned → counted as MINE-blocking — the bar mirrors
  # the Stop hook's partition, and the hook blocks on this entry.
  [ ! -L "$1" ] || return 0
  [ -f "$1" ] || return 0
  # A NUL is checked BEFORE the loop: bash cannot hold one in a variable (it
  # drops them silently), so no test on $line can ever see one — the
  # plausible-looking `case "$line" in *$'\0'*)` is vacuously TRUE, because
  # $'\0' is the empty string and the pattern degenerates to `**`. That mistake
  # was written and caught here (2026-08-02). `read -d ''` returns 0 only if it
  # truly reached a NUL. It matters because bash 3.2's `read -n` stops AT a NUL,
  # so a NUL-padded chunk passes the length guard and its tail is matched as a
  # fresh line — smuggling an owner. Degrade to unowned = blocks. (F46)
  # Whole-file NUL probe in a LC_ALL=C subshell (F55): the single-shot form
  # missed a NUL past byte 512, smuggling a foreign owner that flips the bar
  # from blocking to foreign. Bytes for both -n and ${#}, EOF exits non-zero so
  # the trailing partial chunk never false-positives. Mirror of the Stop hook.
  if ! (LC_ALL=C _np=0
        while IFS= read -r -d '' -n 512 _nulprobe; do
          _np=$((_np + 1)); [ "$_np" -le 40 ] || exit 1
          [ "${#_nulprobe}" -eq 512 ] || exit 1
        done < "$1") 2>/dev/null; then
    printf '%s' ""
    return 0
  fi
  while IFS= read -r -n 512 line || [ -n "$line" ]; do
    n=$((n+1)); [ "$n" -le 20 ] || break     # owner is line 1 by construction
    # Cap-filling chunk → truncated mid-line; its tail would be matched as a
    # fresh line and smuggle an owner. Mirrors ops-stop-hook.sh (F45): unset
    # owner = unowned = counted as MINE-blocking, not waved through as foreign.
    [ "${#line}" -lt 512 ] || { owner=""; break; }
    case "$line" in "session_id: "*) owner="${line#session_id: }"; break ;; esac
  done < "$1" 2>/dev/null
  owner="${owner%$'\r'}"                     # a CRLF checkout must not misclassify
  owner="${owner%"${owner##*[![:space:]]}"}"
  # Mirror check_bare_name's rejects across the three CLIs: a value our writers
  # could never have produced is not a claim of ownership. Degrade to "" —
  # unowned, which counts as blocking. Fail toward the honest warning.
  case "$owner" in */* | .* | *"|"* | *[[:space:]]*) owner="" ;; esac
  printf '%s' "$owner"
}

# --- find the session's newest LIVE workflow journal -------------------------
# The harness appends ~/.claude/projects/<dashed-cwd>/<session>/subagents/
# workflows/wf_<runid>/journal.jsonl per run, and never GC's them. We key on
# SESSION alone (survives worktree isolation, where cwd is the worktree but the
# journal sits under the session's project dir), pick the newest journal, and
# call the run live when the newest file in its dir (journal OR an agent
# transcript) changed within LIVE_SEC — a stopped run's whole dir goes quiet,
# while a long dispatch keeps its transcript growing even though the journal
# is silent between events. Builtins/glob + stat only; no find, no lock.
# Prints the journal path, or nothing. Caller treats empty as "no live run".
# mtime <path> → epoch seconds, or 0. Portability trap, hit in CI: `stat -f` on
# GNU coreutils means FILESYSTEM status and takes the format via -c, so
# `stat -f %m FILE` treats BOTH operands as files — `%m` errors (exit 1) while
# FILE prints a filesystem block to STDOUT. In a `A || B` command substitution
# that partial stdout is CONCATENATED with B's output, yielding garbage like
# "  File: …\n1785…" that fails `[ -gt ]` and silently killed the whole segment
# on Linux (same class as F12's `grep -c || echo 0`). Probe the flavor ONCE and
# branch — never let a failing stat's stdout survive into the value.
_STAT_KIND=""
mtime() { # mtime <path> → epoch seconds (0 on any failure)
  local v
  if [ -z "$_STAT_KIND" ]; then
    if v="$(stat -c %Y "$1" 2>/dev/null)" && case "$v" in ''|*[!0-9]*) false ;; *) true ;; esac; then
      _STAT_KIND=gnu
    elif v="$(stat -f %m "$1" 2>/dev/null)" && case "$v" in ''|*[!0-9]*) false ;; *) true ;; esac; then
      _STAT_KIND=bsd
    else
      _STAT_KIND=none
    fi
  fi
  case "$_STAT_KIND" in
    gnu) v="$(stat -c %Y "$1" 2>/dev/null)" ;;
    bsd) v="$(stat -f %m "$1" 2>/dev/null)" ;;
    *)   v="" ;;
  esac
  case "$v" in ''|*[!0-9]*) printf '0' ;; *) printf '%s' "$v" ;; esac
}

glob_newest_live_journal() { # glob_newest_live_journal <session> [live_sec]
  [ -n "$1" ] || return 0
  local live="${2:-90}" newest="" nmtime=0
  shopt -s nullglob
  local j
  for j in "$HOME/.claude/projects"/*/"$1"/subagents/workflows/wf_*/journal.jsonl; do
    [ -f "$j" ] || continue
    local m
    m="$(mtime "$j")"
    [ "$m" -gt "$nmtime" ] || continue
    nmtime="$m"; newest="$j"
  done
  [ -n "$newest" ] || { shopt -u nullglob; return 0; }
  # Liveness: the journal is appended only on DISPATCH events (started/result),
  # so it legitimately goes quiet for the whole duration of a long agent run —
  # minutes, not seconds. The agent-*.jsonl transcripts in the same dir DO grow
  # during a dispatch, so liveness is the max mtime across the journal and its
  # siblings (one extra glob over the single selected dir; selection above
  # stays journal-keyed — a newer run always has a newer journal).
  local a
  for a in "${newest%/journal.jsonl}"/agent-*.jsonl; do
    [ -f "$a" ] || continue
    local am
    am="$(mtime "$a")"
    [ "$am" -gt "$nmtime" ] && nmtime="$am"
  done
  shopt -u nullglob
  local now; now="$(date +%s 2>/dev/null || echo 0)"
  # UNBALANCED journal (more started than result lines) = a dispatch is in
  # flight, and mtime silence proves nothing: agents can flush their transcript
  # in coarse bursts, and a measured live run (2026-08-03, GLM shards) went
  # >110s with the whole dir untouched — the 90s window declared it dead and
  # the segment flapped off and back mid-run. A wrong "gone" is the same lie as
  # a wrong number. So: unbalanced extends the window to STALL_SEC. It cannot
  # replace the mtime check entirely, because errored agents never write a
  # result line (observed same day: both shards died on a rate limit) — an
  # unbalanced journal is also the signature of a run that FAILED and will
  # never balance, so without the backstop it would render forever.
  # Counting uses grep like the caller's done/started count; on a stripped
  # PATH both greps fail the same way and we degrade to the plain 90s window.
  local stall="${STALL_SEC:-900}" ns=0 nr=0
  ns="$(grep -c '"type":"started"' "$newest" 2>/dev/null)" || ns="${ns:-0}"
  nr="$(grep -c '"type":"result"' "$newest" 2>/dev/null)" || nr="${nr:-0}"
  case "$ns$nr" in *[!0-9]*) ns=0; nr=0 ;; esac
  [ "$ns" -gt "$nr" ] && [ "$stall" -gt "$live" ] 2>/dev/null && live="$stall"
  if [ $((now - nmtime)) -le "$live" ]; then printf '%s' "$newest"; fi
}

# --- partition pending sentinels ---------------------------------------------
# Plain glob, not `find`: no PATH dependency, and it matches the hook's own
# enumeration. A dotfile is invisible to both — that is why all three CLIs
# refuse a leading dot in a task id.
MINE=0
FOREIGN=0
shopt -s nullglob
for f in "$OPDIR/pending"/*; do
  [ -f "$f" ] || continue                    # a directory here is not a task
  owner="$(sentinel_owner "$f")"
  if [ -n "$owner" ] && [ -n "$SESSION" ] && [ "$owner" != "$SESSION" ]; then
    FOREIGN=$((FOREIGN + 1))
  else
    MINE=$((MINE + 1))                       # mine, or unowned (blocks everyone)
  fi
done
shopt -u nullglob

# An operator project with nothing open AND no live workflow renders nothing.
# The bar is for states that change what you do next; the defaults are not news.
RED=$'\033[31m'; DIM=$'\033[2m'; RESET=$'\033[0m'

# --- workflow progress (the journal-based ratio, NOT a %) --------------------
# Unlike the op[ segment above (a mirror of the gate), this is the one part of
# the bar that is NOT gate state: it reflects an in-flight workflow run. It is
# observable because the harness appends a per-run journal.jsonl under the
# session's project dir. Two bounded greps give done/started; the ratio is a
# DISPATCHED-WORK ratio, never a completion % (total isn't known until the last
# agent() call — "2/4" can become "2/9", and a % that lies is worse than none,
# the same failure the file header was written to avoid).
#
# Liveness: wf_* dirs are never GC'd, so mtime must be recent (a stopped run's
# journal stops growing). Schema is undocumented harness internals — on ANY
# surprise (missing, unreadable, no started lines) this renders nothing. A wrong
# progress number is worse than no progress number; fail toward silence.
WFSEG=""
if [ -n "$SESSION" ]; then
  WFDIR="$(glob_newest_live_journal "$SESSION" 2>/dev/null || true)"
  if [ -n "$WFDIR" ] && [ -f "$WFDIR" ]; then
    # `grep -c` prints "0" AND exits 1 on zero matches, so `|| echo 0` would
    # capture "0\n0" — an embedded newline that renders a two-line segment and
    # breaks the composed bar (hit live: every run's first phase has done=0).
    # Assignment form keeps the captured stdout and the fallback distinct.
    started="$(grep -c '"type":"started"' "$WFDIR" 2>/dev/null)" || started="${started:-0}"
    done="$(grep -c '"type":"result"' "$WFDIR" 2>/dev/null)" || done="${done:-0}"
    if [ "${started:-0}" -gt 0 ] 2>/dev/null; then
      WFSEG="${DIM}wf ${done}/${started}${RESET}"
    fi
  fi
fi

[ "$MINE" -gt 0 ] || [ "$FOREIGN" -gt 0 ] || [ -n "$WFSEG" ] || exit 0

# Red only when YOUR stop is actually blocked — the one genuinely actionable
# state. Foreign tasks are dim: worth seeing (that visibility is what made the
# original collision diagnosable) but never a call to action. The op[ segment
# renders ONLY when there is a task to count — op[0] is noise, and the original
# rule ("nothing open renders nothing") still holds for the no-task + no-wf case.
if [ "$MINE" -gt 0 ] || [ "$FOREIGN" -gt 0 ]; then
  SEP=""
  OUT="op["
  [ "$MINE" -gt 0 ] && OUT="${OUT}${RED}${MINE}${RESET}" || OUT="${OUT}0"
  [ "$FOREIGN" -gt 0 ] && OUT="${OUT}${DIM}+${FOREIGN}*${RESET}"
  printf '%s]' "$OUT"
  SEP=" "
fi
# `&&` alone would make an empty WFSEG the script's failing last command: the
# op[ segment rendered but the statusline exited 1, and a renderer that fails
# is one cc-status may drop. Explicit `if` keeps the exit status 0 (review
# panel, 2026-08-02 — main exits 0 here, this branch regressed it).
if [ -n "$WFSEG" ]; then
  printf '%s%s' "${SEP:-}" "$WFSEG"
fi
exit 0
