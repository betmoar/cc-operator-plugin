#!/usr/bin/env bash
# cc-operator statusline segment — what the Stop hook will do to you, right now.
# op[N] mine (red, blocking) / op[N+M*] foreign (dim), dev[N] unpresented
# decisions, wf done/started while a run is live; NOTHING outside operator
# projects. The partition is NOT re-implemented: hook and bar source the same
# scripts/lib/partition.sh. CONTRACT: never block, never fail loudly — the
# hottest reader in the plugin (~300ms debounce); no lock, no write, no find.
# The SENTINEL/OWNER half is builtin-only (a lost PATH must not blank op[);
# the dev[/wf segments use stat/tail/grep/date, every call failure-guarded so
# they degrade to silence, never to a broken bar (audit F117 — the old header
# claimed builtins-only for the whole file, which was false).
#
# Standalone: "statusLine": {"type":"command","command":"bash .../statusline.sh"}
set -uo pipefail

# --- read stdin; a TTY means "run by hand", not "wait forever" (builtin read:
# no PATH dependence in the hot path) ---
IN=""
[ -t 0 ] || IFS= read -r -d '' IN || true

# --- locate the project: the payload's own view first, agreeing with the hook
PROJ=""
SESSION=""
if [ -n "$IN" ]; then
  if command -v jq >/dev/null 2>&1; then
    PROJ="$(printf '%s' "$IN" | jq -r '.workspace.project_dir // .cwd // empty' 2>/dev/null)"
    SESSION="$(printf '%s' "$IN" | jq -r '.session_id // empty' 2>/dev/null)"
  elif command -v python3 >/dev/null 2>&1; then
    # ONE python3 call, two newline-separated fields, byte-bounded reads;
    # never eval on payload-derived text
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
# A renderer with no lib beside it must render NOTHING, not die (audit F125):
# an unguarded source failed loudly (rc 1, unbound MINE under set -u) and a
# failing renderer is one cc-status may drop silently thereafter. The file
# test keeps the source STATEMENT below pristine for the validator's
# statement-anchored pin.
[ -f "$_libdir/partition.sh" ] || exit 0
# shellcheck source=/dev/null
. "$_libdir/partition.sh"

# --- workflow liveness + progress: newest wf journal for THIS session, live =
# dir touched within the window. Ratio is dispatched-work, never a % (total
# unknown until the last dispatch). Undocumented harness schema: on ANY
# surprise render nothing.
#
# stat flavor probed ONCE per render; `stat -f || stat -c` is BANNED — on GNU,
# -f prints filesystem info to stdout before failing and the fallback
# CONCATENATES garbage (F12; killed this segment on Linux once).
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

# STALL_SEC validated at file scope (the caller swallows stderr inside the
# glob call); warn + default, never exit — dying over a workflow knob would
# blank op[ and dev[ too.
STALL_SEC="${STALL_SEC:-900}"
case "$STALL_SEC" in ''|*[!0-9]*) _stall_bad=1 ;; *) [ "$STALL_SEC" -ge 1 ] || _stall_bad=1 ;; esac
if [ -n "${_stall_bad:-}" ]; then
  echo "statusline: STALL_SEC is not a positive integer (got '$STALL_SEC') — using 900" >&2
  STALL_SEC=900
fi

# Prints "<journal-path>\t<started>\t<result>" for a LIVE run, or nothing.
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
  # liveness = max mtime across journal + sibling transcripts (the journal is
  # quiet during a long dispatch); selection stays journal-keyed
  local a
  for a in "${newest%/journal.jsonl}"/agent-*.jsonl; do
    [ -f "$a" ] || continue
    local am
    am="$(mtime "$a")"
    [ "$am" -gt "$nmtime" ] && nmtime="$am"
  done
  shopt -u nullglob
  local now; now="$(date +%s 2>/dev/null || echo 0)"
  # UNBALANCED journal (started > result) = dispatch in flight; extends the
  # window to STALL_SEC (a live run measured >110s dir-untouched). It cannot
  # REPLACE the mtime check: errored agents never write a result line.
  local stall="$STALL_SEC" ns=0 nr=0
  ns="$(grep -c '"type":"started"' "$newest" 2>/dev/null)" || ns="${ns:-0}"
  nr="$(grep -c '"type":"result"' "$newest" 2>/dev/null)" || nr="${nr:-0}"
  case "$ns$nr" in *[!0-9]*) ns=0; nr=0 ;; esac
  [ "$ns" -gt "$nr" ] && [ "$stall" -gt "$live" ] && live="$stall"
  # Tab-separated; the caller splits on it. A journal path cannot contain a tab.
  if [ $((now - nmtime)) -le "$live" ]; then printf '%s\t%s\t%s' "$newest" "$ns" "$nr"; fi
}

scan_pending "$OPDIR" "$SESSION"

# --- deviations: tail-window approximation of the shared scan (CR5) — the
# whole-file scan measured 0.4s at 3000 lines vs the 300ms budget. Last ~256
# lines, walked BACKWARD to the first mine-or-unowned mark; same count when
# the active set fits the window; fails toward silence. Hook gates exactly.
DEVMINE=0
if [ -f "$OPDIR/DECISIONS.md" ] && [ ! -L "$OPDIR/DECISIONS.md" ]; then
  # NUL probe over the SAME window; tail runs twice because bash drops NULs
  # from variables — a captured tail makes the probe vacuous. The window is
  # byte-bounded BEFORE it is line-bounded (audit F124): `tail -n 256` alone
  # returns a multi-MB newline-less final line whole, and the probe chewed it
  # at ~500ms against the 300ms budget. 256KiB covers 256 healthy rows with
  # room; past it the bar's answer is the approximation failing toward
  # silence, which is its documented deal (CR5).
  if (LC_ALL=C _dp=0
      while IFS= read -r -d '' -n 512 _dprobe; do
        _dp=$((_dp + 1)); [ "$_dp" -le 4096 ] || exit 1
        [ "${#_dprobe}" -eq 512 ] || exit 1
      done < <(tail -c 262144 "$OPDIR/DECISIONS.md" 2>/dev/null | tail -n 256 2>/dev/null)) 2>/dev/null; then
    # continuation accumulation (#9): a cap-filling chunk is a CONTINUATION,
    # a shorter one completes the row; LC_ALL=C so ${#} counts bytes.
    _lines=()
    _acc=""
    while IFS= read -r -n 512 line || [ -n "$line" ]; do
      if [ "${#line}" -ge 512 ]; then
        _acc="${_acc}${line}"
      else
        _lines+=("${_acc}${line}"); _acc=""
      fi
    done < <(tail -c 262144 "$OPDIR/DECISIONS.md" 2>/dev/null | tail -n 256 2>/dev/null)
    [ -n "$_acc" ] && _lines+=("$_acc")
    # Set once a FOREIGN mark is passed on the backward walk: from there down,
    # unowned rows are already presented (the lib's asymmetric clearing).
    _devunowned_cleared=0
    i=${#_lines[@]}
    while [ "$i" -gt 0 ]; do
      i=$((i - 1))
      line="${_lines[i]%$'\r'}"
      # a ROW begins with an ISO date — " | " alone matches header prose (#9)
      case "$line" in
        [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' | '*) ;;
        *) continue ;;
      esac
      kind="${line#* | }"; kind="${kind#* | }"; kind="${kind%% | *}"
      what="${line#* | }"; what="${what#* | }"; what="${what#* | }"; what="${what%% | *}"
      case "$kind" in
        DEVIATION|ESCALATION|GATE-EXCEPTION)
          case "$what" in
            "[sid:$SESSION]"*) DEVMINE=$((DEVMINE + 1)) ;;   # mine → counts
            "[sid:"*) : ;;                                  # foreign → never counts
            # unowned → counts only while the unowned set is still standing;
            # a foreign mark already seen (walking backwards) discharged it.
            *) [ "$_devunowned_cleared" = 1 ] || DEVMINE=$((DEVMINE + 1)) ;;
          esac ;;
        HANDOFF-MARK)
          # Walking BACKWARD, so the first mark seen is the LAST in the file.
          # Mirrors the lib's asymmetric clearing (#90): a mine/unowned mark
          # ends the walk entirely; a foreign mark discharges only the unowned
          # rows below it and the walk continues for mine.
          case "$what" in
            "[sid:$SESSION]"*) break ;;                     # mine → clears all
            "[sid:"*) _devunowned_cleared=1 ;;              # foreign → unowned only
            *) break ;;                                     # unowned → clears all
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

# MALFORMED sentinels BLOCK (F118 / #99), so they belong in the RED count: red
# means "your stop is blocked", and a bar that leaves out a blocking bucket
# describes a gate other than the one that runs — the failure this file and the
# hook share partition.sh to prevent. Folded into MINE rather than given a
# segment of their own: the bar's job is whether you are blocked, and the hook
# is where the unusable name and its `rm -f` get spelled out.
BLOCKING=$((MINE + MALFORMED))

[ "$BLOCKING" -gt 0 ] || [ "$FOREIGN" -gt 0 ] || [ "$DEVMINE" -gt 0 ] || [ -n "$WFSEG" ] || exit 0

# Red only when YOUR stop is actually blocked — the one actionable state.
# Foreign is dim: worth seeing, never a call to action. op[0] is noise.
if [ "$BLOCKING" -gt 0 ] || [ "$FOREIGN" -gt 0 ]; then
  OUT="op["
  [ "$BLOCKING" -gt 0 ] && OUT="${OUT}${RED}${BLOCKING}${RESET}" || OUT="${OUT}0"
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
