# Contributing to cc-operator

The plugin is small but no longer tiny: a charter, the evidence-gate scripts,
a slash command per workflow plus the gate/session commands, tier-aliased
agents, the orchestration workflows, wired hooks and two skills (the
chief-operator router and the holdout procedure). Most
contributions are edits to the charter prose or the gate scripts, not new
machinery.

## Repository layout

```
.claude-plugin/plugin.json        # manifest (name, version — source of truth)
.claude-plugin/marketplace.json   # standalone install path; name must match plugin.json + ccp-market
templates/OPERATOR.md             # the charter — <=150 lines, citation-tagged
templates/{VERDICTS,DECISIONS}-header.md   # ledger schemas — byte-identical to the proven originals
commands/*.md                     # slash commands
agents/*.md                       # tier-aliased delegation roles (author/mechanic/reviewer/scout/verifier/crawler/brainstorm/debater)
workflows/*.js                    # orchestration primitives (review/plan/brainstorm/crawl/dispatch/debate/implement)
skills/chief-operator/SKILL.md    # thin router (front door only — nothing load-bearing)
skills/holdout/SKILL.md           # the holdout procedure (#150); its CLI is scripts/ops-holdout.sh
scripts/ops-*.sh                  # the evidence-gate mechanism, the tier resolver/renderer, spec/reverify/holdout/tutorial CLIs
scripts/lib/*.sh                  # shared, sourced-only rules: partition (gate), autobar (#85), caps (#107), stage (#157)
scripts/ops-compress.mjs          # the PostToolUse output compressor
scripts/validate_plugin.py        # contract linter — run before every PR
scripts/release_gate.py           # release-tag coupling gate
scripts/gate-suite.sh             # runs one test rung, checks its marker + tests/floors.env
scripts/base-gate.sh              # the pull_request_target enforcer judged by code the PR cannot edit (#108)
scripts/ci-local.sh               # runs a CI job locally in the pinned container
hooks/hooks.json                  # SessionStart + Stop + PostToolUse (compressor)
tests/                            # bash + stdlib Python + node suites
tests/floors.env                  # the case-count floor per suite — raise it in the same commit that adds cases
.github/workflows/                # GitHub CI (validate, base-gate, release)
.forgejo/workflows/                # the Forgejo/lokaal mirror — same suites, deliberately not identical (see CLAUDE.md)
```

See [`CLAUDE.md`](CLAUDE.md) for the maintainer handoff: the load-bearing
couplings and the landmines. `docs/` holds the design rationale — read-only,
not runtime (`TAGS.md` resolves the charter's `[DOC:spec-*]` tags; the spec
directory itself emptied in 0.11.9); build and pilot history lives in the git
history (tree ≤ v0.2.0).

## Dev setup

No build step, no dependencies beyond Python 3 (stdlib), bash and node. Against a live
Claude Code:

```
/plugin marketplace add /path/to/cc-operator-plugin
/plugin install cc-operator
```

After editing a component, `/reload-plugins` so changes take effect.

## Load-bearing contracts (the validator enforces these — do not route around it)

- **The charter is capped at 150 lines**, its sections appear in a fixed order,
  and it carries `[D:...]` / `[DOC:...]` citation tags. The validator enforces
  at least one tag per section and that every `[DOC:spec-*]` tag resolves in
  `docs/design/TAGS.md`; tagging every rule line is the convention, held by
  review, not by the validator. Adding content means staying under
  the cap — if it does not fit, something else comes out.
- **Ledger schemas are byte-frozen.** `VERDICTS-header.md`'s table header is
  exactly `| Gate | Criterion | Evidence | PASS/FAIL |`. Grep habits and any
  downstream tooling depend on it; changing a column is a breaking change.
- **Agents stay project-agnostic** (a `name`/`model`/`tools` frontmatter, a
  NEEDS_CONTEXT clause, no `unknowns-harness`/`F1..F13` build naming) and keep
  their tier intent via **aliases only** — opus for author/reviewer/verifier,
  sonnet for mechanic, haiku for scout. Never a pinned model ID: pinned IDs
  hard-error when a version is retired; the validator rejects them.
- **`ops-verdict.sh` is the single writer to `VERDICTS.md`.** Append-only holds
  by construction because the append and the sentinel-clear are one action —
  never add a second writer.
- **The Stop hook must fail open.** If `jq`/`python3` are both absent it exits 0
  with a warning; a broken hook must never brick a session.

## Conventions

- **kebab-case** for file and directory names.
- **Command descriptions** say what the command runs in one line, and when a
  command has no workflow behind it (`start`, `handoff`), *when* to run it. The
  body carries the procedure.
- Match the surrounding voice — terse, imperative, concrete. Wrap prose at ~80
  columns to match existing files.

## Changing behavior

- Update [`CHANGELOG.md`](CHANGELOG.md) under `## [Unreleased]` in the same
  commit.
- If the change is user-visible, bump the version in
  [`.claude-plugin/plugin.json`](.claude-plugin/plugin.json) — the single source
  of truth — following [SemVer](https://semver.org/).
- Validate before opening a PR. `.github/workflows/validate.yml` runs, in this
  order: shellcheck (pinned, see below), then each rung of
  `bash scripts/gate-suite.sh <rung>` — `validator`, `python`, `shell`,
  `workflows`, `compress`. Every rung is wrapped: `gate-suite.sh` requires the
  rung's own completion marker in its output and holds its case count to the
  floor declared in `tests/floors.env` (raise the floor in the same commit that
  adds cases — nothing raises it for you). Reproduce it locally:

  ```
  docker run --rm -v "$PWD":/w -w /w koalaman/shellcheck-alpine:v0.10.0 \
    sh -c 'shellcheck scripts/*.sh scripts/lib/*.sh tests/test-scripts.sh'
  bash scripts/gate-suite.sh validator
  bash scripts/gate-suite.sh python
  bash scripts/gate-suite.sh shell
  bash scripts/gate-suite.sh workflows
  bash scripts/gate-suite.sh compress
  ```

  **shellcheck is pinned in CI** to `koalaman/shellcheck-alpine:v0.10.0`, and
  versions disagree — a newer local shellcheck missed an SC2015 that CI
  reports, so run it through the pinned container, not a local install (or use
  `scripts/ci-local.sh`). **The `shell` rung takes roughly 4 minutes and reads
  `.operator/` from the cwd it runs in** — do not run it concurrently with
  another `shell`-rung run (two overlapping runs have produced phantom
  failures), and run it from a neutral cwd such as `/tmp` if failures cluster
  in the statusline block, since a project with leftover pending sentinels
  sees cases CI (which has no `.operator/`) never sees.

  Two more gates run in CI but not in this list: `scripts/base-gate.sh` (a
  `pull_request_target` job that runs the BASE branch's enforcer against the
  tree the merge would produce; the PR's code is never checked out, and it
  refuses a lowered floor, a dropped check or rung, or a deleted test)
  and `scripts/release_gate.py` (tag/CHANGELOG coupling, see Releasing below).
  Coupling rules for all of the above — what touching a rung, a floor, or a
  CI file obligates you to also update — are in `CLAUDE.md`'s "If you touch X"
  table; read it before changing a gate script.

## Releasing

1. Merge to `main` with `plugin.json` bumped and its `## [x.y.z]` entry newest
   in `CHANGELOG.md` (below `[Unreleased]`).
2. Push a tag `v<x.y.z>`. `.github/workflows/release.yml` re-runs the gate
   (`scripts/release_gate.py`) + full validation and publishes a GitHub release
   whose body is that version's CHANGELOG section. Any mismatch between tag,
   `plugin.json`, and the newest heading fails the build.
