#!/usr/bin/env bash
# ops-stop-hook.sh — Stop-hook completion gate (P3/D4 layer 2).
#
# Contract (exit codes are the interface — Claude Code reads them):
#   exit 0  — allow the stop. Cases: no .operator/ in cwd (no-op guard);
#             .operator/pending/ empty; stop_hook_active true (loop guard);
#             no JSON parser available (fail-open — a broken hook must never
#             brick a session).
#   exit 2  — block the stop. This session OWNS a pending sentinel (or one is
#             unowned) and stop_hook_active is false; stderr names those ids and
#             the command to clear them (Claude Code feeds stderr back as
#             guidance).
#
# Ownership: a sentinel stamps `session_id: <id>` (ops-task.sh --owner). Only
# sentinels owned by THIS session — or owned by nobody — block. Foreign ones are
# reported on stderr and allowed, so one session can no longer be trapped by
# another's open task, nor close a row it did not perform. An UNOWNED sentinel
# fails CLOSED (pre-0.4 sentinels are empty files, and an unowned sentinel is a
# real open task) — deliberately the opposite default from the no-parser
# fail-open below, where a broken plugin must not brick a session.
#
# Reads the Stop payload as JSON on stdin ONCE. Sentinel check runs against the
# cwd carried IN the payload, never the script's own cwd. External dependencies
# are limited to one JSON parser (jq preferred, python3 fallback); stdin read,
# pending enumeration, and owner parsing use bash builtins only (no grep/sed),
# so PATH loss cannot brick it.
set -u

# --- read the whole payload from stdin (builtin; no external command) --------
# Slurp everything up to a NUL that never comes: captures the full payload
# whether or not it ends in a newline (command substitution strips trailing
# newlines, which a line-by-line `read` loop would then drop entirely).
input=""
IFS= read -r -d '' input || true

# --- pick a JSON parser once; fail open if none ------------------------------
if command -v jq >/dev/null 2>&1; then
  PARSER=jq
elif command -v python3 >/dev/null 2>&1; then
  PARSER=python3
else
  echo "operator: warning — no jq or python3 on PATH; Stop hook failing open (exit 0)" >&2
  exit 0
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
k = sys.argv[1]
v = d.get(k, "")
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

cwd="$(json_get cwd)"
active="$(json_get stop_hook_active)"
session="$(json_get session_id)"

# --- loop guard: never re-block an already-active stop -----------------------
[ "$active" = "true" ] && exit 0

# --- no-op guard: not an operator project → stay out of the way --------------
# An empty cwd has two very different causes: a payload that legitimately has no
# cwd (fine, stay out of the way) and a payload that FAILED TO PARSE (json_get
# swallows parser errors, so every field comes back empty). Both exit 0, but the
# second is a fail-open we should not perform silently — it is the same class of
# event as the no-parser branch above, which warns. Distinguish them: a payload
# with content but no parseable cwd is a corrupt payload.
if [ -z "$cwd" ]; then
  if [ -n "$input" ]; then
    echo "operator: warning — Stop payload present but unparseable (no cwd); hook failing open (exit 0)" >&2
  fi
  exit 0
fi
# Resolve the project by WALKING UP from the payload cwd to the nearest ancestor
# holding .operator/ — the way git finds its own root.
#
# Why this is not just `"$cwd/.operator"`: ops-task.sh refuses to open a task
# anywhere but the directory holding .operator/, so a task can only ever be armed
# at the root. If the payload cwd is one directory deeper, an exact-match lookup
# finds nothing, takes the no-op guard, and ALLOWS the stop with tasks still
# open — the two components disagreeing about where the project is, and the
# disagreement failing OPEN. That is the whole gate, silently off. (Audit F01.)
#
# The walk is bounded twice so it can never adopt an unrelated ancestor's ledger:
# it stops at a .git boundary (a nested repo is its own project, not part of the
# outer one) and at the filesystem root. `cd -P` resolves symlinks so a symlinked
# worktree lands on its real path rather than walking a link chain.
opdir=""
walk="$(cd -P "$cwd" 2>/dev/null && pwd)" || walk=""
while [ -n "$walk" ]; do
  if [ -d "$walk/.operator" ]; then opdir="$walk/.operator"; break; fi
  # a repository boundary ends the search: do not escape into the parent project
  [ -e "$walk/.git" ] && break
  [ "$walk" = "/" ] && break
  walk="${walk%/*}"; [ -n "$walk" ] || walk="/"
done
[ -n "$opdir" ] || exit 0
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

# --- unpresented deviations (stage 2: a second ledger the gate reads) ---------
# DEVIATION lines in DECISIONS.md record operator-taken decisions; a HANDOFF-MARK
# records that they were presented. The gate blocks Stop iff a DEVIATION owned by
# THIS session — or owned by nobody — appears AFTER the last HANDOFF-MARK owned
# by this session or nobody. Foreign deviations (and foreign marks) never block
# and never clear: the 0.4.0 mine/unowned-vs-foreign partition applied to the
# second ledger, identical in shape to the sentinel partition above.
#
# Polarity is DELIBERATELY OPPOSITE the sentinel default, and both are right:
# an unreadable or absent DECISIONS.md FAILS OPEN (exit 0). A missing ledger is a
# plugin/scaffold problem, not evidence of an unpresented decision — the same
# reasoning as the no-parser fail-open at the top of this hook. Where an unowned
# sentinel fails CLOSED (a real open task), an absent DECISIONS.md has no task
# to enforce. A MALFORMED line (over-long, NUL, CRLF) degrades to counted-as-
# unpresented (fail toward the honest warning): the reader is byte-bounded and a
# degenerate line is not a trustworthy "presented" claim.
#
# The scan is WHOLE-FILE with an aggregate byte cap (fail-closed on cap):
# DECISIONS.md is append-forever, unlike tiers.env whose cap could be sized to a
# parse loop's legal max. There is no cap sized to "legal input" here, so a
# fixed cap that waved a too-big file through would silently disable the gate on
# exactly the ledger most likely to hold an unpresented decision. A too-big-to-
# scan ledger is a real problem to surface, not hide. The cap is a safety bound
# against pathological input, not a real constraint (cf. FRAG_MAX_BYTES).
DECISIONS_MAX_BYTES=2097152   # 2 MiB — orders above any honest decisions ledger
deviations_unpresented=0      # global: count of mine+unowned deviations after the last mark
deviations_scan_failed=0      # global: 1 = file unreadable/absent (caller fails OPEN)
scan_deviations() { # scan_deviations <decisions-path> <this-session>
  local f="$1" sess="$2" line kind what n=0 bytes=0
  # LC_ALL=C so read -n 512 and ${#line} count BYTES not characters (Copilot
  # review, 2026-08-04): in a UTF-8 locale a 512-char chunk can be up to 2048
  # bytes, evading the per-line cap and making the DECISIONS_MAX_BYTES accumulator
  # ~4x looser than intended. Safe to set here: the function only does byte-level
  # parsing, and the hook exits (ASCII output only) shortly after it runs.
  LC_ALL=C
  deviations_unpresented=0
  deviations_scan_failed=0
  [ -f "$f" ] || { deviations_scan_failed=1; return 0; }
  # A symlinked DECISIONS.md is not a ledger our scaffold wrote: `-f` follows it,
  # so a planted link would feed an attacker-chosen file to the scan. Treat as
  # absent → fail OPEN (same as missing), never scan through a link (F65 class).
  [ ! -L "$f" ] || { deviations_scan_failed=1; return 0; }
  # Whole-file NUL probe, bounded (the sentinel parsers' canonical form): a NUL
  # in the ledger means a merge artifact or stray binary, not decisions prose —
  # degrade every line to counted-as-unpresented by failing the probe → the file
  # is "not ours", and a not-ours ledger blocks (fail toward the honest warning).
  if ! (LC_ALL=C _dp=0
        while IFS= read -r -d '' -n 512 _dprobe; do
          _dp=$((_dp + 1)); [ "$_dp" -le 4096 ] || exit 1
          [ "${#_dprobe}" -eq 512 ] || exit 1
        done < "$f") 2>/dev/null; then
    deviations_unpresented=1   # a NUL/corrupt ledger: block (count as unpresented)
    return 0
  fi
  # classify one COMPLETE logical row. Nested so it sees $sess (dynamic scope:
  # bash locals are visible to callees) and the global deviations_unpresented.
  # Factored because the forward pass must classify twice — once per row inside
  # the loop, and once for a final row left mid-accumulation at EOF.
  _dec_line() { # _dec_line <logical-line>
    line="${1%$'\r'}"          # a CRLF checkout must not change semantics
    # A ledger ROW begins with an ISO date: "YYYY-MM-DD | ...". The `*" | "*` test
    # alone is not enough — prose and header comments contain " | " too (the kind
    # enum line "# ... DEVIATION | ESCALATION | GATE-EXCEPTION" would otherwise
    # parse kind=GATE-EXCEPTION, no sid → unowned → counted, blocking every
    # freshly-scaffolded ledger: issue #9 collateral). A leading date is the
    # unambiguous row discriminator; the ledger grammar guarantees it (the kind
    # tag, the only thing that can forge a count, never starts a real row).
    case "$line" in
      [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' | '*) ;;
      *) return ;;             # not a ledger row (header comment, blank, prose)
    esac
    # Extract kind (field 3) and what (field 4) by splitting on " | " — a glob's
    # `*` would consume the delimiter. Only kind+what matter; the sid lives in
    # the what-cell as a leading [sid:<id>] tag.
    # field 3: strip the first TWO " | "-delimited cells (date, eng.task).
    kind="${line#* | }"; kind="${kind#* | }"; kind="${kind%% | *}"
    # field 4: strip three cells, then cut at the next " | " for the what-cell.
    what="${line#* | }"; what="${what#* | }"; what="${what#* | }"; what="${what%% | *}"
    case "$kind" in
      DEVIATION|ESCALATION|GATE-EXCEPTION)
        # mine = sid tag equals this session; unowned = no sid tag. Both block.
        # A foreign sid tag (≠ session) never blocks. Foreign = report only, and
        # the hook's stderr below does not enumerate these (they are the operator's
        # own decisions, not another session's tasks to chase).
        case "$what" in
          "[sid:$sess]"*) : ;;                      # mine → counts
          "[sid:"*) return ;;                       # foreign → never blocks
          *) : ;;                                   # unowned (no tag) → counts
        esac
        deviations_unpresented=$((deviations_unpresented + 1)) ;;
      HANDOFF-MARK)
        # Only a mine-or-unowned mark clears; a foreign mark clears nothing of mine.
        case "$what" in
          "[sid:$sess]"*) deviations_unpresented=0 ;;   # mine → clears
          "[sid:"*) : ;;                                # foreign → no effect
          *) deviations_unpresented=0 ;;                # unowned → clears
        esac ;;
    esac
  }
  # Single forward pass: a mine/unowned DEVIATION increments; a mine/unowned
  # HANDOFF-MARK resets to 0 (it clears everything before it). At EOF the count
  # is exactly the deviations after the last mark = the unpresented set.
  #
  # CONTINUATION ACCUMULATION (not per-chunk fail-closed) — issue #9. A ledger
  # row may be many KB: the charter asks for measurements/baselines/root-causes
  # in the what-cell, so multi-thousand-byte rows are the EXPECTED shape of an
  # honest ledger, not an anomaly. read -n 512 FILLS on any row past 512 bytes.
  # The old per-chunk guard then hard-coded the count to 1 and RETURNED, which
  # (a) made any HANDOFF-MARK past the first long row unreachable — so
  # --mark-handoff could never clear the block, an unkillable phantom block —
  # and (b) left the gate blind to real unpresented decisions after the abort
  # point, the failure presenting as a false positive that masks a dark gate.
  # Fix: a chunk that FILLS the cap did not see a newline, so it is a
  # CONTINUATION of the current row — append it and keep reading. A chunk
  # SHORTER than the cap hit a newline or EOF, so the logical line is complete
  # — classify it and reset the buffer. Under LC_ALL=C, read -n 512 returns
  # exactly 512 bytes iff it stopped on the count rather than a delimiter.
  # This also ELIMINATES the F45 kind-forgery vector rather than merely
  # detecting it: a continuation is appended, never classified as an
  # independent row, so it cannot forge a kind. The aggregate byte cap below
  # bounds pathological input — the per-chunk failure was not carrying that.
  logical=""
  while IFS= read -r -n 512 line || [ -n "$line" ]; do
    n=$((n+1)); [ "$n" -le 20000 ] || { deviations_unpresented=1; return 0; }
    # Aggregate BYTE cap (fail-closed): DECISIONS.md is append-forever, so no
    # cap is sized to "legal input". A ledger past the cap is not scannable in
    # the hook's budget — surface it as a block, not a silent pass. ${#line} is
    # bytes here (LC_ALL=C above); the +1 charges for the newline/EOF delimiter.
    bytes=$((bytes + ${#line} + 1))
    [ "$bytes" -le "$DECISIONS_MAX_BYTES" ] || { deviations_unpresented=1; return 0; }
    logical="${logical}${line}"
    # Cap-filling chunk → mid-row, keep accumulating (see CONTINUATION note).
    [ "${#line}" -ge 512 ] && continue
    _dec_line "$logical"
    logical=""
  done < "$f"
  # Flush a final row left mid-accumulation at EOF: a file ending on a cap-fill
  # chunk with no trailing newline exits the loop with the buffer unprocessed.
  [ -z "$logical" ] || _dec_line "$logical"
}

# --- enumerate pending sentinels (builtin glob; no `find` dependency) --------
# Partition: blocking = mine + unowned; foreign = someone else's (report only).
# A payload with no session_id makes every sentinel unowned → pre-0.4 behavior.
pending=""
foreign=""
foreign_n=0
shopt -s nullglob
for f in "$opdir/pending"/*; do
  # -f, not -e: a directory named into pending/ would otherwise be read as a
  # sentinel and emit a raw bash error as operator guidance.
  [ -f "$f" ] || continue
  name="${f##*/}"
  owner="$(sentinel_owner_of_name "$name")"
  # The TASK id is the name minus the owner prefix — what the operator types
  # into ops-verdict.sh, so report that rather than the on-disk name.
  id="${name#*__}"
  if [ -n "$owner" ] && [ -n "$session" ] && [ "$owner" != "$session" ]; then
    # Name the OWNER, not just the task: with three or more sessions a bystander
    # otherwise cannot tell which session to chase. The opened-at stamp is gone
    # with the body parser — it was the one field that needed reading a file, and
    # task+owner is what makes the report actionable.
    foreign="${foreign:+$foreign; }$id owned by $owner"
    foreign_n=$((foreign_n + 1))
  else
    pending="${pending:+$pending, }$id"
  fi
done
shopt -u nullglob

# Foreign tasks stay VISIBLE — that visibility is what made the collision
# diagnosable in the field — but they never block.
if [ -n "$foreign" ]; then
  echo "operator: $foreign_n pending verdict(s) owned by another session ($foreign) — not blocking." >&2
fi

# --- deviation gate: unpresented decisions block Stop (stage 2) ---------------
# Runs alongside the sentinel check; either can block. scan_deviations sets
# deviations_unpresented (mine+unowned deviations after the last mark) and
# deviations_scan_failed (absent/unreadable ledger → fail OPEN). A session_id
# of "" makes every DEVIATION unowned → every one blocks (pre-gate lines are
# real unpresented decisions), mirroring the unowned-sentinel default.
scan_deviations "$opdir/DECISIONS.md" "$session"

if [ -n "$pending" ]; then
  # Name a path that resolves from the project cwd: ops-init installs the
  # verdict CLI at .operator/bin/. Fall back to this hook's own sibling (the
  # plugin copy, absolute) for projects scaffolded by an older ops-init.
  verdict_cmd=".operator/bin/ops-verdict.sh"
  if [ ! -f "$opdir/bin/ops-verdict.sh" ]; then
    case "${BASH_SOURCE[0]}" in
      */*) script_dir="${BASH_SOURCE[0]%/*}" ;;
      *)   script_dir="." ;;                    # invoked bare: script is in cwd
    esac
    script_dir="$(cd "$script_dir" 2>/dev/null && pwd)" || script_dir=""
    if [ -n "$script_dir" ]; then verdict_cmd="$script_dir/ops-verdict.sh"; fi
  fi
  echo "operator: pending verdict(s): $pending — run $verdict_cmd <id> <criterion> <evidence> <PASS|FAIL>, or --defer \"<reason>\"" >&2
  exit 2
fi

# No pending sentinels — but unpresented deviations still block. Name the
# clearing command (the verdict CLI's --mark-handoff, same path resolution as
# above). deviations_scan_failed=1 means the ledger was absent/unreadable: fail
# OPEN (a missing ledger is a scaffold problem, not an unpresented decision).
if [ "$deviations_scan_failed" = 0 ] && [ "$deviations_unpresented" -gt 0 ]; then
  verdict_cmd=".operator/bin/ops-verdict.sh"
  if [ ! -f "$opdir/bin/ops-verdict.sh" ]; then
    case "${BASH_SOURCE[0]}" in
      */*) script_dir="${BASH_SOURCE[0]%/*}" ;;
      *)   script_dir="." ;;
    esac
    script_dir="$(cd "$script_dir" 2>/dev/null && pwd)" || script_dir=""
    if [ -n "$script_dir" ]; then verdict_cmd="$script_dir/ops-verdict.sh"; fi
  fi
  echo "operator: $deviations_unpresented unpresented decision(s) in DECISIONS.md — present them (/cc-operator:handoff or in your reply), then run $verdict_cmd --mark-handoff --owner <session-id>" >&2
  exit 2
fi

exit 0
