# shellcheck shell=bash
# shellcheck disable=SC2034  # the caps_* globals are consumed by the SOURCING script
# lib/caps.sh — the ONE implementation of the cap-trip detector (#107).
#
# WHAT IT CLOSES. templates/OPERATOR.md's Cap table declares three caps and
# calls a trip "a defined stop-and-report, not a judgment call". Measured
# 2026-09-07, before this file existed:
#
#   $ grep -rn 'Identical-rejection\|rework\|Neighbor-regress' scripts/ hooks/
#   (no output)
#
# Nothing read, counted, or reported any of them. They were instructions to a
# model, which is the category the charter exists to escape — the same shape as
# the evidence gate before #85 auto-armed it, and as the sibling project's
# watchdog incident (a dispatcher re-validated ONE rejected pull request 68
# times in three and a half hours; every individual tick was correct and the
# pathology lived entirely in the SEQUENCE, which nothing was looking at).
#
# WHAT IT COVERS, AND WHAT IT DELIBERATELY DOES NOT. One of the three caps is
# derivable from the ledger this repo already writes. The other two are not,
# and saying so is the point — an uncovered cap recorded as covered is worse
# than an uncovered cap.
#
#   same-target-rework x2   COVERED here. A repeat FAIL on the same
#                           (task-id, criterion) IS two rework rounds on one
#                           target: the row schema carries both cells.
#
#   identical-rejection x2  UNCOVERED, and it needs a SCHEMA decision first.
#                           The cap is "the same REVIEWER rejects the same
#                           target twice", and a VERDICTS.md row carries no
#                           reviewer identity. The row is deliberately 4-cell
#                           (templates/VERDICTS-header.md); a fifth column
#                           breaks validate_plugin.VERDICTS_HEADER and every
#                           ledger already in the field. Encoding the reviewer
#                           inside the evidence cell would make the detector
#                           depend on a convention nothing enforces, which is
#                           a detector that reports on prose. Left open.
#
#   neighbor-regressing x2  UNCOVERED, and NOT for want of a column. The cap is
#                           "a fix round REGRESSED a previously-passing check",
#                           and causation is the load-bearing word: the ledger
#                           records that criterion Y failed, never that a fix
#                           to X caused it. A PASS->FAIL flip is the nearest
#                           observable and it is not the same claim — a flip
#                           happens whenever the tree moves, which is most
#                           rounds. Reporting a flip AS this cap would be a
#                           detector that is precisely correct about the wrong
#                           question, and this file would then read as though
#                           two of three caps were covered.
#
# POLARITY — REPORT-ONLY. It never blocks Stop, never writes, never exits
# non-zero. Two reasons, and the second is decisive:
#
#   1. The charter makes a cap trip the OPERATOR's stop-and-report, not the
#      gate's. Blocking would substitute the tool's judgment for the decision
#      the cap exists to prompt.
#   2. VERDICTS.md is APPEND-ONLY with a single writer, so a tripped key can
#      never be un-tripped by removing a row. A blocking detector over a
#      permanent history is a permanent block — autobar's infinite-block
#      failure one layer up, and worse, because there nothing prevented the
#      operator from clearing the sentinel and here nothing could clear
#      anything at all. A session that cannot end is the failure a user
#      resolves by deleting the plugin (#123 C states the same polarity for
#      the same reason).
#
# So this is NOT the partition.sh case, and the statusline does NOT read it:
# the bar renders whether a stop will BLOCK, and a report-only scan changes no
# blocking state. There is nothing here for the bar to disagree with.
#
# A LATER PASS RESETS THE KEY, and that is what makes the signal usable rather
# than permanent noise. Two FAILs followed by a PASS is a rework that WORKED;
# reporting it forever would fire on every mature ledger from its first
# repeated failure to the end of the project, and a line that is always there
# is a line nobody reads. Forward pass, order matters — the same asymmetry
# scan_deviations applies to HANDOFF-MARK.
#
# ONE SOURCE: VERDICTS.md. DECISIONS.md carries DEFERRED-VERDICT, which is a
# task closed honestly rather than a round that failed — counting it would
# read an honest exit as a rework.

# The cap's own number, from the charter's Cap table: "two rework rounds on one
# target". Two FAIL rows on one (id, criterion) ARE those two rounds.
CAPS_REWORK_MAX=2
# Bounds. Both are work limits, not correctness limits: past either, the scan
# reports what it has and SAYS it stopped early (caps_truncated), because a
# silently short scan reports "no caps tripped" — indistinguishable from a
# clean ledger, which is the failure class this whole file exists to end.
# The key table is scanned linearly per row (bash 3.2 has no associative
# arrays and macOS ships 3.2), so the ceiling on work is rows x keys; a key is
# only ever created by a FAIL, so a ledger of passes costs a zero-iteration
# lookup per row.
CAPS_MAX_KEYS=100
CAPS_MAX_LINES=20000
CAPS_MAX_BYTES=2097152   # 2 MiB — orders above any honest verdict ledger

# THE STEP BUDGET, and it exists because the three bounds above do not bound
# the WORK. Their product does: rows x keys. Measured 2026-09-07 on this
# machine, against a ledger at exactly those bounds (20,000 rows across 100
# distinct failing targets — reachable by an ordinary mature project, not a
# planted file):
#
#   scan_caps alone                       10.2s
#   the Stop hook carrying it             11.1s
#   the same 20,000 rows on ONE key        1.9s   (the row parse alone)
#
# So ~9s of it is the lookup, and every Stop paid it. A gate whose own cost
# grows with the ledger it audits is a gate that gets removed — the same
# reasoning CR5 applied to the statusline's 300ms render budget, one file over,
# except this one had no budget at all and the header claimed a measurement it
# never carried.
#
# An associative array would delete the term, and bash 3.2 does not have one
# (macOS ships 3.2 and this repo tests against it). A string-keyed table was
# measured as the portable alternative and is 20x WORSE: 3m28s on the same
# input, because each lookup rescans a growing string. So the linear array
# stands and the WORK is capped directly.
#
# 200,000 steps measured at 2.1s here, so this budget holds the lookup near
# ~1s on this machine and degrades honestly rather than silently: hitting it
# sets caps_truncated, exactly like the other three bounds, and the caller says
# the report is a floor. A missed report costs a line of guidance; an
# 11-second Stop costs the whole gate.
CAPS_MAX_STEPS=100000

# Sets: caps_tripped (count of targets at or over the cap), caps_rows (one
# "<n> FAIL rounds: <id> | <criterion>" line each — the CALLER sanitizes and
# truncates them; they are untrusted project data), caps_truncated (1 = a
# bound stopped the scan early), caps_scan_failed (1 = no readable ledger).
scan_caps() { # scan_caps <verdicts-path>
  local f="$1" row body id crit ev verdict key r1 r2 i n=0 bytes=0 found steps=0
  # `local LC_ALL=C` so `read -n N` counts BYTES not characters (bash counts
  # CHARACTERS outside the C locale, so the cap would be up to 4x looser than
  # it reads) and so nothing leaks to the sourcing script — the idiom
  # scripts/lib/partition.sh uses.
  local LC_ALL=C
  caps_tripped=0
  caps_rows=""
  caps_truncated=0
  caps_scan_failed=0
  _caps_k=()
  _caps_c=()
  _caps_n=0
  # Absent or symlinked ledger: nothing to report. Report-only, so there is no
  # fail-closed direction to choose here — a missing ledger is a scaffold
  # state, and `-f` follows a link, so the link is refused rather than scanned
  # through (the F65 class).
  [ -f "$f" ] || { caps_scan_failed=1; return 0; }
  [ ! -L "$f" ] || { caps_scan_failed=1; return 0; }
  # The max legal bound (validate_plugin._MAX_READ_BOUND), read the way
  # ops-reverify.sh reads the same file: no continuation accumulation. A row
  # longer than 1 MiB is split, and the tail does not start with "| " so it is
  # dropped — which costs a missed REPORT, never a false one, and matches the
  # polarity above. Accumulating instead would buy a case no writer of ours
  # can produce.
  while IFS= read -r -n 1048576 row || [ -n "$row" ]; do
    n=$((n + 1))
    if [ "$n" -gt "$CAPS_MAX_LINES" ]; then caps_truncated=1; break; fi
    bytes=$((bytes + ${#row} + 1))
    if [ "$bytes" -gt "$CAPS_MAX_BYTES" ]; then caps_truncated=1; break; fi
    # A ledger ROW starts "| " and is not the header or its rule.
    case "$row" in "| "*) ;; *) continue ;; esac
    case "$row" in "| Gate | Criterion |"* | "|---"*) continue ;; esac
    # EXACTLY four cells — `| id | criterion | evidence @stamp | verdict |`,
    # the schema ops-verdict.sh --reconcile enforces. Split on " | "; anything
    # else is skipped, never guessed at.
    body="${row#| }"; body="${body% |}"
    id="${body%% | *}";   r1="${body#* | }"
    crit="${r1%% | *}";   r2="${r1#* | }"
    ev="${r2%% | *}";     verdict="${r2#* | }"
    [ "$r1" != "$body" ] || continue
    [ "$r2" != "$r1" ] || continue
    [ "$verdict" != "$r2" ] || continue
    [ -n "$ev" ] || continue
    case "$verdict" in *" | "*) continue ;; esac
    case "$verdict" in PASS | FAIL) ;; *) continue ;; esac
    # The key. Both halves are pipe-free and newline-free by construction —
    # ops-verdict.sh's check_cell refuses both in every cell — so " | " cannot
    # be forged inside either half and the join is unambiguous.
    key="$id | $crit"
    found=-1
    i=0
    while [ "$i" -lt "$_caps_n" ]; do
      if [ "${_caps_k[i]}" = "$key" ]; then found="$i"; break; fi
      i=$((i + 1))
    done
    # The step budget is charged HERE, where the work actually is, and it is
    # charged whether the lookup hit or missed — a budget that only counts
    # misses is not a budget. Checked AFTER this row is classified below, so
    # the row that exhausts it is still counted rather than half-read.
    steps=$((steps + i))
    if [ "$verdict" = PASS ]; then
      # A PASS RESETS. Only a key we are already tracking: a PASS on a target
      # that never failed creates nothing, which is what keeps the table small
      # on an ordinary ledger.
      [ "$found" -ge 0 ] && _caps_c[found]=0
      continue
    fi
    if [ "$found" -ge 0 ]; then
      _caps_c[found]=$(( _caps_c[found] + 1 ))
    elif [ "$_caps_n" -lt "$CAPS_MAX_KEYS" ]; then
      _caps_k[_caps_n]="$key"
      _caps_c[_caps_n]=1
      _caps_n=$((_caps_n + 1))
    else
      # Past the key ceiling: this FAIL is uncounted. Say so rather than
      # letting the report read as complete.
      caps_truncated=1
    fi
    if [ "$steps" -gt "$CAPS_MAX_STEPS" ]; then caps_truncated=1; break; fi
  done < "$f"
  # The report is built AFTER the whole pass, never during it: a key that hit
  # the cap and was then cleared by a PASS must not appear, and mid-pass
  # emission cannot take that back.
  i=0
  while [ "$i" -lt "$_caps_n" ]; do
    if [ "${_caps_c[i]}" -ge "$CAPS_REWORK_MAX" ]; then
      caps_tripped=$((caps_tripped + 1))
      caps_rows="${caps_rows}${_caps_c[i]} FAIL rounds: ${_caps_k[i]}
"
    fi
    i=$((i + 1))
  done
}
