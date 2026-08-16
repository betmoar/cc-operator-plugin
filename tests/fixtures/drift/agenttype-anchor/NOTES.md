# agenttype-anchor — modeled on #70 round-2/round-1 instance 7 (checker anchors on X, actually anchors on Y)

**Claim (drifted/dispatch.mjs, comment):** "check_workflow_agent_types
anchors on the `agentType:` key — concatenation would let a typo'd seat ship
green."

**The code that falsifies it:** `dispatch()` never writes an `agentType:`
key literal at all — it returns the shorthand property `agentType,` whose
value is read out of the `SEATS` table. A checker that greps for the key
`agentType:` finds nothing in this file, so the guard the comment describes
does not anchor on anything present here. This is the real PR #71 instance:
the checker actually anchors on the string VALUE (the literal
`"cc-operator:op-*"` form), not the key — and the comment describing it got
that backwards. Measured: every one of the six seat values retyped to a
nonexistent agent shipped green under the key-anchored guard the comment
claims exists.

**true/dispatch.mjs** states the corrected anchor ("anchors on the literal
string VALUE... not on an `agentType:` key... a value anchor is the only
anchor that actually covers this call site") against the byte-identical
`SEATS` table and `dispatch` function.

**Which lens should have caught it and why it does not:** this is the
sharpest instance of the class because the comment makes a claim about a
*different file's* mechanism (`check_workflow_agent_types`, which lives in
`scripts/validate_plugin.py`, not in this file) — exactly the shape #70's
writeup says `feasibility` misses: "claims *about* the artifact, living
somewhere else," not claims in the artifact under review. A lens reviewing
only `dispatch.mjs` in isolation has no way to check the claim without also
reading the validator, and none of the five shipped prompts (`spec`,
`testability`, `feasibility`, `quality`, `correctness`) directs a seat to
cross-reference a named checker function's actual anchor logic in a sibling
file.

**What a correct detection must name to count as detected:** the specific
mismatch — "the comment says the checker anchors on the `agentType:` key;
`dispatch()` never emits that key literal, only the shorthand property, so
a key-anchored checker would find nothing here; the guard must anchor on
the value instead" — not a generic "verify this claim against the
checker," which is equally true of `true/dispatch.mjs` and would
false-positive there.

**Functional-identity verification:** `SEATS` and `dispatch` are
byte-identical between `drifted/dispatch.mjs` and `true/dispatch.mjs`; only
the leading comment block differs. Diffed directly:

```
$ diff tests/fixtures/drift/agenttype-anchor/drifted/dispatch.mjs tests/fixtures/drift/agenttype-anchor/true/dispatch.mjs
1,3c1,3
< // A computed agentType is invisible...
---
> // check_workflow_agent_types anchors on the literal string VALUE...
```
No diff below the comment block; both export the same `dispatch(seat,
task)` returning the same shape for the same inputs.

## Measured 2026-08-16

The prediction above said this is the sharpest instance of the class because
the comment makes a claim about a *different file's* mechanism
(`check_workflow_agent_types` in `scripts/validate_plugin.py`), that #70's own
writeup names this exact shape as what `feasibility` misses, and that none of
the five shipped prompts directs a seat to cross-reference a named checker's
logic in a sibling file.

What actually happened (per `tests/fixtures/drift/MEASUREMENT.md`, drifted
column): `feasibility` **85**, `quality` **85**, `correctness` **72**,
`testability` **—**, `spec` **—**. `feasibility`'s 85 and `quality`'s 85 are
each lens's highest score across all six fixtures in this run.

The prediction was **wrong**, and sharply so on the specific point it staked
out: it predicted `feasibility` would miss claims about a different file's
mechanism, and `feasibility` scored its single best result of the run on
exactly that shape.

What still holds: nothing about the mechanism claim survives — the panel did
not need to read `scripts/validate_plugin.py` to catch this, contrary to the
prediction's reasoning that a seat reviewing only `dispatch.mjs` "has no way
to check the claim without also reading the validator." The lens evidently
found the internal contradiction (a shorthand `agentType,` property vs. a
claimed `agentType:` key literal) directly in this file's own code, without
needing the sibling file at all — so the premise that cross-file
verification was required is itself the part that does not hold.
