# cc-operator

A Claude Code plugin that makes a session **operate under a charter**: it
materializes an operating charter, an append-only evidence ledger, and a
Stop-hook completion gate into a project, so "done" means *evidenced*, not
asserted.

It is the operator layer that composes with the
[`cc-unknowns`](https://github.com/betmoar/cc-unknowns-plugin) discovery skill:
`cc-unknowns` surfaces what you don't know before building; `cc-operator` gates
what you claim after.

## What it installs into a project

`/cc-operator:start` writes into the project root:

- **`OPERATOR.md`** — a two-mode operating charter (≤150 lines, every rule line
  citation-tagged). **Solo mode** (default): you implement directly, under the
  evidence gate and the loop caps. **Orchestrated mode** (on first subagent
  dispatch): a relaxed context diet, dispatch packets, and two-stage review.
- **`.operator/`** — the ledger: `VERDICTS.md` (append-only, one row per
  gated task), `DECISIONS.md` (append-only, one line per deviation/decision),
  `pending/` (task sentinels), and `bin/` (the gate CLIs `ops-task.sh` +
  `ops-verdict.sh`, installed so the charter's paths resolve in any project;
  refreshed on every re-run of `/cc-operator:start`).
- A **CLAUDE.md** stanza importing the charter (`@OPERATOR.md`) so it survives
  compaction, or the full charter inlined with `--inline`.

The **Stop hook** blocks the session from ending while any task sentinel is
still pending its verdict — a completion claim on a tracked task requires a
ledger row whose evidence cell is real command output.

## Commands

| Command | Purpose |
|---|---|
| `/cc-operator:start [--inline]` | Initialize the ledger + materialize the charter |
| `/cc-operator:handoff` | Produce the six-section operator→human handoff |

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
.operator/bin/ops-task.sh <id>                   # open a tracked task (drops the sentinel)
.operator/bin/ops-verdict.sh <id> <criterion> <evidence> <PASS|FAIL>   # the single writer to VERDICTS.md
.operator/bin/ops-verdict.sh <id> --defer "<reason>"   # honest exit for a blocked task
```

`ops-init.sh` (run by `/cc-operator:start`) installs those CLIs into
`.operator/bin/` so they resolve from the project root — the model's shell has
no `${CLAUDE_PLUGIN_ROOT}`. Opening a tracked task drops
`.operator/pending/<id>`. `ops-verdict.sh` is the only writer to `VERDICTS.md`:
it appends the row and clears the sentinel in one action, so append-only holds
by construction. The Stop hook (`hooks/hooks.json` → `scripts/ops-stop-hook.sh`)
exits 2 while any sentinel is pending, feeding the operator the instruction to
record or defer the verdict; it fails open if neither `jq` nor `python3` is
available, so a missing dependency never bricks a session.

## Repository layout

```
.claude-plugin/plugin.json        # manifest (name cc-operator, version — source of truth)
.claude-plugin/marketplace.json   # standalone install path (source "./")
templates/OPERATOR.md             # the charter (materialized by /cc-operator:start)
templates/{VERDICTS,DECISIONS}-header.md   # ledger schemas (byte-identical to the proven originals)
commands/{start,handoff}.md       # the two slash commands
agents/op-*.md                    # tier-aliased roles: author, mechanic, reviewer, scout, verifier
skills/chief-operator/SKILL.md    # thin router (front door only)
scripts/ops-{init,task,verdict,stop-hook}.sh   # the evidence-gate mechanism
scripts/validate_plugin.py        # contract linter — run before every PR
scripts/release_gate.py           # tag == version == newest changelog heading
hooks/hooks.json                  # Stop-hook wiring via ${CLAUDE_PLUGIN_ROOT}
tests/                            # bash script suite + stdlib Python tests
```

## Development

No build step; Python 3 (stdlib only) for the validator and tests. Before a PR
(CI runs the same):

```
shellcheck scripts/*.sh tests/test-scripts.sh
python3 scripts/validate_plugin.py
python3 -m unittest discover -s tests
bash tests/test-scripts.sh
```

See [CONTRIBUTING.md](CONTRIBUTING.md) for conventions and
[CLAUDE.md](CLAUDE.md) for the maintainer handoff (the "if you touch X, update
Y" couplings). The design spec lives under `docs/spec/`; build and pilot
history lives in the git history (tree ≤ v0.2.0).

## License

[MIT](LICENSE)
