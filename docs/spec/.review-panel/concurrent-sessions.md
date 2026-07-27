# Panel run — concurrent-sessions.md  (2026-07-27 05:20)

- **artifact:** `docs/spec/concurrent-sessions.md`     **reviewer:** glm-review-design     **N:** 3
- **lenses:** A ambiguity · B contradictions/feasibility · C testability
- **per-lens:** A → 21 findings · B → 7 · C → 12   (tokens: not reported by the harness — `subagent_tokens` came back 0 for all three; omitted rather than guessed)
- **buckets:** must-resolve 4 · should-clarify 0 · consider 5 · dropped <50: 31
- **asked:** none — the 60–74 band was empty after scoring (see note)
- **verdict:** The doc's "Implemented (0.4.0)" amendments hold up against the code on every
  load-bearing mechanism. What failed was the *edges*: one acceptance criterion asserted an absolute
  the system deliberately does not provide, and three shipped details drifted from the proposal text.
  All four fixed. One live bug surfaced (subdirectory gate bypass) — pre-existing on `main`, scoped out.

## Why no clarify round

The `should-clarify` bucket is where a panel asks the user to decide. It came out empty here, which
is worth stating rather than glossing: every finding that scored 60–74 was either (a) a fact I could
verify myself in under a minute, or (b) a limitation this branch had already made a deliberate,
documented call on (adopt-then-close, the reclaim overrun window, fragments-not-for-DECISIONS).
Neither shape is a question for the user. Manufacturing four questions to fill the round would have
been ceremony.

## Findings

### must-resolve

- **[85] §5 criterion 3 asserted an absolute the doc itself retracts 18 lines later** (lens C, corroborated by lens B).
  Criterion 3 read "B never gained the ability to close X"; the §5 amendment then documents that
  `ops-adopt.sh` lets B adopt-then-close, and `tests/test-scripts.sh` asserts that path *works*. The
  suite therefore asserted the criterion and its negation. **This was mine** — I documented the adopt
  limitation without going back to reconcile the criteria list.
  → Criterion 3 rewritten to be true as stated: scoped to the writer, with the adopt door named inline.

- **[80] The foreign-task report named task ids but not owners** (lens A + lens B).
  §4.1's example message always showed `(axis3-phase1, opened 22:24)`; the shipped hook emitted only
  the id. With three or more sessions a bystander could not tell which session to chase.
  → Fixed in the code rather than the doc, because the doc's version is the more useful one.
  `sentinel_owner` now returns `owner|opened_at` from the *same* bounded pass — a second read per
  sentinel on every Stop event is exactly the cost the byte bound exists to avoid. Two assertions added.

- **[75] `.gitattributes` scope understated** (lens B). Doc said "both ledgers"; `ops-init.sh` writes
  three patterns, and the third (`verdicts.d/*.md`) is load-bearing for the §4.4 repair claim.
  → Doc corrected to name all three. Two assertions added — `DECISIONS.md merge=union` and the
  fragments pattern were written but asserted by **nothing**.

- **[75] The sentinel schema omitted `adopted_at:`** (lens B). §4.1 lists three fields; `ops-adopt.sh`
  writes a fourth. A reader auditing a sentinel would not know the field is legitimate.
  → Added to the schema block, marked as adopted-only.

### consider (recorded in the doc, not fixed)

- **[70] Lock exclusivity under reclaim is verified by code review, not by the suite** (lens C).
  No test distinguishes the shipped exclusive-reclaim from the naive `rmdir`+`mkdir`; reproducing it
  needs two writers timing out simultaneously. Now stated explicitly in §5's "what a green suite does
  NOT prove" list. Leaving a non-discriminating test unlabelled is how a green run comes to mean nothing.

- **[65] The bounded-parse test does not discriminate at 32 MB** (lens C). Unfixed takes ~1s there,
  under the 3s threshold; the cost is linear (256 MB = 8.5s unfixed vs 0.16s fixed). Discriminating
  would put a quarter-gig of writes in every CI run. Accepted and labelled, not fixed.

- **[60] `cwd`-is-not-a-discriminator is asserted nowhere** (lens C). §4.2's argument rests on the hook
  never comparing the stamped `cwd`; a regression making it enumerate by its own `$PWD` would silently
  reintroduce the worktree-collision shape. Recorded as a gap.

- **[60] `--reconcile` admits both rows when one task id's evidence diverged across branches** (lens A).
  Verified: dedup is by exact line, so `merge=union` plus an edited evidence cell yields two rows.
  Recorded; hand-resolution is the honest answer.

- **[55] Owner-id uniqueness is an unstated assumption** (lens A). Two sessions sharing an owner id
  share a fragment file. Recorded.

### out of scope (real, verified, not this branch's)

- **[90] A session whose payload `cwd` is a subdirectory bypasses the gate entirely** (lens A).
  Reproduced: hook exits 0 with tasks still open. Then checked `main` — **pre-existing**, not a
  regression from ownership. Recorded in the doc's gaps list; fixing it belongs in its own change,
  not smuggled into a concurrency PR.

## Dropped (<50)

31 findings, the bulk of lens A's `[l]` tier. The recurring shapes: stale `path:line` citations the
doc *already discloses* at line 4 as 0.3.0-relative (not a defect); requests to specify behavior the
code already specifies correctly (mode-000 sentinels, giant sentinels, pre-0.4 re-open) where the
ask was for prose, not a fix; and lens B's own reasoning, which twice talked itself out of a finding
after checking the code — correctly.

Lens B never emitted its final formatted report; its reasoning trace was complete enough to extract
findings from, and each was independently verified before acting. Scored on the findings, not the
formatting.
