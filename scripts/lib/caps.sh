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
#
# THE SCHEMA COUPLING, and it is a LIMITATION, not a guard. This file is the
# SECOND reader of ops-verdict.sh's 4-cell row (ops-reverify.sh is the first),
# and it skips any row it cannot split into exactly four cells. That is right
# for a hand-edit — no writer of ours produces one — and WRONG for a schema
# change: a 5-cell row is silently uncounted, so widening the row turns this
# detector off with every gate green. Measured 2026-09-07: a 5-cell ledger
# carrying two rework rounds reports tripped=0, truncated=0.
#
# A new VERDICT WORD is the same hole from the other side. The reset branch
# tests `= PASS`, so anything else is counted as a failing round — a MOOT row
# (issue #91's proposal for a criterion that stopped being answerable) would
# read as a rework rather than resolving one.
#
# Neither is fixable here: this file cannot know what the writer will emit
# next. The fix is at the writer, so CLAUDE.md's coupling row for the 4-cell
# printf names BOTH parsers, and the two cases in the suite pin the blindness
# so the next schema change reads it there instead of in the field.

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
# sets caps_truncated, exactly like the other three bounds, and the caller
# reports the cap state as UNKNOWN — not as a floor. (This line SAID floor
# until PR #126's Copilot round; the adversarial round below had already
# changed the behaviour and left the reason at the top of the file
# unamended. A comment describing the design a rewrite replaced is the same
# defect as a stale pin, one layer up: the next reader trusts it and the
# measured 60-targets-reported-where-zero-was-true finding reads as fixed
# by a floor that no longer exists.) A missed report costs a line of
# guidance; an 11-second Stop costs the whole gate.
CAPS_MAX_STEPS=100000

# WHAT THE BUDGET DOES NOT BUY, stated because the numbers above are the
# WORST case and the worst case is not the one a project lives in. Measured
# 2026-09-07, a realistic shape (25 task ids x 2 criteria = 50 keys, mostly
# PASS rows), five runs each, whole scan, no truncation until the last row:
#
#     500 rows   0.12s        3000 rows   1.2s
#    1000 rows   0.4s         5000 rows   1.9s (truncated)
#      48 rows   0.05s   <- this repo's own ledger after 40+ verdicts
#
# So a few thousand rows costs ~1-2s ON EVERY STOP, and that is real. There
# is no stated wall-clock budget for this hook (the statusline has CR5's
# 300ms; the Stop hook has never had one), so "within budget" is not a claim
# available here — the honest statement is that the cost is bounded, paid
# every time, and unmeasured against any agreed limit.
#
# Two cheaper designs, neither taken, both with a reason:
#
#   TAIL WINDOW (what statusline.sh does). Reading the last N rows conflicts
#   with the reset rule: a PASS that clears a key can sit anywhere, so a tail
#   scan reports caps that were resolved long ago. A false report is worse
#   than a missed one here — this gate's whole credibility is that it does
#   not cry wolf.
#
#   MTIME CACHE. The ledger is append-only with a single writer, so an
#   unchanged mtime means an unchanged answer. This is the real fix and it is
#   its own piece of work, with its own failure mode: a stale cache is a gate
#   that silently stopped running, which is the exact class this file exists
#   to end. Tracked as issue #127 rather than half-built here.

# Sets: caps_tripped (count of targets at or over the cap), caps_rows (one
# "<n> FAIL rounds: <id> | <criterion>" line each — the CALLER sanitizes and
# truncates them; they are untrusted project data), caps_truncated (1 = a
# bound stopped the scan early), caps_scan_failed (1 = no readable ledger).
scan_caps() { # scan_caps <verdicts-path>
  local f="$1" row body id crit ev verdict key r1 r2 i n=0 bytes=0 found steps=0
  # The key table is INTERNAL state, and it must be local (PR #126 review,
  # Copilot). Only the caps_* globals are outputs; `_caps_k`/`_caps_c`/`_caps_n`
  # were plain assignments, so sourcing this lib silently clobbered any caller
  # variable of the same name — measured: a caller's `_caps_n=KEEP_ME` came
  # back 0 and its `_caps_k` array was emptied. A lib that overwrites its
  # host's namespace is the class `local LC_ALL=C` already exists to avoid,
  # one variable over.
  local -a _caps_k=() _caps_c=()
  local _caps_n=0
  # `local LC_ALL=C` so `read -n N` counts BYTES not characters (bash counts
  # CHARACTERS outside the C locale, so the cap would be up to 4x looser than
  # it reads) and so nothing leaks to the sourcing script — the idiom
  # scripts/lib/partition.sh uses.
  local LC_ALL=C
  caps_tripped=0
  caps_rows=""
  caps_truncated=0
  caps_scan_failed=0
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
    # The header is matched WHOLE, not by prefix (PR #126 review, Copilot).
    # `"| Gate | Criterion |"*` discards any row whose id is `Gate` and whose
    # criterion is `Criterion` — and ops-task.sh permits that id, so it is a
    # real ledger a real project can write. Measured: two FAIL rounds on task
    # `Gate` / criterion `Criterion`, written through the CLI, reported
    # tripped=0. A false NEGATIVE in a detector whose whole job is not to miss
    # a sequence.
    #
    # The full header line cannot collide: its fourth cell is `PASS/FAIL`,
    # which the verdict enum below refuses (a row's verdict is exactly `PASS`
    # or `FAIL`), so even an exact-match escape would be caught one test
    # later. Prefix-matching was the only thing making the collision reachable.
    case "$row" in
      "| Gate | Criterion | Evidence | PASS/FAIL |" | "|---"*) continue ;;
    esac
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
    #
    # `i + 1`, NOT `i`, and the difference is not cosmetic (PR #126 review,
    # Copilot). The loop COMPARES element `i` and then breaks, so a hit at
    # index `i` costs `i + 1` comparisons; charging `i` bills a hit at index 0
    # as FREE. Measured on a 19,000-row ledger where every row hits the first
    # key: charged 0 against 18,999 real comparisons — the budget was not off
    # by one, it was off by everything, and the scan ran 2.9s with
    # `caps_truncated=0` claiming it had stayed inside its bound. With 100 keys
    # created first and 19,000 hits after: charged 4,950 against 23,950 real.
    # A bound that under-bills the common case is a bound in name only, which
    # is the same class as the size-bounds-are-not-work-bounds defect this
    # budget was added to fix — one level down, in the accounting itself.
    steps=$((steps + i + 1))
    if [ "$verdict" = PASS ]; then
      # A PASS RESETS. Only a key we are already tracking: a PASS on a target
      # that never failed creates nothing, which is what keeps the table small
      # on an ordinary ledger.
      [ "$found" -ge 0 ] && _caps_c[found]=0
    elif [ "$found" -ge 0 ]; then
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
    # THE BUDGET CHECK COVERS EVERY PATH, and it did not (PR #126 review,
    # Copilot). The PASS branch charged its lookup and then `continue`d, right
    # past this test — so a PASS-heavy ledger paid for the work and never
    # enforced the bound. Measured on 100 keys plus 19,000 PASS rows that walk
    # the table: 964,550 steps charged against a 100,000 budget — 9x over,
    # `caps_truncated=0`, 10.6 SECONDS. That is the entire DoS the budget was
    # added to fix, restored through the one branch that skipped the check.
    #
    # A PASS is not cheaper than a FAIL: both do the same linear lookup, and
    # only what happens AFTER the lookup differs. So the branches are now a
    # single if/elif chain with no `continue`, and this line is the sole exit —
    # one check on the one path every row takes. `continue` in a loop whose
    # tail carries the guard is the shape to distrust: it reads as "skip the
    # rest of the work" and means "skip the rest of the guards".
    #
    # THE KEY CEILING IS ALSO AN EXIT, and it was not (PR #126 review, Copilot).
    # The `else` above sets caps_truncated and fell through, so the scan kept
    # walking a FULL 100-key table for every remaining row — and the answer was
    # already thrown away, because a truncated scan returns before it builds any
    # report (the prefix-is-not-a-floor rule below). Every one of those lookups
    # bought nothing. Measured on a 20,000-row ledger of distinct failing
    # targets, which hits the ceiling at row 100: 0.97s before, 0.14s after —
    # 7x, on the shape a project with many one-off task ids actually has. The
    # step budget did bound it, so this was waste rather than a DoS; that is why
    # it is one condition at the SAME sole exit and not a second `break`
    # upstream. The condition, not the branch, is what generalises: any future
    # writer of caps_truncated inside this loop stops here too.
    if [ "$caps_truncated" = 1 ] || [ "$steps" -gt "$CAPS_MAX_STEPS" ]; then
      caps_truncated=1
      break
    fi
  done < "$f"
  # The report is built AFTER the whole pass, never during it: a key that hit
  # the cap and was then cleared by a PASS must not appear, and mid-pass
  # emission cannot take that back.
  #
  # AND A TRUNCATED PASS IS NOT A WHOLE PASS. That invariant holds only when
  # the scan reached EOF. Break early on any bound and the unread tail may
  # carry the very PASS rows that clear these keys, so the counts describe a
  # PREFIX, not the ledger. Measured (PR #126 adversarial review, Codex): 60
  # keys failed repeatedly, then a PASS for every one of them past the step
  # budget — reported tripped=60 where the true final state is ZERO, and it
  # recurs on every Stop because the same prefix is rescanned. The operator is
  # told to stop reworking sixty targets they already fixed.
  #
  # So a truncated scan reports the count as UNKNOWN rather than as a floor:
  # caps_tripped stays 0 and caps_rows stays empty, and caps_truncated (already
  # set) is what the caller speaks to. Calling it a FLOOR was the error — a
  # floor claims "at least this many", and a prefix cannot claim even that.
  #
  # Polarity: this drops a real trip when a ledger is genuinely over the
  # bounds, which is the RIGHT direction for a report-only gate. A missed
  # report costs one line of guidance; a confidently wrong one costs the
  # operator's trust in every line the gate prints, and it is the failure that
  # gets a gate ignored. The truncation notice still fires, so the state is
  # "I could not finish reading" — never silence.
  if [ "$caps_truncated" = 1 ]; then
    return 0
  fi
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
