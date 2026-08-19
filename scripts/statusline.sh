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
# Ownership is the sentinel's NAME: pending/<owner>__<task>, unowned when there
# is no `__`. Nothing is opened, so the byte-bounded read, the NUL pre-scan, the
# LC_ALL=C byte counting and the symlink-degrade are gone with the body they
# guarded — they existed to make an untrusted file safe to parse, and there is
# no longer a file to parse. A planted entry cannot smuggle an owner.
sentinel_owner_of_name() { # <basename> → owner ("" when unowned or unwritable-by-us)
  case "$1" in
    *__*) : ;;
    *) printf '\n'; return 0 ;;
  esac
  _o="${1%%__*}"
  # The F1 reject set, moved with the attack surface rather than deleted with the
  # body parser. Our CLIs can never write these shapes (check_bare_name refuses
  # them at construction), so a name carrying one was PLANTED — and the
  # grant-suffix arm in particular would let a planted sentinel pose as the owner
  # of a G3 grant and get another session's exemption deleted by
  # recompute_arm_marker. Degrade to unowned, which blocks everyone: fails
  # CLOSED, the safe direction.
  #
  # The literals live ONLY in the case below, never in this prose: the vacuity
  # test mutates raw text, so a comment repeating a pinned literal absorbs the
  # mutation and the pin stops proving anything.
  case "$_o" in
    "" | */* | .* | *"|"* | *[[:space:]]* | *.exempt) printf '\n'; return 0 ;;
  esac
  printf '%s\n' "$_o"
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
#
# The probe is its OWN function, called from the caller's scope, because every
# mtime call site is `$(mtime …)` — a SUBSHELL, whose assignment to _STAT_KIND
# dies with it. Probing inside mtime therefore memoized nothing: the flavor was
# re-detected on every single call (~3 stats each instead of 1 probe + N reads),
# on the hottest reader in the plugin. Probe once per render, at the top of the
# one function that uses mtime, and the nested subshells inherit the answer.
# `/` (not the candidate path): it always exists and is always statable, so the
# probe never mis-detects "none" from a file that merely vanished mid-render.
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

# STALL_SEC is env-overridable and lands in `[ "$stall" -gt "$live" ]` below. A
# non-numeric value makes that test ERROR (status 2), the `&&` chain
# short-circuits, the stall window silently never extends, and a long run's
# segment flaps off mid-run — exactly the bug the window was added to fix,
# reintroduced by a typo that nothing reports. Validate it like ops-verdict.sh's
# lock budgets: digits only, positive, fail LOUD. Loud here is a stderr warning
# plus the 900 default, never an exit: the renderer's contract is "never block,
# never fail loudly", and dying over a workflow-liveness knob would blank the
# whole bar — op[ and dev[ included, which are the parts that gate a session.
#
# It is validated HERE, at file scope, and not inside the function: the caller
# wraps that call in `2>/dev/null`, so a warning raised in there is swallowed
# and the knob fails silent again — the very failure mode being fixed.
STALL_SEC="${STALL_SEC:-900}"
case "$STALL_SEC" in ''|*[!0-9]*) _stall_bad=1 ;; *) [ "$STALL_SEC" -ge 1 ] || _stall_bad=1 ;; esac
if [ -n "${_stall_bad:-}" ]; then
  echo "statusline: STALL_SEC is not a positive integer (got '$STALL_SEC') — using 900" >&2
  STALL_SEC=900
fi

# Prints "<journal-path>\t<started>\t<result>" for a LIVE run, or nothing.
# The two counts are RETURNED rather than recomputed by the wf segment: both
# needed the identical pair of greps over the identical file, so computing them
# twice doubled the render's external-process cost for no new information.
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
  # PATH both greps fail the same way and we degrade to the plain 90s window
  # (and to a countless wf segment: "" → 0 → nothing renders, as before).
  # STALL_SEC is validated at file scope; see the note above the function.
  local stall="$STALL_SEC" ns=0 nr=0
  ns="$(grep -c '"type":"started"' "$newest" 2>/dev/null)" || ns="${ns:-0}"
  nr="$(grep -c '"type":"result"' "$newest" 2>/dev/null)" || nr="${nr:-0}"
  case "$ns$nr" in *[!0-9]*) ns=0; nr=0 ;; esac
  [ "$ns" -gt "$nr" ] && [ "$stall" -gt "$live" ] && live="$stall"
  # Tab-separated: the caller splits on it. Path first — a journal path cannot
  # contain a tab (it is harness-generated under $HOME/.claude/projects).
  if [ $((now - nmtime)) -le "$live" ]; then printf '%s\t%s\t%s' "$newest" "$ns" "$nr"; fi
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
  owner="$(sentinel_owner_of_name "${f##*/}")"
  if [ -n "$owner" ] && [ -n "$SESSION" ] && [ "$owner" != "$SESSION" ]; then
    FOREIGN=$((FOREIGN + 1))
  else
    MINE=$((MINE + 1))                       # mine, or unowned (blocks everyone)
  fi
done
shopt -u nullglob

# --- unpresented deviations: mirror of the deviation gate (stage 2) -----------
# The bar renders the SAME partition the Stop hook blocks on: mine + unowned
# DEVIATION lines after the last mine-or-unowned HANDOFF-MARK. A bar counting a
# different set than the gate is worse than no bar (the coupling-table rule).
#
# STRATEGY DIFFERS FROM THE HOOK (CR5, code-review 2026-08-04): the bar renders
# on a ~300ms timer, and the hook's whole-file scan is O(n) in an append-forever
# ledger — measured 0.4s at 3000 lines, blowing the render budget. The bar uses a
# REVERSE TAIL scan: read the last ~256 lines and walk them backwards, counting
# mine/unowned deviations, STOPPING at the first mine/unowned mark (it clears
# everything before it). That is O(tail), not O(n). The hook stays whole-file
# fail-closed (it is the gate; accuracy beats latency there). The bar's accuracy
# is approximate when the active deviations exceed the tail window — but the bar
# is informational (fails toward silence, never blocks), and the hook still gates
# exactly. `tail` is an external, but the bar already uses `grep` for the wf
# segment; the gate (the Stop hook) bans externals, the mirror does not.
#
# Dim, not red: an unpresented deviation blocks STOP, not current work. Renders
# nothing when the count is 0 (the common case) or the ledger is absent.
DEVMINE=0
scan_deviations_bar() { # scan_deviations_bar <decisions-path> <this-session>
  local f="$1" sess="$2" line kind what i
  # LC_ALL=C so the bounded reads and ${#} count BYTES not characters (Copilot
  # review, 2026-08-04): in a multibyte locale a 512-char chunk can be 2048
  # bytes, weakening the byte bound. Safe to set without restore: every segment
  # this statusline renders (op[/dev[/wf, ANSI codes, path strings from
  # charset-restricted bare-name sentinel filenames) is ASCII, so the byte
  # locale does not change its output.
  LC_ALL=C
  [ -f "$f" ] && [ ! -L "$f" ] || return 0
  # Reject a NUL/corrupt ledger up front (fail toward silence). The tail scan
  # below would otherwise parse garbage; a corrupt ledger must not render a count.
  #
  # It probes the SAME TAIL WINDOW the scan reads, not the whole file. The
  # whole-file form re-introduced the O(n) cost the reverse-tail scan exists to
  # avoid — measured ~200x the tail's own cost on a 658KB ledger, on a 300ms
  # timer — while only rows inside the window can change the count anyway.
  # A NUL IN the tail still classifies the ledger as corrupt and renders no
  # dev[N]. A NUL far outside it no longer does, and that is deliberate: it is
  # the same approximation the reverse-tail scan already makes (CR5 — the bar
  # is informational and fails toward silence; the Stop hook stays whole-file
  # fail-closed and is what actually gates), and it cannot make the bar under-
  # report a gate, because the rows it counts were themselves NUL-free.
  # `tail` runs twice (probe + scan) rather than once into a variable, because
  # bash DROPS NULs from variables — a captured tail would make the probe
  # vacuous, the same class of mistake as the `case $line in *$'\0'*)` above.
  if ! (LC_ALL=C _dp=0
        while IFS= read -r -d '' -n 512 _dprobe; do
          _dp=$((_dp + 1)); [ "$_dp" -le 4096 ] || exit 1
          [ "${#_dprobe}" -eq 512 ] || exit 1
        done < <(tail -n 256 "$f" 2>/dev/null)) 2>/dev/null; then
    return 0
  fi
  # CONTINUATION ACCUMULATION — issue #9. A ledger row may be many KB; read -n
  # 512 splits one physical row across multiple lines, so a naive line-walk
  # mis-parses long rows: a long DEVIATION's continuation chunks fail the
  # " | " row test and are skipped → under-counted (the bar's silent analog of
  # the hook's hard-abort). Fix: accumulate cap-filling chunks into one logical
  # line before classifying. A chunk that hit the 512 cap stopped on the count,
  # not a newline, so it is a CONTINUATION; a shorter chunk hit the newline and
  # completes the row. read under LC_ALL=C, so ${#} is bytes and exactly 512
  # bytes iff it stopped on the count.
  local _lines=()
  local _acc=""
  # `|| [ -n "$line" ]` flushes a final chunk at EOF without a trailing newline:
  # read returns non-zero on EOF but still sets $line to what it read, and
  # without this guard the last unterminated row's final chunk is dropped from
  # _acc — the bar would under-count exactly the no-trailing-newline ledgers the
  # hook's `|| [ -n "$line" ]` handles. Mirror parity (issue #9, Copilot review).
  while IFS= read -r -n 512 line || [ -n "$line" ]; do
    if [ "${#line}" -ge 512 ]; then
      _acc="${_acc}${line}"           # mid-row → keep accumulating
    else
      _lines+=("${_acc}${line}"); _acc=""   # newline/EOF → complete row
    fi
  done < <(tail -n 256 "$f" 2>/dev/null)
  [ -n "$_acc" ] && _lines+=("$_acc")      # flush a final unterminated row
  [ "${#_lines[@]}" -gt 0 ] || return 0
  i=${#_lines[@]}
  while [ "$i" -gt 0 ]; do
    i=$((i - 1))
    line="${_lines[i]}"
    line="${line%$'\r'}"
    # A ledger ROW begins with an ISO date; " | " alone also matches header prose
    # (the kind-enum comment line), which would forge a count on a fresh ledger
    # (issue #9 collateral). Match the row grammar, not just a delimiter.
    case "$line" in
      [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' | '*) ;;
      *) continue ;;
    esac
    kind="${line#* | }"; kind="${kind#* | }"; kind="${kind%% | *}"
    what="${line#* | }"; what="${what#* | }"; what="${what#* | }"; what="${what%% | *}"
    case "$kind" in
      DEVIATION|ESCALATION|GATE-EXCEPTION)
        case "$what" in
          "[sid:$sess]"*) DEVMINE=$((DEVMINE + 1)) ;;   # mine/unowned → counts
          "[sid:"*) : ;;                                # foreign → never counts
          *) DEVMINE=$((DEVMINE + 1)) ;;
        esac ;;
      HANDOFF-MARK)
        # Walking backwards, the FIRST mine/unowned mark we hit is the last one
        # in file order — it clears everything before it. Stop counting.
        case "$what" in
          "[sid:$sess]"*) return 0 ;;                   # mine/unowned → clears, stop
          "[sid:"*) : ;;                                # foreign → no effect, keep walking
          *) return 0 ;;
        esac ;;
    esac
  done
}
[ -n "$OPDIR" ] && scan_deviations_bar "$OPDIR/DECISIONS.md" "$SESSION"

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
  # The counts come BACK from the liveness check, which already ran the identical
  # `grep -c` pair over this same file for its stall decision. `grep -c` prints
  # "0" AND exits 1 on zero matches, so a `|| echo 0` fallback there would
  # capture "0\n0" — an embedded newline rendering a two-line segment that breaks
  # the composed bar (hit live: every run's first phase has done=0). That guard
  # now lives once, at the producer.
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
# dev[N] — dim (an unpresented decision blocks stop, not current work). Mirrors
# the deviation gate's mine+unowned-after-last-mark count; foreign excluded.
# Renders only when N>0; dev[0] is the common case and is noise.
if [ "$DEVMINE" -gt 0 ]; then
  printf '%s%sdev[%s]%s' "${SEP:-}" "$DIM" "$DEVMINE" "$RESET"
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
