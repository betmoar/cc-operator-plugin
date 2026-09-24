---
description: Watch the evidence gate work — a throwaway project where the real Stop hook blocks on an open task and then lets the stop through once a verdict row records the evidence.
argument-hint: "[--keep]"
allowed-tools: Bash(bash:*)
---

Run the tutorial and relay its output to the user verbatim — do not summarize it
first. The point is that they SEE the block, not that they read about it (#75):

```
bash "${CLAUDE_PLUGIN_ROOT}/scripts/ops-tutorial.sh" $ARGUMENTS
```

It scaffolds a throwaway git project in a temp directory, opens a tracked task,
feeds the real `ops-stop-hook.sh` a Stop payload (exit 2 — blocked), records a
verdict row with evidence through the installed `ops-verdict.sh`, and feeds the
hook again (exit 0 — allowed). It prints `TUTORIAL_OK` only when it observed
both; anything else is `TUTORIAL_FAILED` with the two exit codes, and the plugin
is broken on this machine — say so rather than explaining what should have
happened. Pass `--keep` to leave the project on disk for the user to explore.

Then give the user the next step in two lines: `/cc-operator:start` in their own
project, then a BAR block in `.operator/VERDICTS.md` before the first
multi-file change (`OPERATOR.md` § ENGAGEMENT CONTRACT).
