# Infographics

Visual explainers for cc-operator. They are **communication material, not
specification** — `templates/OPERATOR.md` is the charter, `CLAUDE.md` the map,
and this file loses to both on any disagreement.

Two of the three describe a **target state** ("CC Operator 2.0") rather than the
shipped plugin. That distinction is load-bearing here of all places: this
project's own rule is that a claim without evidence is FAIL by definition, and a
diagram is a claim with unusually good graphic design. Each sheet below carries
what it actually depicts, and the roadmap sheets carry a per-property status
table pointing at the issue that would close it.

## Files

| File | Language | Depicts |
|---|---|---|
| `img/cc-operator-overview-nl.png` | Dutch | The shipped model, conceptually — one AI vs. a reviewed team |
| `img/cc-operator-2.0-nl.png` | Dutch | Target state ("2.0") |
| `img/cc-operator-2.0-en.png` | English | Target state ("2.0"), same content as the Dutch sheet |

---

## 1. Overview — what cc-operator is

![cc-operator overview: from one AI coder to a reviewed team, seven steps from research to approved-and-done](img/cc-operator-overview-nl.png)

The closest of the three to what ships today. The seven-step spine (research →
plan → build → evidence → review → adversarial check → done) is the charter's
own flow, the construction-crew analogy maps onto the seat model
(`agents/op-*.md`), and "REFUTED = stop, full stop" is literally how
`workflows/review.js` treats the adversarial seat: a REFUTED verdict never
enters the scoring pool and cannot be outvoted.

One caveat a reader should carry: *"nothing is marked done without evidence"*
describes the mechanism the gate provides, not a law it can enforce. The
evidence gate is **opt-in at the mechanism level** — nothing forces a sentinel
to be opened in the first place (`ops-task.sh` makes it one command; it does not
close the hole). That limitation is recorded in `CLAUDE.md` and is not
new.

---

## 2. CC Operator 2.0 — the target state

![CC Operator 2.0: ten steps from intent to CI attestation, with an evidence chain, isolation model and adaptive reviewers](img/cc-operator-2.0-en.png)

Dutch edition: [`img/cc-operator-2.0-nl.png`](img/cc-operator-2.0-nl.png).

**This is a roadmap, not a changelog.** Read as shipped capability it would
overstate the product on five separate axes. Each row below says what exists
today and what would close the gap. Rows are updated as things land, not
deleted: **last checked against the tree at 0.8.4** (2026-08-16), when #23 went
from unimplemented to opt-in-and-never-run-live, #14 from open to
order-fixed-but-not-atomic, and #24 from unbuilt to measured-and-declined. A
row that stops being checked is the drift this repo keeps finding elsewhere.

| The sheet claims | Today | Closes it |
|---|---|---|
| Arm-gate layer G1/G2/G3 | **Shipped in 0.7.0.** G2 is **opt-in** (`.operator/armgate.on`, absent by default) and `Bash` is ungated by design — the threat model is forgetting, not evasion | the remaining hole is G4 |
| "Evidence tied to exact source-state: commit SHA, **tree SHA**, command, **exit code**, **timestamp**, **output hash**" | Partly. A verdict row is stamped `@<sha>` / `+dirty` / `+unknown` / `@no-commit` / `@no-vcs`. **No** tree sha, exit code, timestamp or output hash — and the stamp is provenance ("this row was written from that tree"), never attestation ("that tree passes") | [#22](https://github.com/betmoar/cc-operator-plugin/issues/22) |
| "Independent verification environment — clean checkout / container, isolated from builder state" | **Partly implemented (0.8.4), opt-in.** `args.isolate=<sha>` runs the adversarial seat in a git worktree of a named commit; the seat re-derives `git rev-parse HEAD` there and REFUTES on a mismatch. Default is still the builder's tree, and the bound is stated in the result: same filesystem, `$HOME`, caches and PATH, so it defeats in-tree artifacts (the measured `__pycache__` case) and not a poisoned global cache. **Never run live** — the cases pin what the workflow dispatches, not that the harness builds the worktree | [#23](https://github.com/betmoar/cc-operator-plugin/issues/23) |
| "Security Reviewer" and "Dependency Reviewer" seats | **Not implemented, and DECIDED against (0.8.2, #24 closed).** `workflows/review.js` still dispatches a fixed five lenses unconditionally. A security fixture corpus was built and the five were measured against it: they detected 5/5, so a dedicated seat had no headroom to buy. What the measurement changed instead was a tier — `correctness` moved to JUDGMENT, taking coverage 4/5 → 5/5. #70 reached the same verdict for a drift seat in 0.8.4. A dependency lens remains unbuilt and unmeasured | [#24](https://github.com/betmoar/cc-operator-plugin/issues/24) |
| "CI attestation — cryptographically signed, externally reproducible" | **Not implemented.** BAR blocks are hand-written prose with no schema, and neither CI workflow reads the ledger | [#25](https://github.com/betmoar/cc-operator-plugin/issues/25) |
| "Audit trail 2.0 — hash chain, atomic writes" | **Partly closed (0.8.4).** Still no hash chain and still two appends, not one atomic act — but the ORDER now decides which half survives a crash: the `GATE-EXCEPTION` is written BEFORE the row, so an interrupted write leaves an exception a retry completes, instead of a row a retry misreads as an amendment. The audit line is no longer the half that is lost | [#14](https://github.com/betmoar/cc-operator-plugin/issues/14) |

What the sheet gets right about direction: the chain *intent → BAR → source
state → execution → evidence → verdict → attestation* is the correct spine, and
it is the one the open unknowns are organized around. The gap between the
picture and the tree is the backlog, stated honestly rather than sanded off.

## Updating these

The sheets are exported images with no source in this repo, so a correction
means re-exporting and replacing the file. If a claim on a sheet becomes true,
move its row out of the table above rather than deleting the row — a reader
should be able to see that the question was asked and how it was settled, which
is the same rule `docs/UNKNOWNS.md` applies to closing an unknown.
