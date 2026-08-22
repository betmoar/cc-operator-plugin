# shellcheck shell=bash
# shellcheck disable=SC2034  # the scan_* globals are consumed by the SOURCING script
# lib/partition.sh — the ONE implementation of the gate's partition rule.
# Sourced (never shipped standalone) by ops-stop-hook.sh and statusline.sh —
# the hook enforces the partition, the bar renders it, and both reading one
# file is what keeps them from disagreeing about whether a stop will block.
# NOT for the .operator/bin/ gate CLIs: those install standalone into target
# projects (no lib/ beside them), so they keep their own copies, pinned by
# check_guard_parity the same way this file's copies are.

# Ownership is the sentinel's NAME: pending/<owner>__<task>, unowned when there
# is no `__`. Nothing is opened, so no byte-bounded read guards it — a planted
# entry cannot smuggle an owner, only a name our CLIs could never have written.
sentinel_owner_of_name() { # <basename> → owner ("" when unowned or unwritable-by-us)
  case "$1" in
    *__*) : ;;
    *) printf '\n'; return 0 ;;
  esac
  _o="${1%%__*}"
  # The F1 reject set ("" | */* | .* | *"|"* | *[[:space:]]*): our CLIs can
  # never write these shapes, so a name carrying one was PLANTED — degrade to
  # unowned, which fails CLOSED. (The comment quotes the literal on purpose:
  # GuardParityVacuityTest proves the pin reads code, not this line.)
  case "$_o" in
    "" | */* | .* | *"|"* | *[[:space:]]*) printf '\n'; return 0 ;;
  esac
  printf '%s\n' "$_o"
}

# Partition pending/ into blocking (mine + unowned) and foreign (report only).
# Plain glob, not find: builtin, no PATH dependency, and it cannot see dotfiles
# — which is why every writer CLI refuses a leading dot in a task id. `-f`
# follows symlinks: a planted link counts as BLOCKING (fail toward warning).
# A payload with no session_id makes every sentinel unowned → all block.
# Sets: MINE, FOREIGN (counts); MINE_IDS (comma list); FOREIGN_DESC,
# FOREIGN_N ("id owned by <sid>" semicolon list + count).
scan_pending() { # scan_pending <opdir> <session>
  local _opdir="$1" _sess="$2" f name owner id
  MINE=0
  FOREIGN=0
  FOREIGN_N=0
  MINE_IDS=""
  FOREIGN_DESC=""
  shopt -s nullglob
  for f in "$_opdir/pending"/*; do
    # -f, not -e: a directory named into pending/ is not a sentinel.
    [ -f "$f" ] || continue
    name="${f##*/}"
    owner="$(sentinel_owner_of_name "$name")"
    # The TASK id is the name minus the owner prefix — what the operator types
    # into ops-verdict.sh, so report that rather than the on-disk name.
    id="${name#*__}"
    if [ -n "$owner" ] && [ -n "$_sess" ] && [ "$owner" != "$_sess" ]; then
      # Name the OWNER, not just the task: with 3+ sessions a bystander cannot
      # tell which session to chase otherwise.
      FOREIGN_DESC="${FOREIGN_DESC:+$FOREIGN_DESC; }$id owned by $owner"
      FOREIGN=$((FOREIGN + 1))
      FOREIGN_N=$((FOREIGN_N + 1))
    else
      MINE_IDS="${MINE_IDS:+$MINE_IDS, }$id"
      MINE=$((MINE + 1))
    fi
  done
  shopt -u nullglob
}

# Unpresented deviations (stage 2). DEVIATION/ESCALATION/GATE-EXCEPTION lines
# record decisions; HANDOFF-MARK records they were presented. Counts THIS
# session's (or unowned) gated lines after the last mine-or-unowned mark;
# foreign lines never count, foreign marks never clear. scan_failed=1 (absent/
# unreadable/symlink ledger) fails OPEN — a scaffold problem, not a decision.
# Corrupt shapes (NUL, over-cap) fail CLOSED: unpresented=1, surfaced not
# hidden. Globals read by the sourcing script (SC2034/2154 expected).
DECISIONS_MAX_BYTES=2097152   # 2 MiB — orders above any honest decisions ledger
scan_deviations() { # scan_deviations <decisions-path> <this-session>
  local f="$1" sess="$2" line kind what n=0 bytes=0 logical
  # LC_ALL=C so read -n 512 and ${#line} count BYTES not characters: in a
  # UTF-8 locale a 512-char chunk can be 2048 bytes, evading the per-line cap
  # and loosening the DECISIONS_MAX_BYTES accumulator ~4x.
  LC_ALL=C
  deviations_unpresented=0
  deviations_scan_failed=0
  [ -f "$f" ] || { deviations_scan_failed=1; return 0; }
  # A symlinked DECISIONS.md is not a ledger our scaffold wrote (`-f` follows
  # it); treat as absent → fail OPEN, never scan through a link (F65 class).
  [ ! -L "$f" ] || { deviations_scan_failed=1; return 0; }
  # Bounded NUL probe: a NUL means a merge artifact or stray binary — degrade
  # to counted-as-unpresented (a not-ours ledger blocks; fail toward warning).
  if ! (LC_ALL=C _dp=0
        while IFS= read -r -d '' -n 512 _dprobe; do
          _dp=$((_dp + 1)); [ "$_dp" -le 4096 ] || exit 1
          [ "${#_dprobe}" -eq 512 ] || exit 1
        done < "$f") 2>/dev/null; then
    deviations_unpresented=1
    return 0
  fi
  # classify one COMPLETE logical row (nested so it sees $sess by dynamic
  # scope; factored because the forward pass classifies twice — per row and
  # for a final row left mid-accumulation at EOF).
  _dec_line() { # _dec_line <logical-line>
    line="${1%$'\r'}"          # a CRLF checkout must not change semantics
    # A ledger ROW begins with an ISO date. The `*" | "*` test alone is not
    # enough — prose and header comments contain " | " too (the kind-enum
    # comment line would parse kind=GATE-EXCEPTION, no sid → unowned →
    # counted, blocking every freshly-scaffolded ledger: issue #9).
    case "$line" in
      [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' | '*) ;;
      *) return ;;             # not a ledger row (header comment, blank, prose)
    esac
    # kind (field 3) and what (field 4) by splitting on " | " — a glob's `*`
    # would consume the delimiter. The sid lives in the what-cell as a
    # leading [sid:<id>] tag.
    kind="${line#* | }"; kind="${kind#* | }"; kind="${kind%% | *}"
    what="${line#* | }"; what="${what#* | }"; what="${what#* | }"; what="${what%% | *}"
    case "$kind" in
      DEVIATION|ESCALATION|GATE-EXCEPTION)
        # mine (sid matches) or unowned (no tag) → counts; foreign never does.
        case "$what" in
          "[sid:$sess]"*) : ;;
          "[sid:"*) return ;;
          *) : ;;
        esac
        deviations_unpresented=$((deviations_unpresented + 1)) ;;
      HANDOFF-MARK)
        # Only a mine-or-unowned mark clears; a foreign mark clears nothing.
        case "$what" in
          "[sid:$sess]"*) deviations_unpresented=0 ;;
          "[sid:"*) : ;;
          *) deviations_unpresented=0 ;;
        esac ;;
    esac
  }
  # Forward pass with CONTINUATION ACCUMULATION (#9): a cap-filling chunk saw
  # no newline → append and continue; a shorter chunk completes the row.
  # (Per-chunk fail-closed made a mark past the first long row unreachable —
  # an unkillable phantom block.) LC_ALL=C: 512 bytes iff stopped on count.
  logical=""
  while IFS= read -r -n 512 line || [ -n "$line" ]; do
    n=$((n+1)); [ "$n" -le 20000 ] || { deviations_unpresented=1; return 0; }
    # Aggregate BYTE cap: ${#line} is bytes here; +1 for the delimiter.
    bytes=$((bytes + ${#line} + 1))
    [ "$bytes" -le "$DECISIONS_MAX_BYTES" ] || { deviations_unpresented=1; return 0; }
    logical="${logical}${line}"
    [ "${#line}" -ge 512 ] && continue
    _dec_line "$logical"
    logical=""
  done < "$f"
  # Flush a final row left mid-accumulation at EOF.
  [ -z "$logical" ] || _dec_line "$logical"
}
