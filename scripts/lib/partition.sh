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
  #
  # The metacharacter arm is #89's, and a READER needs it as much as the
  # writers do. Measured: a pre-0.9 sentinel whose body read `session_id: $S`
  # migrated to `$S__planted`, which this parser accepted as a valid FOREIGN
  # owner — so a real open task stopped blocking every session, Stop rc 0.
  # Whatever the writers refuse must read as unowned here, or a name our CLIs
  # could never have written buys silence instead of a block.
  case "$_o" in
    "" | */* | .* | *"|"* | *[[:space:]]*) printf '\n'; return 0 ;;
    *'$'* | *'`'* | *"'"* | *'"'* | *\\*) printf '\n'; return 0 ;;
  esac
  printf '%s\n' "$_o"
}

# Partition pending/ into blocking (mine + unowned), foreign (report only) and
# MALFORMED (blocking, but not addressable by a CLI — see below).
# Plain glob, not find: builtin, no PATH dependency, and it cannot see dotfiles
# — which is why every writer CLI refuses a leading dot in a task id. `-f`
# follows symlinks: a planted link counts as BLOCKING (fail toward warning).
# A payload with no session_id makes every sentinel unowned → all block.
# Sets: MINE, FOREIGN (counts); MINE_IDS (comma list); FOREIGN_DESC,
# FOREIGN_N ("id owned by <sid>" semicolon list + count); MALFORMED (count) and
# MALFORMED_LIST (a bash ARRAY of full paths, one element each).
#
# An array, not a delimited string, because these paths are PARSED BACK into
# shell commands. FOREIGN_DESC's "; " join is safe — it is display-only — but
# the first cut of this bucket joined paths the same way and the hook split on
# the same literal, so a project at `/work/proj; x/` produced `rm -f '/work/proj'`
# and `rm -f 'x/.operator/pending/A__B__C'`: two confident lines, neither the
# sentinel (measured, PR #104 review). No printable delimiter is safe in a path
# and bash variables cannot hold NUL, so the only lossless carrier is an array.
# Readers under `set -u` on bash 3.2 must guard `"${MALFORMED_LIST[@]}"` behind
# `[ "$MALFORMED" -gt 0 ]`: expanding an EMPTY array is "unbound variable" there.
#
# THE MALFORMED BUCKET (F118, issue #99). Readers split the name on the FIRST
# `__`, so a planted `A__B__C` parses as owner `A`, task `B__C` — and `B__C` is
# a task id every writer CLI REFUSES, because `__` is the separator. The gate
# therefore named a command that could not run: `ops-verdict.sh 'B__C' --defer`
# dies on the guard. Being told to run something that errors is worse than
# being told nothing, because the operator's next move is to doubt the gate.
#
# Why a THIRD bucket rather than degrading these to unowned: degrading fixes
# the ownership question and not the reported one. The id is derived from the
# name either way, so an unowned `A__B__C` reports the id `A__B__C`, which the
# CLIs refuse for the same reason. The name is the problem, so the remedy has
# to be a name-level one — hence the full PATH and `rm -f`, which is what the
# operator does today once they work out that nothing else clears it.
#
# Polarity is fail CLOSED, matching the unowned default: our CLIs cannot write
# this shape, so it is planted or hand-made, and there is no reading of it
# under which allowing a silent stop is right. Note this BLOCKS where the old
# code merely reported (such a name usually parses as a foreign owner) — the
# widening is deliberate and bounded to names no writer could ever produce.
scan_pending() { # scan_pending <opdir> <session>
  local _opdir="$1" _sess="$2" f name owner id
  MINE=0
  FOREIGN=0
  FOREIGN_N=0
  MINE_IDS=""
  FOREIGN_DESC=""
  MALFORMED=0
  MALFORMED_LIST=()
  shopt -s nullglob
  for f in "$_opdir/pending"/*; do
    # -f, not -e: a directory named into pending/ is not a sentinel.
    [ -f "$f" ] || continue
    name="${f##*/}"
    owner="$(sentinel_owner_of_name "$name")"
    # The TASK id is the name minus the owner prefix — what the operator types
    # into ops-verdict.sh, so report that rather than the on-disk name.
    id="${name#*__}"
    # A remaining `__` means a second separator: no writer produced this name,
    # and no CLI can address the id it yields. Bucketed BEFORE the ownership
    # branch so neither message can name the unusable id.
    case "$id" in
      *__*)
        MALFORMED_LIST+=("$f")
        MALFORMED=$((MALFORMED + 1))
        continue ;;
    esac
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
# record decisions; HANDOFF-MARK records they were presented. Foreign lines
# never count.
#
# CLEARING IS ASYMMETRIC, and the asymmetry is the whole of #90. A gated row is
# either MINE (`[sid:me]`) or UNOWNED (no tag at all):
#
#   mine row    — cleared only by a MINE or UNOWNED mark
#   unowned row — cleared by ANY later mark, foreign included
#
# Until this split, a foreign mark cleared nothing and an unowned row counted
# for everyone, so every untagged decision blocked every future session FOREVER
# — the session that wrote it presented it under its own sid, and that mark was
# foreign to everyone after. Measured on two real ledgers as a fresh session:
# strike-zero 6 unpresented (6 untagged rows, 20+ tagged marks, none clearing),
# gtrw 2. Both are 0 under the split, and both were genuinely presented.
#
# The rule, not the migration heuristic: nothing writes the `[sid:]` tag onto a
# DEVIATION — the operator hand-writes those rows — so untagged is the NORMAL
# case, not a pre-0.4 artifact, and ageing them out would leave today's rows
# accumulating exactly as before. An unowned row belongs to nobody, so whoever
# presented it presented it. What still blocks is the case the gate exists for:
# an unowned row with NO later mark at all.
#
# FOUR states, and the polarity differs by WHY the scan could not run (#83 —
# this comment used to say scan_failed=1 covered "unreadable" too, and it never
# did; an unreadable file takes the NUL-probe path below and fails CLOSED. The
# CODE is right and the comment was wrong, which is the worse direction: this is
# the paragraph you read before touching the polarity, so trusting it you would
# "restore" fail-open and quietly open the deviation gate):
#
#   readable, no gated rows  -> unpresented=0 scan_failed=0   (stop allowed)
#   ABSENT or SYMLINK        -> unpresented=0 scan_failed=1   fails OPEN — no
#                               ledger is a scaffold problem, not a decision
#   UNREADABLE (chmod 000)   -> unpresented=1 scan_failed=0   fails CLOSED — the
#                               file EXISTS and we cannot read it, so a real
#                               unpresented decision may be in there
#   corrupt (NUL, over-cap)  -> unpresented=1 scan_failed=0   fails CLOSED
#
# The split is "is there a ledger" versus "is there a ledger we cannot read".
# Globals read by the sourcing script (SC2034/2154 expected).
DECISIONS_MAX_BYTES=2097152   # 2 MiB — orders above any honest decisions ledger
scan_deviations() { # scan_deviations <decisions-path> <this-session>
  local f="$1" sess="$2" line kind what n=0 bytes=0 logical date eng
  local _mine_rows _unowned_rows
  # `local`: without it this leaks C collation to the SOURCING script. Harmless
  # at both call sites today (#83) — declared so it stays that way.
  # LC_ALL=C so read -n 512 and ${#line} count BYTES not characters: in a
  # UTF-8 locale a 512-char chunk can be 2048 bytes, evading the per-line cap
  # and loosening the DECISIONS_MAX_BYTES accumulator ~4x.
  local LC_ALL=C
  deviations_unpresented=0
  deviations_scan_failed=0
  # The counted rows themselves (#93/#94): the hook asked the operator to
  # present N decisions while withholding WHICH — so the cheapest correct
  # response was to mark without reading, the habit the gate exists to prevent.
  # One line per row, `date | engagement | KIND | what`, capped and truncated by
  # the caller. Reset here so a second call cannot append to the first's list.
  deviations_rows=""
  deviations_mine=0
  deviations_unowned=0
  _mine_rows=""
  _unowned_rows=""
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
    # leading [sid:<id>] tag. date/eng are fields 1-2, carried only so a
    # counted row can NAME itself in the block message (#93/#94).
    date="${line%% | *}"
    eng="${line#* | }"; eng="${eng%% | *}"
    kind="${line#* | }"; kind="${kind#* | }"; kind="${kind%% | *}"
    what="${line#* | }"; what="${what#* | }"; what="${what#* | }"; what="${what%% | *}"
    case "$kind" in
      DEVIATION|ESCALATION|GATE-EXCEPTION)
        # Mine and unowned counted SEPARATELY: they clear differently (header).
        case "$what" in
          "[sid:$sess]"*)
            deviations_mine=$((deviations_mine + 1))
            _mine_rows="${_mine_rows}${date} | ${eng} | ${kind} | ${what}
" ;;
          "[sid:"*) return ;;
          *)
            deviations_unowned=$((deviations_unowned + 1))
            _unowned_rows="${_unowned_rows}${date} | ${eng} | ${kind} | ${what}
" ;;
        esac ;;
      HANDOFF-MARK)
        case "$what" in
          # Mine, or unowned (no tag): presented by me or by nobody in
          # particular — discharges everything standing.
          "[sid:$sess]"*)
            deviations_mine=0; deviations_unowned=0
            _mine_rows=""; _unowned_rows="" ;;
          # FOREIGN: discharges the UNOWNED set only (#90). An untagged row
          # belongs to nobody, so another session presenting it is the only
          # way it is ever presented — otherwise it blocks every future
          # session forever. My own tagged rows are untouched.
          "[sid:"*)
            deviations_unowned=0; _unowned_rows="" ;;
          *)
            deviations_mine=0; deviations_unowned=0
            _mine_rows=""; _unowned_rows="" ;;
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
  # The two sets are summed only HERE: every early return above is a
  # fail-CLOSED path that sets deviations_unpresented=1 directly and must not
  # be overwritten by a count of rows it never finished reading.
  deviations_unpresented=$((deviations_mine + deviations_unowned))
  deviations_rows="${_mine_rows}${_unowned_rows}"
}
