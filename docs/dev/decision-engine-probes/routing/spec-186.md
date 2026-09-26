## What was measured

Four-agent review of PR #185 (the #177 plan gate + #178 node guard), HEAD 0f53b63. The gate itself (`workflows/plan.js` `/^Status:[ \t]*(\S+)/m`, first-token `!== "APPROVED"`) is correct. Six inputs around it are UNPINNED — no test would notice a behavior change:

| input | current behavior | polarity |
|---|---|---|
| two Status lines (`DRAFT` first, `APPROVED` later) | first wins → refused | fail-closed |
| `Status: APPROVED` after `﻿` BOM | no match → proceeds as `unstamped` | visible via `specStatus` |
| indented `  Status: DRAFT` | no match → proceeds as `unstamped` | visible via `specStatus` |
| lowercase `approved` | refused | fail-closed |
| CRLF-terminated stamp | captures `APPROVED` cleanly (`\S` stops before `\r`; probed live) | correct |
| column-0 `Status: DRAFT` inside a fenced block | refused (anchor is not fence-aware) | fail-closed |

## Why it matters

Three of these proceed via the spec-less path without a refusal; today that is visible in the result's `specStatus` field, but nothing pins the direction. A future loosening (`^\s*` prefix, case-insensitive match, last-line-wins) ships green. Two already have single-case coverage gaps noted during review (case-sensitivity, first-line-wins).

## What would close it

One parametrized node case block pinning all six behaviors (≈10 assertions, the `statusSpec` fixture already exists in tests/test_workflows.mjs). Do it whenever the gate regex is next touched, not as a standalone change.

Reviewed by: 4-agent PR review panel (code, tests, comments, silent-failure), fixes in 0f53b63. The two IMPORTANT gaps (early-return `specStatus`, zero-spend assertion) and the unpinned node-guard SHAPE are fixed in that commit — this issue is only the accepted edges.
