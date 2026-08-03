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

---

## The 4 tiers — what they mean

A **tier** is a job-difficulty class that maps to a specific AI model. The
operator picks the tier by *what the task needs*, not by cost alone — but
cheap tasks never get an expensive brain, and hard judgment never gets a cheap
one.

| Tier name     | Default model            | What it's for                          | Cost / power        |
| ------------- | ------------------------ | -------------------------------------- | ------------------- |
| **JUDGMENT**  | `claude-opus-5`          | Hard calls: design, review, verdicts   | Highest / smartest  |
| **IMPLEMENT** | `glm-5.2`                | Writing real code, multi-step builds   | Mid / capable       |
| **MECHANICAL**| `glm-5-turbo`            | Bulk generation, reading shards        | Cheap / fast        |
| **RECON**     | `claude-haiku-4-5-…`     | Lookups, searches, "where is X?"       | Cheap / fast        |

**The golden rule:** *judgment work never runs below judgment tier.* If a task
needs taste or reasoning, it gets JUDGMENT — no exceptions. Cheap tiers are for
volume and speed, not for decisions.

> You can change which model each tier points at — see "Customizing" below.
> You **cannot** rename the four tier names; the whole system keys off them.

---

## The team — 7 agents

Each agent has a fixed job. The operator dispatches them like specialists.

| Agent (`op-…`)   | Tier used      | Its one job                                           |
| ---------------- | -------------- | ----------------------------------------------------- |
| **op-author**    | JUDGMENT       | Writes prose, design, anything needing taste          |
| **op-verifier**  | JUDGMENT       | Adversarial check: tries to *break* your claim (REFUTED/CONFIRMED) |
| **op-reviewer**  | JUDGMENT       | Read-only review + scoring of finished work           |
| **op-mechanic**  | IMPLEMENT      | Scaffolds, fixtures, commits, reverts — mechanical edits |
| **op-scout**     | RECON          | Fast searches & lookups ("where/how is X?")           |
| **op-crawler**   | MECHANICAL     | Reads one chunk of a large codebase, returns a digest |
| **op-brainstorm**| MECHANICAL     | Generates many candidate ideas (divergent thinking)   |

**Read vs. write:** scouts, crawlers, reviewers, verifiers are **read-only**
(they can't change files). Author and mechanic **write**. The operator never
lets two writers touch the same thing at once.

---

## The 4 workflows — pre-built multi-agent recipes

A **workflow** is a canned fan-out: it spawns several agents in parallel and
converges on an answer. You don't run these manually — the operator invokes
them at the right moment.

| Workflow      | When the operator uses it                          | What happens                                            |
| ------------- | -------------------------------------------------- | ------------------------------------------------------- |
| **review**    | After work that will be merged/published           | Many narrow lenses (cheap) + one adversarial verifier (JUDGMENT). A **REFUTED** = hard stop, can't be outvoted |
| **plan**      | After a spec/design is approved                    | Breaks work into bite-sized TDD tasks, vets each (feasibility + testability) |
| **brainstorm**| At the start, before a spec exists                | Explores many directions + a blindspot scan → design options |
| **crawl**     | When you need to digest a big codebase/text fast   | Parallel cheap readers, one shard each, merged at JUDGMENT |

**The killer feature:** in `review`, if the adversarial verifier says REFUTED,
the work is rejected — no matter how many other agents liked it. One solid
"this is wrong" beats five "looks fine."

---

## The 3 commands you'll type

| Command                | When                                      |
| ---------------------- | ----------------------------------------- |
| `/cc-operator:start`   | **Start** a session you'll operate        |
| `/cc-operator:tiers`   | See/resolve tier→model bindings, render agents |
| `/cc-operator:handoff` | **End** the engagement with a clean handoff |

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

You'll recognize a good dispatch packet — every task ships with:
```
TASK / SCENE / INPUTS / FORBIDDEN / CONSTRAINTS /
DONE MEANS (command + expected output) / REPORT (≤30 lines)
```

### 4. Workers report one of four statuses
| Status              | What it means                         | What the operator does                    |
| ------------------- | ------------------------------------- | ----------------------------------------- |
| **DONE**            | Finished, evidence attached           | Runs the review workflow (for mergeable work) |
| **DONE_WITH_CONCERNS** | Done, but has correctness worries  | Holds review until concerns resolve       |
| **NEEDS_CONTEXT**   | Missing info to proceed               | Supplies it, re-dispatches                |
| **BLOCKED**         | Stuck                                 | Climbs the escalation ladder (context → promote tier → split → you) |

### 5. The evidence gate — proof, not promises
A claim of "done" with no evidence is a **FAIL** by definition. The operator
opens a tracked task, and closes it only by appending a real evidence row
(command output, a diff, a reviewer verdict) to a ledger. While a task *you
own* is open, the session **can't stop** — it's forced to finish honestly.

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
| ---------------------------- | ------------------------------------------ | ------------------------------ |
| Identical-rejection ×2       | Same reviewer rejects same target twice    | Escalate, never a 3rd loop     |
| Same-target-rework ×2        | Two rework rounds on one thing             | Stop, log, move on / escalate  |
| Neighbor-regressing ×2       | Two fixes each break something else        | End tuning, report             |

When a cap trips, the operator stops and tells you — that's the system working
as designed.

---

## Customizing — point tiers at your own models

Tier→model bindings live in a config file, layered (later wins):

1. Built-in defaults (the table above)
2. `~/.claude/cc-operator/tiers.env` — **your** global prefs
3. `./.operator/tiers.env` — **this project's** overrides
4. `--set NAME=id` — one-off for a single run

A `tiers.env` line is just `NAME=model-id`, e.g.:
```
# Use a different Opus-class model for judgment calls
JUDGMENT=claude-opus-5
# Route cheap work to a faster local model
MECHANICAL=glm-5-turbo
```
Run `/cc-operator:tiers` to see the current bindings and provenance (where each
value came from). Add `--check` to verify every id is actually reachable on
your proxy before trusting it.

> Rules: model ids must match a routable shape (`glm-*`, `vendor/model`, or
> `claude-*`), contain no spaces or quotes, and you can't rename the four tier
> names.

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
decision is shaped the way it is, see `docs/spec/` and `docs/PLAYBOOK.md`.*
