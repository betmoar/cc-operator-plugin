# cc-operator

A Claude Code plugin that makes a session **operate under a charter**. It
installs an operating charter, an append-only evidence ledger and a Stop-hook
completion gate into your project, so "done" has to be *evidenced*: asserting
it is not enough.

- **The evidence gate.** Open a tracked task and the session cannot stop until
  a verdict row with real evidence (command output, a diff, a reviewer verdict)
  closes it. Change two or more files without opening one, and the gate opens
  one for you.
- **The charter.** `OPERATOR.md` (≤150 lines) sets the rules: solo mode by
  default, orchestrated mode once you dispatch subagents, loop caps, a dispatch
  packet, a four-status worker protocol and a recovery protocol for after
  compaction.
- **The workflows.** Seven deterministic multi-agent workflows (review,
  brainstorm, plan, implement, debate, crawl, dispatch) run seats on four model
  tiers that you bind in `tiers.env`.

Version **0.12.8**. See [CHANGELOG.md](CHANGELOG.md) for what changed, and
[docs/](docs/README.md) for everything else.

---

## Contents

- [Prerequisites](#prerequisites)
- [Install](#install)
- [Getting started](#getting-started)
- [What `/cc-operator:start` installs](#what-cc-operatorstart-installs)
- [The evidence gate](#the-evidence-gate)
- [The engagement cycle and its commands](#the-engagement-cycle-and-its-commands)
- [Workflows and tiers](#workflows-and-tiers)
- [Hooks](#hooks)
- [Status bar](#status-bar-optional)
- [Documentation](#documentation)
- [Repository layout](#repository-layout)
- [Development](#development)

## Prerequisites

| Tool | Used for | If it is missing |
|---|---|---|
| `bash` (3.2+) | every gate CLI and hook | nothing works |
| `git` | the source stamp on each verdict row, auto-arm, `ops-claims.sh`, the tutorial | `ops-init.sh` warns; rows are stamped `@no-vcs`; auto-arm arms nothing |
| `jq` **or** `python3` | reading the hook payload (Stop, SessionStart, statusline) | the Stop hook **fails open** (exits 0 with a warning), so a missing dependency never bricks a session |
| `node` | the PostToolUse output compressor | tool output is not compressed |
| `claude` CLI | `ops-holdout.sh` only | the holdout skill cannot derive |
| [cc-proxy](https://github.com/betmoar/cc-proxy-plugin) *(optional)* | routing tiers to non-Anthropic models; `ops-tiers.sh --check/--suggest/--panel` | tiers use Anthropic model ids; the proxy-backed flags report and fail open |
| [cc-status](https://github.com/betmoar/cc-status-plugin) *(optional)* | composing the status-bar segment | wire `scripts/statusline.sh` directly (see below) |

## Install

```
/plugin marketplace add betmoar/cc-operator-plugin
/plugin install cc-operator
```

From a local checkout:

```
/plugin marketplace add /path/to/cc-operator-plugin
/plugin install cc-operator
```

## Getting started

1. **`/cc-operator:tutorial`** builds a throwaway git project, opens a tracked
   task, and feeds the real Stop hook a stop payload. You watch the hook block
   (exit 2), a verdict row get written, and the hook allow the stop (exit 0).
   The tutorial prints `TUTORIAL_OK` only when it observed both;
   `TUTORIAL_FAILED` means the plugin is broken on this machine. `--keep`
   leaves the project on disk.
2. **`/cc-operator:start`** in your own project installs the charter and the
   ledger (next section).
3. Work as usual. When a task has a done-state, open it with `ops-task.sh`,
   close it with `ops-verdict.sh`, and the Stop hook keeps you honest. For
   the plain-English tour of tiers, agents, workflows and a full session, see
   [docs/guide/HANDOUT.md](docs/guide/HANDOUT.md).

## What `/cc-operator:start` installs

`/cc-operator:start [--inline]` runs `scripts/ops-init.sh` from the project
root. It is idempotent, and re-running it is also how the gate CLIs get upgraded.

- **`OPERATOR.md`**: the operating charter ([source](templates/OPERATOR.md)).
  **Solo mode** is the default: you implement directly, under the evidence gate
  and the cap table. **Orchestrated mode** starts at the first subagent
  dispatch and adds a context diet (no worker transcripts or raw diffs), the
  dispatch packet, the four-status protocol (DONE / DONE_WITH_CONCERNS /
  NEEDS_CONTEXT / BLOCKED) and review before merge.
- **A `CLAUDE.md` stanza** that imports the charter (`@OPERATOR.md`) so it
  survives compaction. With `--inline`, the full charter is written inline
  instead.
- **`.operator/`**, the ledger:

  | Path | What it is | Tracked in git |
  |---|---|---|
  | `VERDICTS.md` | append-only: BAR blocks and one row per verdict | yes |
  | `DECISIONS.md` | append-only: decisions, deviations, deferrals, handoff marks | yes |
  | `verdicts.d/` | per-session copies of every row (merge-repair backstop) | yes |
  | `specs/` | spec artifacts written by `/cc-operator:spec` | yes |
  | `handoff-<date>.md` | the handoff written by `/cc-operator:handoff` | yes |
  | `tiers.env` | project tier bindings | yes |
  | `pending/` | open-task sentinels | no |
  | `bin/` | the six installed gate CLIs (below) | no |

  `.operator/.gitignore` is an allowlist: only the rows marked "yes" are
  tracked, and everything else the plugin creates is ignored.

The CLIs are copied into `.operator/bin/` because the model's shell has no
`${CLAUDE_PLUGIN_ROOT}`. The SessionStart hook refreshes those copies whenever
the plugin version changes or a shipped CLI is newer than its installed copy.

## The evidence gate

```
.operator/bin/ops-task.sh <id> --owner <sid>                     # open a tracked task (drops a sentinel)
.operator/bin/ops-verdict.sh <id> <criterion> <evidence> PASS --owner <sid>   # or FAIL / MOOT; closes it
.operator/bin/ops-verdict.sh <id> --defer "<reason>" --owner <sid>            # honest exit for a blocked task
.operator/bin/ops-adopt.sh --owner <new-sid> <id>...             # re-claim your tasks after /clear
.operator/bin/ops-verdict.sh --reconcile                         # restore rows lost to a messy merge
.operator/bin/ops-verdict.sh --mark-handoff --owner <sid>        # record that the handoff was presented
.operator/bin/ops-claims.sh --since <sha> --claimed "<paths>"    # check a DONE report's CHANGED line against the diff
.operator/bin/ops-spec.sh --new <slug>                           # scaffold a spec
.operator/bin/ops-spec.sh --check <slug>                         # validate its skeleton; writes nothing
.operator/bin/ops-spec.sh --approve <slug> --owner <sid>         # stamp it, log SPEC-APPROVED, emit a BAR block
.operator/bin/ops-backlog.sh --census                            # tracked files, code files, code LOC
```

**The session id.** `<sid>` is the id the SessionStart hook prints at the top
of every session. `CLAUDE_SESSION_ID` is not set in the Bash tool environment
(only hooks receive it), so the hook injects it into the context and you pass
it as `--owner`. After `/clear` the id changes, and the banner prints the
`ops-adopt.sh` line with the new id filled in.

**Verdicts.** `PASS` means the criterion held and `FAIL` means it did not.
`MOOT` means the criterion cannot be evaluated any more, and its evidence cell
must give the reason. `--defer` writes a `DEFERRED-VERDICT` line to
`DECISIONS.md` instead of a row. A row without evidence counts as FAIL by
definition.

**What the Stop hook blocks on.** It exits 2 (blocked) while any of these hold:

- a sentinel **this session owns** is pending;
- an **unowned** sentinel is pending (pre-0.4 sentinels, or a task opened
  without `--owner`). Unowned sentinels fail closed and block everyone;
- a **malformed** entry sits in `pending/`;
- a gated `DECISIONS.md` deviation has not been presented to the human yet.

Sentinels owned by *other* sessions in the same tree are reported but never
block you, and `ops-verdict.sh` refuses to close them. Two sessions can
therefore share one working tree safely.

**Auto-arm.** If the working tree has two or more changed paths (outside
`.operator/`) at stop time, the Stop hook opens a task named `autobar` for the
session, at most once per session, and blocks. The charter's rule that
multi-file work needs a BAR block is enforced in code, not left as a request.
Coverage is deliberately partial: a non-git project arms nothing, and one
deferred task satisfies it. Because the delta is measured on the tree, in a
worktree shared by several sessions it can arm a session for another session's
changes. The alternative, a gate that silently disarms, is the worse failure
(the reasoning is in `scripts/lib/autobar.sh`).

**Loop guard.** When the Stop hook blocks, it records a marker. On the
continuation that follows, it stands down once, and only if the marker is its
own. It therefore never re-blocks a stop it forced itself, and another plugin's
block (a cc-repete loop, for example) cannot switch the gate off.

**The cap detector.** The charter's cap table (identical-rejection ×2,
same-target-rework ×2, neighbor-regressing ×2) is reported by the Stop hook
where it can be measured from the ledger. Today that is same-target-rework
×2: two FAIL rows on one `(task, criterion)` without a PASS in between. It is
report-only, and it never blocks.

**The source stamp.** `ops-verdict.sh` ends every evidence cell with the state
of the tree that produced it: `@<sha>` (clean), `@<sha>+dirty` (anything
outside `.operator/` uncommitted), `@<sha>+unknown` (git could not answer),
`@no-commit` or `@no-vcs`. The stamp says *this row came from that tree*,
not *that tree still passes*. It sits inside the cell so that the 4-cell row
schema (`| Gate | Criterion | Evidence | PASS/FAIL |`) and every `grep`
written against it keep working.

**Concurrency and merges.** `ops-verdict.sh` is the only writer to
`VERDICTS.md`. Under a `mkdir` lock it writes the row to
`verdicts.d/<owner>.md`, appends it to the ledger and clears the sentinel, in
that order. `.operator/.gitattributes` marks the ledgers `merge=union`. If
`VERDICTS.md` still comes out of a merge wrong, resolve it any way you like
and run `--reconcile`: rows are restored from the fragments, and hand-written
BAR blocks are left untouched. (One known gap: a lock held longer than its
timeout is presumed crashed and reclaimed. The timeout sits well above the
slowest real critical section.)

**Naming rules.** Task ids and session ids become filenames, so they must be
bare names: no `/`, no leading `.`, no `|` or newline, and no `__` (the
separator between owner and task in a sentinel's name).

**Re-verification.** `scripts/ops-reverify.sh [--from YYYY-MM-DD] [--to YYYY-MM-DD]`
lists the verdict rows written while HEAD sat inside a date window, such as a
release with a known defect. You can then re-run their criteria. It never writes.

## The engagement cycle and its commands

A session moves through a cycle. At each start the SessionStart banner prints
the **derived stage**, computed from what is on disk (open tasks, deviations,
specs, handoff marks) and never stored. The stages are `BLOCKED`,
`IMPLEMENT`, `HANDOFF`, `SPEC`, `PLAN` and `CLEAR`, with the next move for
each.

| Command | Stage | What it does |
|---|---|---|
| `/cc-operator:tutorial [--keep]` | — | watch the gate block a stop, then clear it with a verdict row |
| `/cc-operator:start [--inline]` | — | install the charter and the ledger into this project |
| `/cc-operator:brainstorm` | diverge | divergent directions, a blindspot scan and a reference search, then an interview one question at a time |
| `/cc-operator:spec` | spec | write, check and approve the spec, the artifact that survives compaction |
| `/cc-operator:plan` | plan | decompose an approved spec into TDD tasks and vet them (needs a spec and a north star) |
| `/cc-operator:implement` | implement | one implementer seat per task, strictly serial, on the IMPLEMENT tier |
| `/cc-operator:review` | review | the review panel over an artifact; a REFUTED verdict is a hard stop |
| `/cc-operator:debate` | decide | 2–5 rival models argue a judgment call over three rounds; you decide |
| `/cc-operator:crawl` | — | digest a large corpus shard by shard, cheaply |
| `/cc-operator:tiers` | — | resolve tier→model bindings, apply one-off overrides, render project agents |
| `/cc-operator:handoff` | handoff | the six-section operator→human handoff |

Every workflow command resolves the tier bindings itself
(`ops-tiers.sh --json`) and passes them to its workflow, so a configured
`tiers.env` reaches the seats without any model id pasted by hand.

The plugin also ships two skills. **`chief-operator`** routes "run as
operator" requests to the charter and `/cc-operator:start`. **`holdout`**
is the procedure for deriving a check suite, from the spec alone, in a process
that cannot read the code (`scripts/ops-holdout.sh --derive --dir <empty-dir>`, with `--canary`
to prove the denial holds on this machine).

## Workflows and tiers

The workflows are deterministic scripts that fan agent seats out across model
tiers and converge on a judgment-tier result:

| Workflow | Shape | Use |
|---|---|---|
| `review` | parallel narrow lenses (two cheap, three judgment), then an adversarial verifier; a REFUTED cannot be outvoted | after a DONE on work that will be merged or depended on |
| `brainstorm` | N divergent directions + blindspot scan + reference search → converge | before a spec exists |
| `plan` | decompose an approved spec into TDD tasks → parallel feasibility and testability vetting | after the spec is approved |
| `implement` | one implementer per task, strictly serial; refuses an incomplete dispatch packet before spending a seat | the implement stage |
| `debate` | 2–5 models argue blind over three rounds → neutral synthesis; `chose` is always null | a decision that turns on judgment rather than measurement |
| `crawl` | one cheap crawler per shard → judgment-tier merge | digesting a large corpus |
| `dispatch` | one seat on a named tier or an explicit model id | running a single seat on its configured model |

**Agents.** There are eight seats, in `agents/op-*.md`: author, mechanic,
reviewer, verifier, scout, brainstorm, crawler and debater. Each seat's
frontmatter names a tier *alias* (`opus`/`sonnet`/`haiku`), never a pinned id.

**Tiers.** Workflows pin each seat to a tier. What a tier resolves to is
layered configuration, where later wins: built-ins →
`~/.claude/cc-operator/tiers.env` → `.operator/tiers.env` → `--set` one-offs.

| Tier | Built-in default | Used for |
|---|---|---|
| `JUDGMENT` | `claude-opus-5` | converging, adversarial review, debate, authoring |
| `IMPLEMENT` | `claude-sonnet-5` | implementation seats |
| `MECHANICAL` | `glm-5.3-flash` | cheap lenses, crawlers, brainstorm directions |
| `RECON` | `claude-haiku-4-5-20251001` | search and lookup |

A `tiers.env` holds three kinds of line: `TIER=model-id`, `seat=TIER` (for
example `op-scout=MECHANICAL`), and the debate panel
(`PANEL=a,b,c`, `PANEL_FALLBACK=…`).

These two scripts are not installed into `.operator/bin/`. Run them through
`/cc-operator:tiers`, or from a plugin checkout:

```
scripts/ops-tiers.sh --show      # the resolved table and where each value came from
scripts/ops-tiers.sh --json      # what the workflow commands pass as args.tiers
scripts/ops-tiers.sh --check     # verify each id against the cc-proxy catalogue
scripts/ops-tiers.sh --suggest   # report a binding a graded model beats on score AND both prices
scripts/ops-tiers.sh --panel     # resolve the cross-vendor debate panel against what the proxy routes
scripts/ops-render.sh            # render .claude/agents/op-*.md so plain Agent dispatch uses the bindings
```

`ops-tiers.sh` judges only that an id is well-formed. Whether a model
exists is cc-proxy's call.

## Hooks

Declared in [`hooks/hooks.json`](hooks/hooks.json), each run from
`${CLAUDE_PLUGIN_ROOT}`:

| Event | Script | Role |
|---|---|---|
| `SessionStart` (startup, resume, clear, compact) | `ops-sessionstart-hook.sh` | injects the session id, refreshes `.operator/bin/`, migrates legacy sentinels, prints the stage banner, wipes per-session scratch state |
| `Stop` | `ops-stop-hook.sh` | the completion gate: auto-arm, then the ownership partition, the deviation scan and the cap report |
| `PostToolUse` (Bash, WebFetch, WebSearch, Grep, Glob, Agent) | `ops-compress.mjs` | the output compressor (below) |

**The compressor.** It scrubs, deduplicates and elides tool output that would
otherwise be billed again on every turn. It works on a strict allowlist: never
Read/Edit/Write/NotebookEdit, never `mcp__*` tools, and never evidence-gate
output (ledger paths and gate CLIs are carved out by path). Elided output is
spilled verbatim to `.operator/.compress-spill/` and the elision cites the
spill path, so evidence can be recovered byte-for-byte. The charter requires
evidence quoted from elided output to cite that path. A project without
`.operator/` gets no spill and no deduplication, and the elision says "not
spilled".

## Status bar (optional)

`scripts/statusline.sh` renders the gate as one segment:

| Segment | Meaning |
|---|---|
| `op[2]` (red) | this session owns 2 open tasks, so your stop is blocked |
| `op[1+2*]` (dim) | 1 is yours, and 2 belong to other sessions in the tree (informational) |
| `dev[1]` (dim) | an unpresented deviation in `DECISIONS.md` that will block stop |
| `wf 2/4` (dim) | a workflow run in flight: results/dispatches from its journal, never a percentage |

The segment runs the Stop hook's own partition rule (`scripts/lib/partition.sh`),
so it answers "will my stop be blocked?", which a raw count of `pending/`
would get wrong. It prints nothing outside operator projects, and nothing when
nothing is open.

With [cc-status](https://github.com/betmoar/cc-status-plugin) the segment is
discovered through `.claude-plugin/statusline.json`, and you toggle it with
`/cc-status:toggle cc-operator on`. Standalone, wire it directly:

```json
"statusLine": { "type": "command", "command": "bash /path/to/cc-operator/scripts/statusline.sh" }
```

## Documentation

The full index is [docs/README.md](docs/README.md). By audience:

| You want to… | Read |
|---|---|
| understand the whole system in plain English | [docs/guide/HANDOUT.md](docs/guide/HANDOUT.md) |
| know why a charter rule exists (`[DOC:spec-*]` tags) | [docs/design/TAGS.md](docs/design/TAGS.md) |
| see the engagement-cycle design (spec, implement, derived stage) | [docs/design/CYCLE.md](docs/design/CYCLE.md) |
| see what was measured before rejecting a decision engine | [docs/design/DECISION-ENGINE-PROBES.md](docs/design/DECISION-ENGINE-PROBES.md) |
| change the plugin safely | [CONTRIBUTING.md](CONTRIBUTING.md), [CLAUDE.md](CLAUDE.md), [docs/maintainer/PLAYBOOK.md](docs/maintainer/PLAYBOOK.md) |
| learn why a guard exists (already-hit failures) | [docs/maintainer/LANDMINES.md](docs/maintainer/LANDMINES.md) |
| audit the plugin in a live session | [docs/maintainer/REPLAY-CHARTER.md](docs/maintainer/REPLAY-CHARTER.md) |
| file or close an unknown | [docs/maintainer/UNKNOWNS.md](docs/maintainer/UNKNOWNS.md) |
| read releases before 0.9 | [docs/history/CHANGELOG-archive.md](docs/history/CHANGELOG-archive.md) |

## Repository layout

```
.claude-plugin/plugin.json          manifest; its version is the source of truth
.claude-plugin/marketplace.json     standalone install path
.claude-plugin/statusline.json      cc-status segment manifest
templates/OPERATOR.md               the charter
templates/{VERDICTS,DECISIONS}-header.md   ledger schemas
commands/*.md                       the 11 slash commands
workflows/*.js                      the 7 workflows
agents/op-*.md                      the 8 seats; agents/_templates/ is the render template
skills/{chief-operator,holdout}/    the router skill and the holdout procedure
hooks/hooks.json                    SessionStart + Stop + PostToolUse
scripts/ops-install-set.sh          the ONE list of CLIs installed into .operator/bin/
scripts/ops-{task,verdict,adopt,claims,spec,backlog}.sh   the installed gate CLIs
scripts/ops-init.sh                 /cc-operator:start's installer
scripts/ops-{stop,sessionstart}-hook.sh   the completion gate + session-id injection
scripts/ops-compress.mjs            the PostToolUse output compressor
scripts/lib/partition.sh            mine/foreign/malformed partition (hook + statusline)
scripts/lib/autobar.sh              the auto-arm rule
scripts/lib/caps.sh                 the cap detector (report-only)
scripts/lib/stage.sh                the derived engagement stage
scripts/ops-{tiers,render}.sh       tier resolver + project-agent renderer
scripts/ops-reverify.sh             rows written inside a date window
scripts/ops-holdout.sh              denied-context derivation (holdout skill)
scripts/ops-tutorial.sh             /cc-operator:tutorial
scripts/statusline.sh               the status-bar segment
scripts/validate_plugin.py          the contract validator
scripts/gate-suite.sh               runs one test rung and holds it to its marker and floor
scripts/base-gate.sh                judges a PR with the BASE branch's enforcer
scripts/release_gate.py             tag == version == newest changelog heading
scripts/ci-local.sh                 run the CI job locally, on CI's platform
tests/                              bash suite, Python tests, two node suites, floors.env
.github/workflows/, .forgejo/workflows/   CI: validate, base-gate, release (GitHub + local Forgejo)
docs/                               guide, design, maintainer, history (see docs/README.md)
```

## Development

There is no build step. The validator and tests use Python 3 (stdlib only),
bash and node. CI runs exactly these, and a PR should pass them locally first:

```
docker run --rm -v "$PWD":/w -w /w koalaman/shellcheck-alpine:v0.10.0 \
  shellcheck scripts/*.sh scripts/lib/*.sh tests/test-scripts.sh
bash scripts/gate-suite.sh validator
bash scripts/gate-suite.sh python
bash scripts/gate-suite.sh shell        # ~4 min; never run two at once
bash scripts/gate-suite.sh workflows
bash scripts/gate-suite.sh compress
```

`gate-suite.sh` checks each rung's completion marker and its case-count
floor in `tests/floors.env`, so if you add cases you must raise the floor in
the same commit. Shellcheck is pinned to v0.10.0 because 0.10 and 0.11 disagree.
On pull requests, `scripts/base-gate.sh` also runs from the base branch and
refuses a PR that weakens the enforcer (a lowered floor, a dropped check, a
deleted test). Releases go through `scripts/release_gate.py`.

Conventions and the release process are in [CONTRIBUTING.md](CONTRIBUTING.md).
The "if you touch X, update Y" couplings are in [CLAUDE.md](CLAUDE.md).

## License

[MIT](LICENSE)
