# cc-operator — the plain-English handout

> Read this once. It's the whole picture: what the tiers are, who the
> agents are, what the workflows do, and how to actually run a session.
> No jargon you can't look up in this file.

---

## The big idea (30-second version)

cc-operator turns Claude Code into a **chief operator** with a team. Instead of
one AI doing everything alone, the operator runs like a project lead: it
**delegates** small jobs to cheap, fast workers, keeps the **hard judgment
calls** for itself (or a top-tier reviewer), and **writes down proof** that
every piece of work is actually done — not just claimed to be.

You stay in control: you give the goal, the operator does the orchestration,
and nothing gets marked "done" without evidence you can check.

**First thing to run:** `/cc-operator:tutorial` — a throwaway project where you
*watch* the evidence gate block a stop and then release it once a verdict row
exists. It's the fastest way to see what "gated" actually means.

---

## The 4 tiers — what they mean

A **tier** is a job-difficulty class that maps to a specific AI model. The
operator picks the tier by *what the task needs*, not by cost alone — but
cheap tasks never get an expensive brain, and hard judgment never gets a cheap
one. Which tier a given agent *seat* runs on is decided per workflow call
site, not baked into the agent file.

| Tier name     | Default model                | What it's for                          | Cost / power        |
| ------------- | ----------------------------- | --------------------------------------- | -------------------- |
| **JUDGMENT**  | `opus` (alias → latest Opus)   | Hard calls: design, review, verdicts   | Highest / smartest  |
| **IMPLEMENT** | `claude-sonnet-5`               | Writing real code, multi-step builds   | Mid / capable       |
| **MECHANICAL**| `glm-5.3-flash`                 | Bulk generation, reading shards        | Cheap / fast        |
| **RECON**     | `claude-haiku-4-5-20251001`     | Lookups, searches, "where is X?"       | Cheap / fast        |

There is also a **PANEL** — not a tier, a debate line-up (default
`opus, glm-5.3, deepseek-flash`, with fallback spares for a dead seat)
that feeds the debate workflow via `ops-tiers.sh --panel`.

**The golden rule:** *judgment work never runs below judgment tier.* If a task
needs taste or reasoning, it gets JUDGMENT — no exceptions. Cheap tiers are for
volume and speed, not for decisions.

> You can change which model each tier (and the panel) points at — see
> "Customizing" below. You **cannot** rename the four tier names; the whole
> system keys off them.

---

## The team — 8 agents

Each agent has a fixed job. The operator dispatches them like specialists;
the tier column below is the one each seat is *typically* dispatched at by
the shipped workflows — a seat has no tier of its own.

| Agent (`op-…`)   | Typical tier    | Its one job                                           |
| ---------------- | --------------- | ------------------------------------------------------ |
| **op-author**    | JUDGMENT/MECH.  | Writes prose, design, anything needing taste (also drafts and merges) |
| **op-debater**   | the panel's ids | Read-only debate seat — holds ONE position across rounds, revises only on evidence |
| **op-verifier**  | JUDGMENT        | Adversarial check: tries to *break* your claim (REFUTED/CONFIRMED) |
| **op-reviewer**  | JUDGMENT/MECH.  | Read-only review + scoring of finished work (spec/quality/scoring modes) |
| **op-mechanic**  | IMPLEMENT       | Scaffolds, fixtures, commits, reverts — mechanical edits |
| **op-scout**     | RECON           | Fast searches & lookups ("where/how is X?")           |
| **op-crawler**   | MECHANICAL      | Reads one chunk of a large codebase, returns a digest |
| **op-brainstorm**| MECHANICAL      | Generates many candidate ideas (divergent thinking)   |

**Read vs. write:** scouts, crawlers, reviewers, verifiers, and the debater are
**read-only by tool policy** — Write/Edit excluded, but a seat carrying Bash
could still write through the shell, so the operator verifies the tree after
read-only dispatches (`ops-claims.sh --expect-clean`) rather than trusting the
label. Author and mechanic **write**; the operator never lets two writers
touch the same thing at once.

---

## The 7 workflows — pre-built multi-agent recipes

A **workflow** is a canned fan-out: it spawns one or more agents and converges
on an answer. You don't run these manually — the operator (or the matching
`/cc-operator:` command) invokes them at the right moment.

| Workflow      | When it's used                                      | What happens                                            |
| ------------- | ---------------------------------------------------- | ---------------------------------------------------------- |
| **brainstorm**| At the start, before a spec exists                  | N divergent directions + a blindspot scan + a reference search → ranked design options |
| **plan**      | After a spec/design is approved                      | Decomposes into bite-sized TDD tasks (JUDGMENT), vets each (feasibility JUDGMENT + testability cheap) |
| **implement** | Any implementation dispatch                          | One implementer seat per task, STRICTLY SERIAL, on IMPLEMENT tier; refuses an incomplete dispatch packet before spending a seat |
| **review**    | After work that will be merged/published             | Narrow lenses in parallel (mixed tiers) + one adversarial verifier (JUDGMENT). A **REFUTED** = hard stop, can't be outvoted |
| **debate**    | A judgment call, not a measurable fact                | 2-5 named models argue the same case over three blind rounds (opening, rebuttal, closing), then a neutral synthesis — it never picks a winner, you decide |
| **crawl**     | When you need to digest a big codebase/text fast     | Parallel cheap-tier readers, one shard each, merged at JUDGMENT |
| **dispatch**  | One seat on a caller-supplied model or named tier    | Plain single-agent dispatch when the enum-locked `Agent` tool can't reach a configured proxy model |

**The killer feature:** in `review`, if the adversarial verifier says REFUTED,
the work is rejected — no matter how many other agents liked it. One solid
"this is wrong" beats five "looks fine."

---

## The commands you'll type

Eleven `/cc-operator:` commands. `tutorial` is where to start; `start` opens
a session; the rest map onto the cycle below or wrap a single workflow.

| Command                 | When                                                       |
| ------------------------ | ------------------------------------------------------------ |
| `/cc-operator:tutorial`  | **Try it first** — watch the evidence gate block, then release, on a throwaway project |
| `/cc-operator:start`     | **Start** a session you'll operate                          |
| `/cc-operator:brainstorm`| Explore directions before a spec exists                     |
| `/cc-operator:spec`      | Write/check/approve the engagement's spec                   |
| `/cc-operator:plan`      | Decompose an approved spec into TDD tasks                   |
| `/cc-operator:implement` | Run one implementer seat per task, serially                 |
| `/cc-operator:review`    | Run the review panel over an artifact                       |
| `/cc-operator:debate`    | Run a multi-model debate on a judgment call                 |
| `/cc-operator:crawl`     | Digest a large corpus cheaply                                |
| `/cc-operator:tiers`     | See/resolve tier→model bindings, render agents               |
| `/cc-operator:handoff`   | **End** the engagement with a clean handoff                  |

### The cycle

Stages run **brainstorm → spec → plan → implement → review → handoff**. Small
work can skip straight to SOLO MODE edits; anything earning a BAR block (see
ENGAGEMENT CONTRACT in the charter) follows this path. The SessionStart banner
prints a derived **STAGE** line (`CLEAR`, `SPEC`, `PLAN`, `IMPLEMENT` or
`BLOCKED`) naming where the session stands, so you never have to reconstruct
it from memory. Unpresented deviations are checked by the Stop hook, not the
banner.

---

## How to actually use it — ELI5 walkthrough

### 1. Start the session
```
/cc-operator:start
```
Tell the operator your goal in plain words:
> *"Add a dark mode toggle to the settings page."*

### 2. Stay in SOLO MODE for small stuff
For a one-file tweak, the operator just does it — reads, edits, verifies. No
ceremony. You'll see it state, before each risky step:
- **Destination check** — "I'm about to write to *this* path, and it's not an
  old result."
- **Meter check** — "this result would be invalid if X; I checked X."
- **Record over summary** — it trusts command output/logs, not a rosy summary.

### 3. Big jobs flip into ORCHESTRATED MODE
The moment the operator dispatches its **first subagent**, you're in orchestrated
mode. Now it behaves like a lead:
- It **doesn't** read workers' full transcripts — it reads short reports (`--stat`
  and summaries), to keep its own head clear.
- It routes each task to the right tier (cheap for volume, JUDGMENT for calls).
- **One writer at a time**; read-only workers can run in parallel.

You'll recognize a good dispatch packet — every task ships with exactly the
charter's fields:
```
TASK / TEXT / SCENE / INPUTS / FORBIDDEN (gate files off-limits unless the task
IS the gate) / DONE / REACH (the shipped entry point this is reached from + the
grep or trace proving the path; when the deliverable IS a gate, a red run on a
real violation AND a green run on a compliant input, mutation restored
byte-identical) / REPORT (status <=30 lines, SHA, CHANGED: <paths>|none)
```
The `CHANGED:` line is not decoration — on a DONE report the operator feeds it
to `ops-claims.sh`, which checks the claimed paths against the actual diff.

`REACH` answers a question the rest of the packet does not: *is this code on
any path that ships?* Three artifacts in one engagement passed every gate —
tests green, evidence real, verifier CONFIRMED — while nothing called them;
the evidence was true about the unit and silent about its reach. A check that
has only ever gone red proves something about one input, not about the rule.

### 4. Workers report one of four statuses
| Status              | What it means                         | What the operator does                    |
| ------------------- | -------------------------------------- | ------------------------------------------ |
| **DONE**            | Finished, evidence attached           | Runs the review workflow (for mergeable work) |
| **DONE_WITH_CONCERNS** | Done, but has correctness worries  | Holds review until concerns resolve       |
| **NEEDS_CONTEXT**   | Missing info to proceed               | Supplies it, re-dispatches                |
| **BLOCKED**         | Stuck                                 | Climbs the escalation ladder (context → promote tier → split → you) |

### 5. The evidence gate — proof, not promises
A claim of "done" with no evidence is a **FAIL** by definition. The operator
opens a tracked task, and closes it only by appending a real evidence row
(command output, a diff, a reviewer verdict) to a ledger. Every row carries a
verdict word — **PASS**, **FAIL**, or **MOOT** (the criterion cannot be
answered any more; the reason itself is the evidence). A task that's genuinely
stuck ends honestly with `--defer "<reason>"` rather than being forced to a
false PASS. While a task *you own* is open, the session **can't stop** — it's
forced to finish honestly. And if two or more files changed, the Stop hook
opens an `autobar` task for you anyway (once between session starts), so
multi-file work cannot slip out without a verdict.

> This is why you can trust the "done": there's a written record behind it.

### 6. Hand off cleanly
```
/cc-operator:handoff
```
Produces six sections: what the verdict was, what holds, what's unverified,
next steps (each with a precheck), when to stop, and what's deliberately
**not** being done.

---

## Caps — when the operator stops and asks for help

The operator has tripwires so it never spins in circles:

| Cap                          | Trip                                       | Action                         |
| ----------------------------- | -------------------------------------------- | -------------------------------- |
| Identical-rejection ×2       | Same reviewer rejects same target twice    | Escalate, never a 3rd loop     |
| Same-target-rework ×2        | Two rework rounds on one thing             | Stop, log, move on / escalate  |
| Neighbor-regressing ×2       | Two fixes each break something else        | End tuning, report             |

When a cap trips, the operator stops and tells you — that's the system working
as designed. (A report-only cap *detector* also scans the ledger for
same-target-rework and surfaces it early; it never blocks by itself.)

---

## Customizing — point tiers at your own models

Tier→model bindings live in a config file with three line kinds, layered
(later wins). Comments go on their own line — a `#` after a value becomes part
of the value and the resolver refuses it:

1. Built-in defaults (the table above)
2. `~/.claude/cc-operator/tiers.env` — **your** global prefs
3. `./.operator/tiers.env` — **this project's** overrides
4. `--set NAME=id` — one-off for a single run

A `tiers.env` line is one of:
```
# TIER = model-id
JUDGMENT=opus
# seat = TIER ('op-' prefix optional)
op-scout=MECHANICAL
# the debate panel, and its spares
PANEL=opus,glm-5.3,deepseek-flash
PANEL_FALLBACK=qwen3.8-max
```
Run `/cc-operator:tiers` to see the current bindings and provenance. Add
`--check` to verify every id is reachable on your proxy, or `--suggest` for a
report-only note about a graded model that beats a current binding on both
score and price — it changes nothing itself.

> Rules: a model id may contain only letters, digits and `._:/@[]-` (no spaces
> or quotes). Whether that model exists is cc-proxy's call, not the
> resolver's. You can't rename the four tier names.

---

## Recovery — if something crashes or you lose context

Don't panic, don't trust memory. The operator re-reads its ledgers:
1. Re-reads the charter (`OPERATOR.md`)
2. Reads `.operator/DECISIONS.md` in full
3. `git log --oneline -20`
4. Reads `.operator/VERDICTS.md` for the last verdict
5. Rebuilds its task list
6. Re-claims tasks it still owns (its session id changed)
7. Resumes at the first incomplete task

The ledgers are the source of truth — not the AI's memory of what it "thinks"
happened.

---

## One-line summary for the wall

> **You name the goal. The operator picks the tier per task, delegates to the
> right agent, gates every "done" on real evidence, and escalates instead of
> looping. You review the proof.**

---

*For the full rules, the charter is `templates/OPERATOR.md`. For why every
decision is shaped the way it is, see `docs/design/TAGS.md` and `docs/maintainer/PLAYBOOK.md`.*
