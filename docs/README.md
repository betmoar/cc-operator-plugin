# cc-operator documentation

Start with the [project README](../README.md), which covers install,
prerequisites, the evidence gate, commands, workflows, hooks and the status bar.
This directory holds everything that is too long or too specialised for the
README. It is grouped by who reads it.

Nothing under `docs/` is loaded at runtime. The plugin's behaviour lives in
`templates/`, `scripts/`, `hooks/`, `workflows/`, `agents/` and `commands/`,
and when a document here disagrees with that code, the code wins. The validator
reads only three files in this directory: `design/TAGS.md` (every charter
`[DOC:spec-*]` tag must resolve there), `guide/HANDOUT.md` (its copy of the
dispatch packet is pinned to the charter's) and `maintainer/LANDMINES.md`
(CLAUDE.md's citations must resolve against it).

## guide/ — for users

| File | What it is |
|---|---|
| [HANDOUT.md](guide/HANDOUT.md) | The plain-English handout: tiers, agents, workflows, commands, the engagement cycle, and a walkthrough of a whole session. Read it once, after `/cc-operator:tutorial`. |

## design/ — why it is built this way

| File | What it is |
|---|---|
| [TAGS.md](design/TAGS.md) | Resolves every `[DOC:spec-*]` citation tag in the charter (`templates/OPERATOR.md`) to what the rule means as shipped. Start here when a charter rule is unclear. |
| [CYCLE.md](design/CYCLE.md) | The engagement cycle (diverge → spec → plan → implement → review → gate → handoff): the design record for the spec stage (#155), the implement workflow (#158) and the derived stage (#157), with the plan gate still unbuilt. |
| [DECISION-ENGINE-PROBES.md](design/DECISION-ENGINE-PROBES.md) | The measured record of whether a typed decision engine belongs in the plugin: six surfaces, the filter that decided each, and the constraints if one is ever built. Read before touching #151 or #152. |

## maintainer/ — changing the plugin

Read these together with [CONTRIBUTING.md](../CONTRIBUTING.md) (setup, CI,
release) and [CLAUDE.md](../CLAUDE.md) (the load-bearing map, and the "if you
touch X, update Y" coupling table).

| File | What it is |
|---|---|
| [PLAYBOOK.md](maintainer/PLAYBOOK.md) | Executable procedures for load-bearing changes: adding a guard or a reader, touching the lock or the Stop hook, verifying a fix, writing a locator, running the shell suite under both uids. **Read it before your first change.** |
| [LANDMINES.md](maintainer/LANDMINES.md) | The narrative register of already-hit failure classes: the *why* behind each coupling-table row and each validator pin. Append-only, read on demand; grep a coupling row's first cell to find its entry. |
| [REPLAY-CHARTER.md](maintainer/REPLAY-CHARTER.md) | A live-session audit protocol (R0–R8) for what the suites cannot reach: whether the harness honours the scripts' answers. Its quoted CLI messages are maintained by hand. |
| [UNKNOWNS.md](maintainer/UNKNOWNS.md) | The convention for the unknowns register. The register itself is GitHub issues (`label:unknown`, `label:residual`); this file holds what an entry must contain and how one is closed. |

## history/ — dated records

| File | What it is |
|---|---|
| [CHANGELOG-archive.md](history/CHANGELOG-archive.md) | Release notes for 0.1.0 – 0.8.4, split from [CHANGELOG.md](../CHANGELOG.md) in 0.10.0. Frozen. |

## dev/ — working artifacts

`dev/` holds dated working material that other documents cite, kept so that
results can be re-run rather than trusted. Nothing in it describes the current
state.

- `dev/2026-09-16-base-gate-subject-spec.md` and `-plan.md` — the spec and
  plan for 0.11.13's base-gate fix (#130, #131), cited by
  `scripts/base-gate.sh`.
- `dev/decision-engine-probes/` — the raw requests and responses behind
  [DECISION-ENGINE-PROBES.md](design/DECISION-ENGINE-PROBES.md).

## Not in the tree

Audit handoffs, build ledgers and pilot evidence from before 0.3.0 are in git
history (tree ≤ v0.2.0) and in the maintainer's local archive. The one audit
handoff that was ever committed (`docs/audit-2026-08-09-handoff.md`, F67+)
left in 0.10.0; read it at `git show 7d2b9ae^:docs/audit-2026-08-09-handoff.md`.
