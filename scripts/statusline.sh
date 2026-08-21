#!/usr/bin/env bash
# cc-operator statusline segment — what the Stop hook will do to you, right now.
#
# Renders  op[2]  when this session owns 2 open tasks (red: your stop is
# blocked), and  op[1+2*]  when 1 is yours and 2 belong to other sessions in the
# same tree (the `*` suffix is dim: informational, they will not block you),
# dev[N] for N unpresented decisions, and a dim wf done/started ratio while a
# workflow run is live. Prints NOTHING (exit 0) outside operator projects, so
# the bar stays clean everywhere else.
#
# The partition (what blocks, what is foreign, what counts as unpresented) is
# NOT re-implemented here: ops-stop-hook.sh and this script source the same
# scripts/lib/partition.sh, so the bar describes the exact gate that runs.
#
# CONTRACT: never block, never fail loudly. This renders on every statusline
# pass (~300ms debounce) — the hottest reader in the plugin. Bash builtins plus
# one optional JSON parser, `tail`/`grep` for the deviation window and wf
# counts; no lock, no write, no find.
#
# Standalone use (without cc-status composing the bar):
#   "statusLine": { "type": "command",
#                   "command": "bash ~/.claude/plugins/.../scripts/statusline.sh" }
set -uo pipefail

# --- read stdin; a TTY means "run by hand", not "wait forever" ----------------
# `cat` on a terminal blocks until EOF that never comes; the BUILTIN read also
# survives a stripped PATH (this renders ~every 300ms — an external in the hot
# path is a hazard the Stop hook avoids for once-per-turn-end).
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
    # ONE python3 call (~30ms startup charged every 300ms), two newline-
    # separated fields consumed by the byte-bounded builtin reads. Never eval
    # on payload-derived text. Newlines in a path/id desynchronize the
    # two-line contract and are unusable here anyway.
    { IFS= read -r -n 4096 PROJ; IFS= read -r -n 4096 SESSION; } < <(printf '%s' "$IN" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    print(); print(); sys.exit(0)
w = d.get("workspace") if isinstance(d.get("workspace"), dict) else {}
p = w.get("project_dir") or d.get("cwd") or ""
s = d.get("session_id") or ""
print(str(p).replace("\n", " "))
print(str(s).replace("\n", " "))
' 2>/dev/null) || true
  fi
fi
[ -n "$PROJ" ] || PROJ="${CLAUDE_PROJECT_DIR:-$PWD}"

# --- resolve .operator/ by walking up, exactly like the Stop hook -------------
OPDIR=""
walk="$(cd -P "$PROJ" 2>/dev/null && pwd)" || walk=""
while [ -n "$walk" ]; do
  if [ -d "$walk/.operator" ]; then OPDIR="$walk/.operator"; break; fi
  [ -e "$walk/.git" ] && break
  [ "$walk" = "/" ] && break
  walk="${walk%/*}"; [ -n "$walk" ] || walk="/"
done
[ -n "$OPDIR" ] || exit 0          # not an operator project -> render nothing

# --- the partition rule, shared with the Stop hook -----------------------------
case "$0" in
  */*) _libdir="${0%/*}/lib" ;;
  *)   _libdir="lib" ;;
esac
# shellcheck source=/dev/null
. "$_libdir/partition.sh"

# --- workflow liveness + progress ---------------------------------------------
# The harness appends ~/.claude/projects/<dashed-cwd>/<session>/subagents/
# workflows/wf_<runid>/journal.jsonl per run and never GC's them. Key on
# SESSION alone (survives worktree isolation), pick the newest journal, and
# call the run live when the newest file in its dir (journal OR an agent
# transcript) changed within the window: a stopped run's dir goes quiet, while
# a long dispatch keeps its transcript growing even though the journal is
# silent between events. The ratio is a DISPATCHED-WORK ratio, never a % —
# total isn't known until the last dispatch, and a % that lies is worse than
# none. Schema is undocumented harness internals: on ANY surprise render
# nothing (fail toward silence).
#
# mtime → epoch seconds, or 0. Probe the stat flavor ONCE per render, in the
# caller's scope (every mtime call site is a subshell whose variables die with
# it): `stat -f %m F || stat -c %Y F` is BANNED here — on GNU, `-f` prints
# filesystem info to stdout before failing, so the fallback CONCATENATES
# garbage (F12 class; killed this segment on Linux once). `/` as the probe
# target: always exists, never mis-detects "none" from a vanished file.
_STAT_KIND=""
stat_probe() { # stat_probe → sets _STAT_KIND once (gnu|bsd|none)
  [ -z "$_STAT_KIND" ] || return 0
  local v
  if v="$(stat -c %Y / 2>/dev/null)" && case "$v" in ''|*[!0-9]*) false ;; *) true ;; esac; then
    _STAT_KIND=gnu
  elif v="$(stat -f %m / 2>/dev/null)" && case "$v" in ''|*[!0-9]*) false ;; *) true ;; esac; then
    _STAT_KIND=bsd
  else
    _STAT_KIND=none
  fi
}
mtime() { # mtime <path> → epoch seconds (0 on any failure)
  local v
  stat_probe                       # no-op when the caller already probed
  case "$_STAT_KIND" in
    gnu) v="$(stat -c %Y "$1" 2>/dev/null)" ;;
    bsd) v="$(stat -f %m "$1" 2>/dev/null)" ;;
    *)   v="" ;;
  esac
  case "$v" in ''|*[!0-9]*) printf '0' ;; *) printf '%s' "$v" ;; esac
}

# STALL_SEC is env-overridable and lands in `[ "$stall" -gt "$live" ]`. A
# non-numeric value makes the test error, the chain short-circuits, and the
# stall window silently never extends — the bug the window exists to fix,
# reintroduced by a typo. Validated HERE, at file scope: the caller wraps the
# glob call in 2>/dev/null, so a warning raised inside would be swallowed.
# Loud is a stderr warning plus the default, never an exit: dying over a
# workflow knob would blank op[ and dev[ too — the parts that gate a session.
STALL_SEC="${STALL_SEC:-900}"
case "$STALL_SEC" in ''|*[!0-9]*) _stall_bad=1 ;; *) [ "$STALL_SEC" -ge 1 ] || _stall_bad=1 ;; esac
if [ -n "${_stall_bad:-}" ]; then
  echo "statusline: STALL_SEC is not a positive integer (got '$STALL_SEC') — using 900" >&2
  STALL_SEC=900
fi

# Prints "<journal-path>\t<started>\t<result>" for a LIVE run, or nothing.
# Counts come back from here because the wf segment needed the identical pair
# of greps over the identical file — computing them twice doubled the render's
# process count for no new information.
glob_newest_live_journal() { # glob_newest_live_journal <session> [live_sec]
  [ -n "$1" ] || return 0
  local live="${2:-90}" newest="" nmtime=0
  stat_probe                       # once per render, not once per $(mtime) call
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
  # Liveness = max mtime across the journal and its sibling agent transcripts:
  # the journal is appended only on DISPATCH events, so it legitimately goes
  # quiet for minutes during a long agent run while the transcripts keep
  # growing. Selection above stays journal-keyed (a newer run always has a
  # newer journal).
  local a
  for a in "${newest%/journal.jsonl}"/agent-*.jsonl; do
    [ -f "$a" ] || continue
    local am
    am="$(mtime "$a")"
    [ "$am" -gt "$nmtime" ] && nmtime="$am"
  done
  shopt -u nullglob
  local now; now="$(date +%s 2>/dev/null || echo 0)"
  # UNBALANCED journal (more started than result lines) = a dispatch in flight,
  # and mtime silence proves nothing: agents flush in coarse bursts (a measured
  # live run went >110s with the dir untouched — the 90s window declared it
  # dead and the segment flapped off mid-run). Unbalanced extends the window
  # to STALL_SEC; it cannot replace the mtime check, because errored agents
  # never write a result line (an unbalanced journal is also a failed run's
  # signature, which would otherwise render forever).
  local stall="$STALL_SEC" ns=0 nr=0
  ns="$(grep -c '"type":"started"' "$newest" 2>/dev/null)" || ns="${ns:-0}"
  nr="$(grep -c '"type":"result"' "$newest" 2>/dev/null)" || nr="${nr:-0}"
  case "$ns$nr" in *[!0-9]*) ns=0; nr=0 ;; esac
  [ "$ns" -gt "$nr" ] && [ "$stall" -gt "$live" ] && live="$stall"
  # Tab-separated; the caller splits on it. A journal path cannot contain a tab.
  if [ $((now - nmtime)) -le "$live" ]; then printf '%s\t%s\t%s' "$newest" "$ns" "$nr"; fi
}

scan_pending "$OPDIR" "$SESSION"

# --- deviations: the tail-window approximation of the shared scan -------------
# The lib's whole-file scan (what the hook gates on) is O(n) in an append-
# forever ledger — measured 0.4s at 3000 lines, blowing the 300ms render
# budget. The bar reads the last ~256 lines and walks them BACKWARD, stopping
# at the first mine-or-unowned mark: O(tail) instead of O(n), the same count
# whenever the active set fits the window, informational-only (fails toward
# silence), while the hook still gates exactly. A NUL inside the window still
# suppresses the count (corrupt tail — fail toward silence).
DEVMINE=0
if [ -f "$OPDIR/DECISIONS.md" ] && [ ! -L "$OPDIR/DECISIONS.md" ]; then
  # Bounded NUL probe over the SAME window the scan reads — not the whole
  # file, which would re-introduce the O(n) cost the tail scan exists to
  # avoid. `tail` runs twice (probe + scan) rather than once into a variable,
  # because bash DROPS NULs from variables — a captured tail makes the probe
  # vacuous.
  if (LC_ALL=C _dp=0
      while IFS= read -r -d '' -n 512 _dprobe; do
        _dp=$((_dp + 1)); [ "$_dp" -le 4096 ] || exit 1
        [ "${#_dprobe}" -eq 512 ] || exit 1
      done < <(tail -n 256 "$OPDIR/DECISIONS.md" 2>/dev/null)) 2>/dev/null; then
    # CONTINUATION ACCUMULATION (issue #9): read -n 512 splits a multi-KB row
    # across chunks; a cap-filling chunk is a CONTINUATION (append), a shorter
    # one completes the row. LC_ALL=C so ${#} is bytes and exactly 512 bytes
    # iff it stopped on the count. `|| [ -n "$line" ]` flushes a final chunk
    # at EOF without a trailing newline.
    _lines=()
    _acc=""
    while IFS= read -r -n 512 line || [ -n "$line" ]; do
      if [ "${#line}" -ge 512 ]; then
        _acc="${_acc}${line}"
      else
        _lines+=("${_acc}${line}"); _acc=""
      fi
    done < <(tail -n 256 "$OPDIR/DECISIONS.md" 2>/dev/null)
    [ -n "$_acc" ] && _lines+=("$_acc")
    i=${#_lines[@]}
    while [ "$i" -gt 0 ]; do
      i=$((i - 1))
      line="${_lines[i]%$'\r'}"
      # A ledger ROW begins with an ISO date; " | " alone also matches header
      # prose, which would forge a count on a fresh ledger (issue #9).
      case "$line" in
        [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' | '*) ;;
        *) continue ;;
      esac
      kind="${line#* | }"; kind="${kind#* | }"; kind="${kind%% | *}"
      what="${line#* | }"; what="${what#* | }"; what="${what#* | }"; what="${what%% | *}"
      case "$kind" in
        DEVIATION|ESCALATION|GATE-EXCEPTION)
          case "$what" in
            "[sid:$SESSION]"*) DEVMINE=$((DEVMINE + 1)) ;;   # mine/unowned → counts
            "[sid:"*) : ;;                                  # foreign → never counts
            *) DEVMINE=$((DEVMINE + 1)) ;;
          esac ;;
        HANDOFF-MARK)
          # Walking backwards, the FIRST mine/unowned mark is the last one in
          # file order — it clears everything before it. Stop counting.
          case "$what" in
            "[sid:$SESSION]"*) break ;;                     # mine → clears
            "[sid:"*) : ;;                                  # foreign → keep walking
            *) break ;;
          esac ;;
      esac
    done
  fi
fi

# An operator project with nothing open AND no live workflow renders nothing:
# the bar is for states that change what you do next; defaults are not news.
RED=$'\033[31m'; DIM=$'\033[2m'; RESET=$'\033[0m'

WFSEG=""
if [ -n "$SESSION" ]; then
  WFLINE="$(glob_newest_live_journal "$SESSION" 2>/dev/null || true)"
  WFDIR="${WFLINE%%$'\t'*}"
  started="${WFLINE#*$'\t'}"; done="${started#*$'\t'}"; started="${started%%$'\t'*}"
  if [ -n "$WFLINE" ] && [ -n "$WFDIR" ] && [ -f "$WFDIR" ]; then
    case "$started$done" in ''|*[!0-9]*) started=0; done=0 ;; esac
    if [ "${started:-0}" -gt 0 ] 2>/dev/null; then
      WFSEG="${DIM}wf ${done}/${started}${RESET}"
    fi
  fi
fi

[ "$MINE" -gt 0 ] || [ "$FOREIGN" -gt 0 ] || [ "$DEVMINE" -gt 0 ] || [ -n "$WFSEG" ] || exit 0

# Red only when YOUR stop is actually blocked — the one actionable state.
# Foreign is dim: worth seeing, never a call to action. op[0] is noise.
if [ "$MINE" -gt 0 ] || [ "$FOREIGN" -gt 0 ]; then
  OUT="op["
  [ "$MINE" -gt 0 ] && OUT="${OUT}${RED}${MINE}${RESET}" || OUT="${OUT}0"
  [ "$FOREIGN" -gt 0 ] && OUT="${OUT}${DIM}+${FOREIGN}*${RESET}"
  printf '%s]' "$OUT"
  SEP=" "
fi
# dev[N] — dim (an unpresented decision blocks stop, not current work).
if [ "$DEVMINE" -gt 0 ]; then
  printf '%s%sdev[%s]%s' "${SEP:-}" "$DIM" "$DEVMINE" "$RESET"
  SEP=" "
fi
# Explicit `if` keeps the exit status 0: a renderer that fails is one cc-status
# may drop (an empty WFSEG as the script's failing last command did exit 1).
if [ -n "$WFSEG" ]; then
  printf '%s%s' "${SEP:-}" "$WFSEG"
fi
exit 0
