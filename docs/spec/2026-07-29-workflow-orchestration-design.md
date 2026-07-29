# cc-operator as workflow orchestrator — design

**Date:** 2026-07-29
**Status:** proposed. Supersedes `2026-07-28-cc-operator-orchestration-design.md`,
whose two central constraints were measured false (see §2).
**Target:** cc-operator 0.5.0 · cc-agents retired · superpowers reduced to non-overlap
· cc-proxy unchanged

---

## 1. What changed since the 0.4.0-era design

The prior design (2026-07-28) built a model-binding renderer and a worktree
lifecycle by hand, because the Agent tool's `model` parameter is a fixed enum and
worktrees were unmanaged. Claude Code 2.1.220 ships **dynamic workflows**, which
invalidate both premises. Measured 2026-07-29, this machine:

| claim | measurement |
|---|---|
| a workflow agent can run on a non-Anthropic model through cc-proxy | `{"model":"glm-5.2"}` in agent meta; `message.model: "glm-5.2"`; returned `PONG` |
| `opts.model` overrides an agent file's `model:` frontmatter | `agentType: cc-operator:op-scout` (file says `model: haiku`) + `opts.model: glm-5.2` → served by `glm-5.2` |
| one agent body can serve N seats at N prices | 4 lenses on `op-reviewer.md`: 2× `glm-5-turbo`, 2× `claude-opus-5`, one run, `agents_error: 0` |
| the harness owns worktree lifecycle | `worktreePath: .claude/worktrees/wf_…`, auto-removed; `git worktree list` + `git status --porcelain` clean afterward |

So the renderer (`ops-tier.sh`: two-layer resolver, guard chain, liveness probe,
atomic multi-file write, last-known-good revert) and the isolation lifecycle
(`ops-worktree.sh`, engagement records, sentinel schema change) are **not
deferred — they are unnecessary**. cc-agents' mechanism retires *into the
harness*, not into cc-operator.

What has no harness equivalent, and therefore remains cc-operator's entire
reason to exist: **the ledger, the evidence gate, the charter, the dispatch
packet.**

---

## 2. Constraints (measured 2026-07-29, not assumed)

**M1 — `opts.model` accepts any id cc-proxy routes.** Verified with `glm-5.2` and
`glm-5-turbo`. The proxy routes by id shape (`^glm-|/|^claude-`), so honoring a
tier value is one guard, and no proxy change is needed for a new backend.

**M2 — `opts.model` beats agent-file frontmatter.** This is the load-bearing
fact. A seat = an existing `op-*.md` body + a per-call lens prompt + a per-call
model. The file's `model:` line degrades from a binding to a default.

**M3 — a worktree is its own git toplevel, and the ledger is invisible from it.**
Measured against the real Stop hook, in a harness-created worktree:

```
hook cwd = main tree        → exit 2, names the pending task
hook cwd = harness worktree → exit 0, allows the stop
```

`git rev-parse --show-toplevel` inside the worktree returns the *worktree*, and
`ls .operator` returns `No such file or directory`. This is not a defect to fix;
it is the boundary the design must respect (§5).

**M4 — the gate does not fire on workflow agents.** `hooks/hooks.json` registers
`SessionStart` and `Stop` only, never `SubagentStop`. Workflow agents cannot trip
the evidence gate, and the operator's own Stop remains the single gate point.

**M5 — a workflow script has no filesystem access.** Only its spawned agents
touch disk. Any ledger write must therefore happen in the operator's turn, or in
a non-isolated agent that the workflow dispatches for that purpose.

**M6 — `isolation: 'worktree'` resolves git from the workflow's cwd.** A run
launched from a non-repo directory dies with `WorktreeIsolationError`. Operator
workflows using isolation must be invoked from the repository.

**M7 — `CLAUDE_CODE_SUBAGENT_MODEL` overrides `opts.model`.** Unset here. A
workflow that silently loses its routing to an env var needs a guard, not a
comment.

---

## 3. The seat model, without a renderer

```
agents/op-*.md      the CONTRACT (read-only guarantee, four-status protocol,
                    DONE MEANS discipline). Its model: line is a default.
workflow agent()    the LENS (one narrow question) + the TIER (a cc-proxy id)
```

Tiers are ids, declared once at the top of each workflow. Four, not three —
splitting JUDGMENT from IMPLEMENT lets an implementer run sonnet-class while
review stays opus-class, the common case:

```js
const JUDGMENT   = "claude-opus-5";
const IMPLEMENT  = "claude-sonnet-5";
const MECHANICAL = "glm-5-turbo";
const RECON      = "claude-haiku-4-5-20251001";
```

A lens that needs judgment is not a lens, it is a review. That is the rule that
makes a cheap tier honest, and it held in the pilot: the `glm-5-turbo`
testability lens found three enforced rules in `check_bare_name` with no
acceptance criterion targeting `ops-task.sh` — a real gap in a 192-case suite,
found by the cheapest model on the panel.

**No `settings.toml`, no `[[seat]]` table, no `/tier` command, no rendered
`.claude/agents/op-*.md`.** A tier change is an edit to a workflow file, which
takes effect on next invocation with no session restart — the prior design's
open risk #1 does not exist here because there is nothing to reload.

---

## 4. Review as a workflow (pilot: shipped and run)

`workflows/review.js` — four narrow lenses in parallel at mixed tiers, then the
adversarial seat on what survives. Synthesis is plain code (drop <50, bucket
≥75/60/50), not an agent.

**A REFUTED is a hard stop.** It never enters the scoring pool, cannot be
outvoted by panel scores, and cannot be dropped by the threshold. The workflow
returns `blocked: true`.

Pilot run against `scripts/ops-task.sh`, 2026-07-29 — 5 agents, 3 models,
138k subagent tokens, 21 min, `agents_error: 0`. Against a **192 passed, 0
failed** baseline it returned REFUTED and surfaced a P1 the suite and the
2026-07-27 audit both missed:

> A non-regular entry in `.operator/pending/` (directory, dangling symlink,
> ENOSPC) makes `ops-task.sh` print `already open: <id> (ownership unchanged)`
> and exit 0, while the Stop hook's `-f` guard refuses to count it — so the
> session stops with a task the operator believes is tracked. Reproduced
> independently.

That is the argument for the panel: a green suite plus four satisfied reviewers,
and the adversarial seat still refuted on evidence it gathered itself.

### 4.1 Correction to apply from the pilot

Use `pipeline()`, not `parallel()`, for the panel. The barrier made the whole
run wait on one read-heavy `glm-5-turbo` lens that took ~3× the others; cheap
tier is not fast tier when the lens is read-heavy. Findings should flow to
synthesis as each lens lands.

---

## 5. The gate boundary (the one genuinely new rule)

M3 + M5 + `ops-task.sh`'s `OPDIR=".operator"` (cwd-relative, refuses to run
where there is no `.operator/`) produce one rule, and it is not negotiable:

> **The operator opens and closes tasks, from the main tree. Workflows never
> touch the gate. A workflow is evidence produced *under* an open task, never a
> task opener.**

Consequences:

- No `worktree:` / `branch:` lines in the sentinel — sentinels never live in a
  worktree, so the prior design's schema change is void.
- A workflow's return value is evidence the operator transfers into
  `VERDICTS.md` via `ops-verdict.sh`, exactly like a worker report today.
- `isolation: 'worktree'` is for agents that *mutate files in parallel*. Review
  and recon agents are read-only and must not pay ~200-500ms + disk for it.

---

## 6. Retirement

### 6.1 cc-agents

Nothing outside cc-agents depends on its agent names. Re-run anchored to actual
dispatch syntax rather than the bare words `reasoner|coder|simple` (which return
~99 false positives across the marketplace):

```
grep -rnE "subagent_type[^a-zA-Z]{0,4}(reasoner|coder|simple)|cc-agents:(reasoner|coder|simple)|glm-(review-|code-crawler|bulk-reader|brainstorm|scout)"
```

→ 2 hits, both prose in `clean-audit/HANDOFF-plugin-descriptions.md`. No shim.

**Note:** the installed plugin is **0.3.0** (`~/.claude/plugins/cache/…/0.3.0`),
not the repo's 0.2.0 branch. 0.3.0 already shipped `set-tier.sh`,
`/cc-agents:tier`, `.claude/cc-agents.local.md`, and replaced the
`POST /v1/messages` probe with a free `GET /v1/models` membership check. Any
"port the guard chain" instruction written against 0.2.0 is stale — and moot,
since §3 ports nothing.

Sequence: tag 0.3.x → strip `agents/`, `scripts/`, `skills/`, `commands/` →
README becomes a pointer → marketplace entry → user removes
`"cc-agents@betmoar": true` from `~/.claude/settings.json`.

### 6.2 superpowers

Not a wholesale removal — a removal of *overlap the charter already claims to
outrank*. `OPERATOR.md:138` names `subagent-driven-development` and
`verification-before-completion` as subordinate, yet they load anyway, and
`subagent-driven-development` (28 KB) specifies its own model-routing ladder
that contradicts `OPERATOR.md:47`. That is precisely the conflicting-instruction
cost Anthropic measured: the model must reason through the contradiction before
it can start.

Measured overlap, bytes of SKILL.md body:

| skill | bytes | replaced by |
|---|---|---|
| `subagent-driven-development` | 28,077 | charter ORCHESTRATED MODE + dispatch packet |
| `brainstorming` | 10,047 | `workflows/brainstorm.js` |
| `test-driven-development` | 9,015 | keep — no overlap |
| `systematic-debugging` | 9,465 | keep — no overlap |
| `finishing-a-development-branch` | 7,022 | keep |
| `writing-plans` | 6,907 | `workflows/plan.js` |
| `using-git-worktrees` | 6,813 | harness `isolation: 'worktree'` |
| `receiving-code-review` | 6,203 | `workflows/review.js` |
| `dispatching-parallel-agents` | 6,078 | `parallel()` / `pipeline()` |
| `verification-before-completion` | 3,646 | EVIDENCE GATE |
| `requesting-code-review` | 2,956 | `workflows/review.js` |
| `executing-plans` | 2,305 | charter four-status protocol |

**~66 KB of directly-overlapping guidance retired**, against ~128 KB total.
`test-driven-development`, `systematic-debugging`, and
`finishing-a-development-branch` stay: they cover ground the charter does not,
and removing them would be dieting for its own sake.

The replacement is cheaper than the thing replaced: **a workflow body costs
nothing until invoked**, unlike a skill body pulled into context by a trigger
match. That is the whole diet argument.

---

## 7. The context diet

Measured always-on load per session:

| source | bytes |
|---|---|
| skill descriptions, all plugins (tool listing) | 41,963 |
| project `CLAUDE.md` | 22,023 |
| `OPERATOR.md` (`@import`) | 7,615 |
| `~/.claude/CLAUDE.md` | 2,678 |

Three moves, in decreasing confidence:

1. **Retire the overlap** (§6.2). Removes both context weight and the
   contradictions, which is the larger win. `skillListingBudgetFraction: 0.02`
   is already truncating the 42 KB listing — a skill that does not appear cannot
   fire, so shrinking the set makes the survivors *more* reliable, not less.

2. **Split the project `CLAUDE.md`.** At 22 KB / 292 lines it is an excellent
   maintainer artifact and mostly *not* session guidance: `## Landmines` alone
   is lines 89–268. Anthropic's guidance is ≤200 lines. Keep the load-bearing
   map and the coupling table; move the landmine narratives to
   `docs/LANDMINES.md`, where `PLAYBOOK.md` and the validator already point.
   Nothing is lost — the couplings that must not rot are enforced by
   `check_reader_bounds`, `check_guard_parity`, and `check_lock_parity`, not by
   being read every session.

3. **Trim the charter's PRECEDENCE section.** It currently enumerates the
   superpowers skills it outranks. Once those are gone, the enumeration is dead
   weight in a file capped at 150 lines (currently 141 — 9 lines of headroom,
   and §8 needs some of it).

---

## 8. Changes to cc-operator

| area | change |
|---|---|
| `workflows/review.js` | **done** — pilot run, found a P1 |
| `workflows/brainstorm.js` | new — divergent generation at MECHANICAL, convergence at JUDGMENT |
| `workflows/plan.js` | new — decompose, then one feasibility lens per task |
| `agents/op-*.md` | unchanged bodies; `model:` becomes a documented default |
| `templates/OPERATOR.md` | ORCHESTRATED MODE cites workflows as the routing mechanism; PRECEDENCE trimmed (§7.3); **the §5 gate boundary is added — it is the one rule the operator cannot infer** |
| `scripts/validate_plugin.py` | new `check_workflows`: every `workflows/*.js` parses, `meta` is a pure literal and the first statement, and every `opts.model` value matches `^glm-\|/\|^claude-` (the M1 guard, enforced at build time rather than trusted at dispatch) |
| `CLAUDE.md` | split per §7.2; add the coupling row below |
| `docs/spec/2026-07-28-…` | marked superseded, retained — its §2 constraint discipline is the reason the false premises were catchable |

New coupling row, in the existing table's idiom:

| If you change… | You must also… |
|---|---|
| a tier id in any `workflows/*.js` | keep it cc-proxy-routable (`^glm-\|/\|^claude-`) — `check_workflows` enforces this, because an unroutable id fails at dispatch time, deep inside a run, not at build time |

---

## 9. Not in scope

- **`ops-tier.sh` / any renderer.** M2 makes it unnecessary.
- **`ops-worktree.sh` / engagement records / sentinel schema change.** The
  harness owns worktrees; M3 makes cc-operator-managed isolation actively
  harmful to the gate.
- **Any cc-proxy change.** M1.
- **A cc-agents shim.** §6.1.
- **Removing `test-driven-development`, `systematic-debugging`,
  `finishing-a-development-branch`.** No overlap; removal would be diet theater.

---

## 10. Open risks

1. **`CLAUDE_CODE_SUBAGENT_MODEL` silently overrides every `opts.model`** (M7).
   Unset today. A workflow whose routing is overridden wholesale would still
   *succeed*, just on the wrong model and at the wrong price — the failure is
   invisible. Worth a startup check, not a comment.

2. **Workflow resume is same-session only.** Exiting Claude Code mid-run starts
   fresh next session, and replay re-runs every agent that started after the
   first unfinished one. A workflow that fans out across many small agents
   preserves more progress than one long agent — which argues for `pipeline()`
   over few-and-large regardless of §4.1.

3. **The pilot found a P1 that this design does not fix.** The non-regular
   `pending/` entry (§4) is a live fail-open in 0.4.0. It is independent of this
   refactor and should be fixed under the gate first, not folded in.

---

## References

- [The new rules of context engineering for Claude 5 generation models](https://claude.com/blog/the-new-rules-of-context-engineering-for-claude-5-generation-models)
- [A harness for every task: dynamic workflows in Claude Code](https://claude.com/blog/a-harness-for-every-task-dynamic-workflows-in-claude-code)
- [Steering Claude Code: CLAUDE.md, skills, hooks, subagents](https://claude.com/blog/steering-claude-code-skills-hooks-rules-subagents-and-more)
- `docs/spec/2026-07-28-cc-operator-orchestration-design.md` — superseded
- `docs/spec/concurrent-sessions.md:75` — *"Worktrees do **not** solve this;
  they make it more likely"* — the evidence the prior design cited against its
  own conclusion
