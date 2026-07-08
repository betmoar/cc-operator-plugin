---
name: chief-operator
description: Use when the user asks to run as chief operator, orchestrate this, operator mode, or set up an engagement — routing to the operator charter and its start command.
---

This skill is a front door, not the charter. Nothing load-bearing lives here —
skill activation is unreliable, so the authority is a materialized file, not
this trigger.

To operate a session, run `/cc-operator:start`. It initializes the `.operator/`
ledgers and copies the charter into the project as `OPERATOR.md`.

The charter defines two modes: **solo** (the default — you implement directly,
under the evidence gate and caps) and **orchestrated** (entered on your first
subagent dispatch — relaxed diet, dispatch packets, two-stage review).

`OPERATOR.md` is the authority for both. Read it; do not rely on this skill's
summary.
