# cc-operator

A Claude Code plugin that makes a session **operate under a charter**: it
materializes an operating charter, an append-only evidence ledger, and a
Stop-hook completion gate into a project, so "done" means *evidenced*, not
asserted.

Discovery is built in: the charter's **Discovery discipline** (formerly the
separate [`cc-unknowns`](https://github.com/betmoar/cc-unknowns-plugin)
plugin, folded in as of 0.5.0 and retired) surfaces what you don't know
before building — interview, blindspot pass, plan vetting, adversarial
pre-done — and the evidence gate gates what you claim after. Sole external
dependency: [cc-proxy](https://github.com/betmoar/cc-proxy-plugin) for
non-Anthropic model routing.

## Getting started

Install (below), then run **`/cc-operator:tutorial`**. It builds a throwaway
project and shows the real Stop hook blocking a session that has an open task,
then letting it end once a verdict row records the evidence. Watching the block
is the fastest way to see what the gate is for. Then run `/cc-operator:start`
in your own project.

## What it installs into a project

`/cc-operator:start` writes into the project root:

- **`OPERATOR.md`** — a two-mode operating charter (≤150 lines, every rule line
  citation-tagged). **Solo mode** (default): you implement directly, under the
  evidence gate and the loop caps. **Orchestrated mode** (on first subagent
  dispatch): a relaxed context diet, dispatch packets, and two-stage review.
- **`.operator/`** — the ledger: `VERDICTS.md` (append-only, one row per
  gated task), `DECISIONS.md` (append-only, one line per deviation/decision),
  `verdicts.d/` (per-session row fragments — a merge-repair backstop),
  `pending/` (task sentinels), `specs/` (the spec artifacts), and `bin/` (the
  six gate CLIs `ops-task.sh`, `ops-verdict.sh`, `ops-adopt.sh`,
  `ops-claims.sh`, `ops-backlog.sh` and `ops-spec.sh`,
  installed so the charter's paths resolve in any project; refreshed on every
  re-run of `/cc-operator:start`).
- A **CLAUDE.md** stanza importing the charter (`@OPERATOR.md`) so it survives
  compaction, or the full charter inlined with `--inline`.

The **Stop hook** blocks the session from ending while any task sentinel **it
owns** is still pending its verdict — a completion claim on a tracked task
requires a ledger row whose evidence cell is real command output.

**Concurrent sessions.** Two sessions can share one working tree. Each sentinel
stamps the session that opened it, so a session is gated by its own open tasks
only; another session's are reported as informational and are refused by the
writer if you try to close them. A sentinel with no owner blocks everyone — the
safe default, and what pre-0.4 sentinels degrade to.

## Orchestration layer (0.5.0)

Seven **workflows** are the operator's dispatch primitives — deterministic
scripts that fan agent seats across model tiers and converge on judgment:

| Workflow | Shape | Use |
|---|---|---|
| `cc-operator:review` | parallel narrow lenses (two cheap, three judgment) → adversarial verifier; a REFUTED is a hard stop | after a DONE on work that will be merged or depended on |
| `cc-operator:brainstorm` | N divergent directions + blindspot scan + reference search → converge | before a spec exists |
| `cc-operator:plan` | decompose an approved spec into TDD tasks → parallel feasibility/testability vetting | after a spec is approved |
| `cc-operator:crawl` | one cheap crawler per shard → judgment-tier merge | digesting a large corpus fast |
| `cc-operator:debate` | 2–5 caller-named models argue blind over three rounds → reviewer synthesis, `chose` always null | a decision worth paying rival flagships to disagree about |
| `cc-operator:implement` | one implementer seat per task, STRICTLY SERIAL, on the IMPLEMENT tier; refuses an incomplete dispatch packet before spending a seat | the implement stage — every other stage of the cycle was already a workflow (#158) |
| `cc-operator:dispatch` | one seat, on a caller-supplied id or a named tier; with neither, no model override at all | running a seat on its configured tier without rendering (#55, #158) |

**Tier system.** Seats are pinned to tiers (`JUDGMENT`, `IMPLEMENT`,
`MECHANICAL`, `RECON`) in each workflow; what a tier *resolves to* is layered
config: built-ins → `~/.claude/cc-operator/tiers.env` → `.operator/tiers.env`
→ `--set` one-offs. `ops-tiers.sh` resolves (charset-guarded; it does not
judge which ids exist — that is cc-proxy's call) and the operator passes the result as `args.tiers`; `ops-render.sh`
renders project-layer agents so plain Agent dispatch can run on configured
models. `/cc-operator:tiers` wraps both.

**Input-axis compressor.** A PostToolUse hook (`scripts/ops-compress.mjs`)
scrubs/dedups/elides re-billed tool output on a strict allowlist — never
Read/Edit/Write/NotebookEdit, never `mcp__*`, never evidence-gate output
(ledger paths and gate CLIs are carved out by path). Elided output is spilled
verbatim (pre-scrub) and cited, so evidence stays recoverable byte-for-byte — to
`.operator/.compress-spill/`, and **only** there: a project that never ran
`/cc-operator:start` gets no spill and no dedup state, and the elide says "not
spilled" rather than writing somewhere the user never asked for (0.10 removed the
tempdir fallback). The spill root carries its own `*` ignore, and
`.operator/.gitignore` is an allowlist: the two ledgers, the `verdicts.d/`
fragments, `tiers.env` and `specs/` are tracked; everything else the plugin
creates is ignored by default. The scheme is versioned — a v1 blocklist is
REPLACED behind a verified backup (the two contradict), while a v2 allowlist
is APPENDED to, because v3 only adds lines and a rewrite would delete allow
lines you added by hand (#156).

## Commands

Every workflow command resolves the tier bindings itself (`ops-tiers.sh --json`)
and passes them through, so a configured `tiers.env` reaches the seats without
the operator pasting a model id by hand (#55 at the call site).

| Command | Purpose |
|---|---|
| `/cc-operator:tutorial` | Watch the gate block a stop, then clear it with a verdict row |
| `/cc-operator:start [--inline]` | Initialize the ledger + materialize the charter |
| `/cc-operator:handoff` | Produce the six-section operator→human handoff |
| `/cc-operator:tiers` | Resolve tier→model bindings, apply overrides, render project-layer agents |
| `/cc-operator:brainstorm` | Diverge before a spec exists, then interview one question at a time |
| `/cc-operator:spec` | Write, check and approve the spec — the artifact that survives a compaction |
| `/cc-operator:plan` | Decompose an approved spec into vetted TDD tasks |
| `/cc-operator:implement` | One implementer seat per task, serially, on the IMPLEMENT tier |
| `/cc-operator:review` | The two-stage review panel over an artifact |
| `/cc-operator:crawl` | Digest a large corpus by shard, cheaply |
| `/cc-operator:debate` | 2–5 rival models argue a judgment call; you decide |

## Install

```
/plugin marketplace add betmoar/cc-operator-plugin
/plugin install cc-operator
```

Or from a local checkout:

```
/plugin marketplace add /path/to/cc-operator-plugin
/plugin install cc-operator
```

## The evidence gate, concretely

```
.operator/bin/ops-task.sh <id> --owner <session-id>     # open a tracked task (drops the sentinel)
.operator/bin/ops-verdict.sh <id> <criterion> <evidence> <PASS|FAIL|MOOT> --owner <session-id>
.operator/bin/ops-verdict.sh <id> --defer "<reason>"    # honest exit for a blocked task
.operator/bin/ops-adopt.sh --owner <new-id> <id>...     # re-claim your tasks after a /clear
.operator/bin/ops-verdict.sh --reconcile                # restore rows lost to a messy merge
.operator/bin/ops-claims.sh --since <sha> --claimed "<paths>"   # verify a DONE report against the diff
.operator/bin/ops-spec.sh --new <slug>                          # scaffold the spec the plan stage reads
.operator/bin/ops-spec.sh --check <slug>                        # validate its skeleton; writes nothing
.operator/bin/ops-spec.sh --approve <slug> --owner <id>         # stamp it, log SPEC-APPROVED, emit the BAR block
```

`ops-init.sh` (run by `/cc-operator:start`) installs those CLIs into
`.operator/bin/` so they resolve from the project root — the model's shell has
no `${CLAUDE_PLUGIN_ROOT}`. Opening a tracked task drops
`.operator/pending/<id>`, stamped with the owning session. `ops-verdict.sh` is
the only writer to `VERDICTS.md`: under a `mkdir`-based lock it mirrors the row
to `verdicts.d/<owner-or-unowned>.md`, appends it, and clears the sentinel — so
writes are mutually exclusive against concurrent sessions, not merely
append-only. (One stated gap: a lock held past the timeout is presumed crashed
and reclaimed, so a writer that genuinely ran longer would be overrun. The
budget sits well above the slowest real critical section.) The Stop hook
(`hooks/hooks.json` → `scripts/ops-stop-hook.sh`) exits 2 while any sentinel
owned by that session is pending; it fails open if neither `jq` nor `python3` is
available, so a missing dependency never bricks a session.

**Where the session id comes from:** `CLAUDE_SESSION_ID` is not set in the Bash
tool environment — only hooks receive it. The SessionStart hook
(`scripts/ops-sessionstart-hook.sh`) injects it into the session's context, and
the charter instructs the operator to pass it as `--owner`.

**What a row is bound to:** the evidence cell ends with a source-state stamp
that `ops-verdict.sh` resolves itself — `@<sha>` for a clean tree, `@<sha>+dirty`
when anything outside `.operator/` was uncommitted, `@no-commit` in a repo with
no commits, `@no-vcs` outside git, `@<sha>+unknown` when git could not answer.
Without it a PASS survived unstaged, staged, committed and untracked mutation of
the source it had just verified, with nothing marking the row stale. Read it for
what it is: the stamp is written by the same process that writes the row, so it
says *this row came from that tree*, not *that tree passes*. It is deliberately
inside the cell rather than a fifth column, so every existing ledger and every
`grep` written against the 4-cell schema keeps working.

**Across branches:** each session's rows also live in its own
`verdicts.d/<owner>.md`, which git merges cleanly, and `.operator/.gitattributes`
marks the ledgers `merge=union`. If `VERDICTS.md` still comes out of a merge
wrong, resolve it any way at all and run `--reconcile` — every row is restored
from the fragments. It repairs, never regenerates: hand-written BAR blocks in
`VERDICTS.md` survive untouched, and any fragment line that does not match the
4-cell `PASS`/`FAIL` schema is skipped and reported rather than copied in.

Task ids and session ids are filenames, so they must be bare names: no `/`, no
leading `.` (a dotfile sentinel would be invisible to the Stop hook's glob), no
`|` or newlines (they would break the ledger's one-line row schema).

**On the status bar (optional).** `scripts/statusline.sh` renders the gate as a
segment: `op[2]` when this session owns 2 open tasks (red — your stop is
blocked), `op[1+2*]` when 1 is yours and 2 belong to other sessions in the tree
(dim — informational). It prints nothing outside operator projects and nothing
when there is nothing open.

It deliberately does **not** count `.operator/pending/`. Since 0.4.0 the Stop
hook blocks only on sentinels this session owns, plus unowned ones, so a raw
count answers a different question than "will my stop be blocked?" — and gets
it wrong in both directions. The segment runs the hook's own partition instead,
against the session id in the statusline payload.

Since 0.5.0 the segment also shows in-flight workflow progress: `wf 2/4` is
the dispatched-work ratio (results/started) from the run's journal — never a
percentage, since the total isn't known until the last dispatch. An unbalanced
journal (dispatches still outstanding) holds the segment live through long
quiet stretches; a finished run clears within ~90s.

Installed with [cc-status](https://github.com/betmoar/cc-status-plugin) as the
composer, it is discovered automatically via `.claude-plugin/statusline.json`
and toggled with `/cc-status:toggle cc-operator on`. Standalone, wire it
directly:

```json
"statusLine": { "type": "command", "command": "bash /path/to/cc-operator/scripts/statusline.sh" }
```

## Repository layout

```
.claude-plugin/plugin.json        # manifest (name cc-operator, version — source of truth)
.claude-plugin/marketplace.json   # standalone install path (source "./")
templates/OPERATOR.md             # the charter (materialized by /cc-operator:start)
templates/{VERDICTS,DECISIONS}-header.md   # ledger schemas (byte-identical to the proven originals)
commands/*.md                     # slash commands: start, handoff, tiers, tutorial + one per workflow
workflows/{review,brainstorm,plan,crawl,dispatch,debate,implement}.js  # the orchestration primitives
agents/op-*.md                    # tier-aliased seats: author, mechanic, reviewer, scout, verifier, brainstorm, crawler, debater
skills/chief-operator/SKILL.md    # thin router (front door only)
skills/holdout/SKILL.md           # deriving/repairing a holdout the builder cannot read (#150)
scripts/ops-{init,task,verdict,adopt,claims,backlog,spec}.sh  # the evidence-gate mechanism
scripts/ops-install-set.sh        # the .operator/bin install manifest (both writers source it)
scripts/ops-{stop,sessionstart}-hook.sh # completion gate + session-id injection
scripts/lib/partition.sh          # the mine/foreign partition rule — hook + statusline share it
scripts/ops-{tiers,render}.sh     # tier resolver + project-layer agent renderer
scripts/ops-holdout.sh            # denied-context derivation + its --canary (the holdout skill's CLI)
scripts/ops-tutorial.sh           # /cc-operator:tutorial — self-checking block-then-clear demo
scripts/ops-compress.mjs          # input-axis compressor (PostToolUse)
.claude-plugin/statusline.json    # cc-status segment manifest (name/render/order)
scripts/statusline.sh             # the segment: open tasks, partitioned by owner
scripts/validate_plugin.py        # contract linter — run before every PR
scripts/release_gate.py           # tag == version == newest changelog heading
hooks/hooks.json                  # SessionStart + Stop + PostToolUse (compressor), via ${CLAUDE_PLUGIN_ROOT}
tests/                            # bash suite + stdlib Python tests + two node suites
```

## Development

No build step; Python 3 (stdlib only) for the validator and tests. Before a PR
(CI runs the same):

```
shellcheck scripts/*.sh tests/test-scripts.sh
python3 scripts/validate_plugin.py
python3 -m unittest discover -s tests
bash tests/test-scripts.sh
node tests/test_workflows.mjs
node tests/test_compress.mjs
```

See [CONTRIBUTING.md](CONTRIBUTING.md) for conventions and
[CLAUDE.md](CLAUDE.md) for the maintainer handoff (the "if you touch X, update
Y" couplings). Design rationale lives under `docs/` — `TAGS.md` resolves the
charter's `[DOC:spec-*]` tags, `LANDMINES.md` holds the already-hit failure
classes, `CYCLE.md` specifies the engagement cycle's missing spec stage; build
and pilot history lives in the git history (tree ≤ v0.2.0).

## License

[MIT](LICENSE)
