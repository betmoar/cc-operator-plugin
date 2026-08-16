# Contributing to cc-operator

The plugin is small but no longer tiny: a charter, the evidence-gate scripts,
three slash commands, seven agents, five orchestration workflows, four wired
hooks and a thin skill. Most contributions are edits to the charter prose or the
gate scripts, not new machinery.

## Repository layout

```
.claude-plugin/plugin.json        # manifest (name, version — source of truth)
.claude-plugin/marketplace.json   # standalone install path; name must match plugin.json + ccp-market
templates/OPERATOR.md             # the charter — <=150 lines, every rule line citation-tagged
templates/{VERDICTS,DECISIONS}-header.md   # ledger schemas — byte-identical to the proven originals
commands/{start,handoff,tiers}.md # slash commands (trigger-only frontmatter descriptions)
agents/*.md                       # tier-aliased delegation roles (author/mechanic/reviewer/scout/verifier/crawler/brainstorm)
workflows/*.js                    # orchestration primitives (review/plan/brainstorm/crawl/dispatch)
skills/chief-operator/SKILL.md    # thin router (front door only — nothing load-bearing)
scripts/ops-*.sh                  # the evidence-gate mechanism, the tier resolver/renderer, the corpus builder
scripts/ops-compress.mjs          # the PostToolUse output compressor
scripts/validate_plugin.py        # contract linter — run before every PR
scripts/release_gate.py           # release-tag coupling gate
hooks/hooks.json                  # SessionStart + Stop + PreToolUse (arm gate) + PostToolUse (compressor)
tests/                            # bash + stdlib Python + node suites
```

See [`CLAUDE.md`](CLAUDE.md) for the maintainer handoff: the load-bearing
couplings and the landmines. `docs/spec/` holds the design spec — read-only
rationale, not runtime; build and pilot history lives in the git history
(tree ≤ v0.2.0).

## Dev setup

No build step, no dependencies beyond Python 3 (stdlib) and bash. Against a live
Claude Code:

```
/plugin marketplace add /path/to/cc-operator-plugin
/plugin install cc-operator
```

After editing a component, `/reload-plugins` so changes take effect.

## Load-bearing contracts (the validator enforces these — do not route around it)

- **The charter is capped at 150 lines**, its sections appear in a fixed order,
  and **every rule line carries a `[D:...]` or `[DOC:...]` citation tag**. A rule
  without a tag does not ship (build gate B2). Adding content means staying under
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
- **Command descriptions are trigger-only** — say *when* to run the command, not
  what it does (the body says what).
- Match the surrounding voice — terse, imperative, concrete. Wrap prose at ~80
  columns to match existing files.

## Changing behavior

- Update [`CHANGELOG.md`](CHANGELOG.md) under `## [Unreleased]` in the same
  commit.
- If the change is user-visible, bump the version in
  [`.claude-plugin/plugin.json`](.claude-plugin/plugin.json) — the single source
  of truth — following [SemVer](https://semver.org/).
- Validate before opening a PR. CI runs these six, in this order — the two node
  suites are easy to forget and a PR that skips them can go green locally and
  red in CI:

  ```
  shellcheck scripts/*.sh tests/test-scripts.sh
  python3 scripts/validate_plugin.py
  python3 -m unittest discover -s tests
  bash tests/test-scripts.sh
  node tests/test_workflows.mjs
  node tests/test_compress.mjs
  ```

  Two things the local run does not reproduce by itself. **shellcheck is pinned
  in CI** to `koalaman/shellcheck-alpine:v0.10.0`, and versions disagree — a
  newer local shellcheck missed an SC2015 that CI reports, so check with the
  container command from `.github/workflows/validate.yml` before trusting a
  clean local run. **`bash tests/test-scripts.sh` reads `.operator/`** from the
  cwd it runs in, so a project with leftover pending sentinels sees statusline
  cases fail that CI (which has no `.operator/`) never sees; run it from a
  neutral cwd such as `/tmp` if the failures are all in the statusline block.

## Releasing

1. Merge to `main` with `plugin.json` bumped and its `## [x.y.z]` entry newest
   in `CHANGELOG.md` (below `[Unreleased]`).
2. Push a tag `v<x.y.z>`. `.github/workflows/release.yml` re-runs the gate
   (`scripts/release_gate.py`) + full validation and publishes a GitHub release
   whose body is that version's CHANGELOG section. Any mismatch between tag,
   `plugin.json`, and the newest heading fails the build.
