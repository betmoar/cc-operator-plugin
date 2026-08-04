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

# --- read a sentinel's stamped owner (builtins only; no grep/sed) ------------
# "" when the file has no usable session_id line — including a pre-0.4 empty
# sentinel. "" means unowned, which BLOCKS every session: the safe direction,
# so every degenerate body (unreadable, malformed, binary) fails closed.
#
# Two guards worth keeping:
#  - trailing \r/whitespace is stripped. A CRLF checkout would otherwise make a
#    session's OWN task compare unequal to its id and be waved through as
#    foreign — a fail-OPEN in the central invariant.
#  - the scan is bounded in lines AND in bytes per line. This runs on EVERY
#    session's Stop event, so an unbounded read stalls every turn-end in the
#    tree. A line cap alone is not a bound: a single newline-less line is one
#    "line" and `read -r` consumes all of it first — measured 8.5s for a 256 MB
#    line, the shape a merge artifact or stray binary easily takes. `read -n N`
#    stops at N chars *or* the newline, whichever comes first, so a giant line
#    is truncated instead of slurped. (`read -N` — capital — ignores the
#    newline and proved unreliable here, returning an empty chunk; it would have
#    made every sentinel parse as unowned. Do not "simplify" back to it.)
#    The owner is line 1 by construction, so 512 chars is generous.
# Emits "<owner>|<opened_at>" so ONE bounded pass yields both fields: this runs
# on every session's Stop event, and a second read per sentinel is exactly the
# cost the bound exists to avoid. Callers split on the first '|' — safe because
# an owner containing '|' is rejected below. Not set as a global: the callers
# use $( ), which is a subshell, so a side-effect variable would be discarded.
sentinel_owner() { # sentinel_owner <path> → "owner|opened_at"
  local line owner="" opened="" n=0
  # A symlink is never a sentinel our CLIs wrote (F65): `-f` alone FOLLOWS it,
  # so a planted link would read its target's session_id: as a foreign owner
  # and wave the stop through. Degrade to unowned → BLOCKS everyone — the same
  # fail-closed direction as every other body our writers could not have
  # produced. (The enumeration below still counts the entry as a task; only
  # the ownership claim is voided.)
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
  # Probe the WHOLE file for a NUL, not just the first 512 bytes: a single-shot
  # probe left a NUL past byte 512 undetected, so a padded sentinel smuggled a
  # foreign owner and flipped unowned→foreign, opening the Stop gate (measured
  # on bash 3.2: NUL at byte 656 → owner=EVIL, exit 0). Loop in a LC_ALL=C
  # subshell so BOTH -n and ${#} count BYTES — a bare read prefix leaves ${#}
  # counting characters, and a multibyte first chunk then false-positives a
  # NUL. `read -d ''` returns 0 only on a NUL or a full 512-byte fill; EOF
  # returns non-zero, so the final partial chunk never trips it. (F55 applied to
  # the sentinel parsers; the config readers got it in 22791dc, these did not.)
  # BOUNDED whole-file probe: cap at 40 chunks (20KB) so a 64MB newline-less
  # sentinel cannot stall the scan (the single-shot form was O(1) but missed a
  # NUL past byte 512). A real sentinel is one chunk; exceeding the cap means
  # the file is not ours → fail closed (exit 1 → unowned → blocks), which also
  # bounds where a late NUL can hide. A short chunk (NUL or a genuine <512 EOF)
  # exits 1 too; a full 512-byte chunk continues. EOF ends the loop cleanly.
  if ! (LC_ALL=C _np=0
        while IFS= read -r -d '' -n 512 _nulprobe; do
          _np=$((_np + 1)); [ "$_np" -le 40 ] || exit 1
          [ "${#_nulprobe}" -eq 512 ] || exit 1
        done < "$1") 2>/dev/null; then
    printf '%s' ""
    return 0
  fi
  while IFS= read -r -n 512 line || [ -n "$line" ]; do
    n=$((n+1)); [ "$n" -le 20 ] || break
    # A chunk that FILLS the cap was truncated mid-line: its tail arrives next
    # iteration as a fresh "line" and is matched independently, so one physical
    # line of padding + `session_id: EVIL` claimed ownership and flipped this
    # sentinel from unowned (blocks) to foreign (waves the stop through) —
    # exactly the inversion PLAYBOOK step 2 forbids. On bash 3.2 `read -n` also
    # stops at a NUL, so a padded line need not even reach 512 bytes. Our CLIs
    # write `session_id:` on line 1 and every line well under 512, so a
    # cap-filling chunk cannot be ours: stop reading and leave owner unset,
    # which degrades to "" = unowned = blocks everyone. Fail closed (F45).
    [ "${#line}" -lt 512 ] || { owner=""; opened=""; break; }
    case "$line" in
      "session_id: "*) owner="${line#session_id: }" ;;
      "opened_at: "*)  opened="${line#opened_at: }" ;;
    esac
    [ -n "$owner" ] && [ -n "$opened" ] && break
  done < "$1" 2>/dev/null
  owner="${owner%$'\r'}"
  owner="${owner%"${owner##*[![:space:]]}"}"
  # An owner our CLIs could never have written is not a trustworthy claim of
  # ownership — treat it as unowned so it BLOCKS, rather than as a foreign
  # session's task which would wave the stop through. Must mirror the same
  # rejects as check_bare_name in the three CLIs.
  case "$owner" in
    */* | .* | *"|"* | *[[:space:]]*) owner="" ;;
  esac
  # opened_at is display-only, so it is sanitized rather than rejected: a '|'
  # would break the field split, and a newline cannot survive `read -r` anyway.
  case "$opened" in *"|"*) opened="" ;; esac
  printf '%s|%s' "$owner" "$opened"
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
  # Single forward pass: a mine/unowned DEVIATION increments; a mine/unowned
  # HANDOFF-MARK resets to 0 (it clears everything before it). At EOF the count
  # is exactly the deviations after the last mark = the unpresented set.
  while IFS= read -r -n 512 line || [ -n "$line" ]; do
    n=$((n+1)); [ "$n" -le 20000 ] || { deviations_unpresented=1; return 0; }
    # Aggregate BYTE cap (fail-closed): DECISIONS.md is append-forever, so no
    # cap is sized to "legal input". A ledger past the cap is not scannable in
    # the hook's budget — surface it as a block, not a silent pass. ${#line} is
    # bytes here (LC_ALL=C is not set globally in this hot reader, but each line
    # is ≤512 bytes by the -n bound regardless of locale, so the sum is a sound
    # upper bound on bytes read).
    bytes=$((bytes + ${#line} + 1))
    [ "$bytes" -le "$DECISIONS_MAX_BYTES" ] || { deviations_unpresented=1; return 0; }
    # A cap-filling chunk was truncated mid-line: its tail would parse as a fresh
    # line and could forge a kind. Our scaffold writes short lines, so a 512-fill
    # is not ours → count as unpresented (fail toward blocking). (F45 class.)
    [ "${#line}" -lt 512 ] || { deviations_unpresented=1; return 0; }
    line="${line%$'\r'}"      # a CRLF checkout must not change semantics
    # A DECISIONS row is pipe-delimited: <date> | <eng.task> | <kind> | <what> | <why>
    # Extract kind (field 3) and what (field 4) by splitting on " | " — a glob's
    # `*` would consume the delimiter. Only kind+what matter; the sid lives in
    # the what-cell as a leading [sid:<id>] tag.
    case "$line" in
      *" | "*) ;;
      *) continue ;;            # not a ledger row (header comment, blank, prose)
    esac
    # field 3 (kind): strip the first TWO " | "-delimited cells (date, eng.task).
    # Each `${var#* | }` strips one cell + its delimiter; two of them land on kind.
    kind="${line#* | }"; kind="${kind#* | }"; kind="${kind%% | *}"
    # field 4 (what): the cell holding the leading [sid:<id>] tag. Strip three
    # cells, then cut at the next " | " so only the what-cell remains.
    what="${line#* | }"; what="${what#* | }"; what="${what#* | }"; what="${what%% | *}"
    case "$kind" in
      DEVIATION|ESCALATION|GATE-EXCEPTION)
        # mine = sid tag equals this session; unowned = no sid tag. Both block.
        # A foreign sid tag (≠ session) never blocks. Foreign = report only, and
        # the hook's stderr below does not enumerate these (they are the operator's
        # own decisions, not another session's tasks to chase).
        case "$what" in
          "[sid:$sess]"*) : ;;                      # mine → counts
          "[sid:"*) continue ;;                     # foreign → never blocks
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
  done < "$f"
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
  id="${f##*/}"
  parsed="$(sentinel_owner "$f")"
  owner="${parsed%%|*}"
  opened="${parsed#*|}"
  if [ -n "$owner" ] && [ -n "$session" ] && [ "$owner" != "$session" ]; then
    # Name the OWNER, not just the task: with three or more sessions a bystander
    # otherwise cannot tell which session to chase.
    entry="$id owned by $owner"
    [ -n "$opened" ] && entry="$entry, opened $opened"
    foreign="${foreign:+$foreign; }$entry"
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
