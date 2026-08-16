# errno-claim — modeled on #70 instance 1

**Claim (drifted/check.mjs, lines 1-3):** "statSync throws ENOENT when the
path is missing, which we treat as 'no sentinel yet'."

**The code that falsifies it:** the `catch (e)` block has no check on `e` at
all — it treats *any* thrown error (`EACCES`, a symlink loop, a permission
error) as "no sentinel", not specifically `ENOENT`. The comment names a
narrower precondition than the code implements.

**true/check.mjs** carries the corrected claim ("can throw for many reasons
... we treat ANY throw ... as 'no sentinel'") describing the exact same
`catch` block. The two files are byte-identical apart from the header
comment block (lines 1-4) — same function bodies, same control flow, same
exported symbol, same runtime behaviour for every input.

**Which lens should have caught it and why it does not:**
- `feasibility` is the nearest miss — its brief is "load-bearing claims in
  the artifact against the actual code." Measured against the security
  corpus (`tests/fixtures/security/MEASUREMENT.md`) it reads that as claims
  about *this* file's own code, and this claim is literally about this
  file's own code — but issue #70's real instance (Copilot, PR #67) shows
  the panel's shipped feasibility prompt has never reported this shape: a
  comment naming a narrower error condition than a bare `catch` accepts. It
  is a single-file drift, the easiest case, and still missed in the
  measured instance.
- `correctness` ("logic errors, unhandled cases... do not judge style or
  spec fit") could plausibly flag "catches too broadly" as a logic issue,
  but the real PR #67 instance was found by Copilot, not by the panel's
  `correctness` seat.
- `spec`/`testability`/`quality` do not ask this question at all — no task
  text mentions ENOENT, there is no separate acceptance criterion for it,
  and "catches broadly" is not a craft/convention issue.

**What a correct detection must name to count as detected:** the specific
disagreement — "the comment says ENOENT, the catch has no error-code check
and accepts any throw" — not a generic "add error handling" or "consider
narrowing the catch," which would be equally true of `true/check.mjs` (there
the catch is *deliberately* broad, matching its comment) and would therefore
be a false positive on the control column.

**Functional-identity verification:** the two `check.mjs` files differ only
in the comment lines (1-4); `ownerOrNull` and `readOwnerLine` are character-
for-character identical below the comment block. Diffed directly:

```
diff tests/fixtures/drift/errno-claim/{drifted,true}/check.mjs
```

confirms the only hunks touch comment lines, never code lines.

## Measured 2026-08-16

The prediction above said `feasibility` is the nearest miss but has never
reported this shape, `correctness` could plausibly flag it but the real PR
found it via Copilot not the panel, and `spec`/`testability`/`quality` do not
ask this question at all.

What actually happened (per `tests/fixtures/drift/MEASUREMENT.md`, drifted
column): `feasibility` **80**, `quality` **82**, `correctness` **80**,
`testability` **—**, `spec` **—**. Three of the five lenses detected it, named
the specific claim/code mismatch.

The prediction was **wrong**. It predicted a miss for `feasibility` and named
`correctness` only as "plausible"; both detected, along with `quality`, which
the prediction did not mention as a candidate at all.

What still holds: the reasoning that `spec`/`testability` have no mechanism to
ask this question is confirmed — both scored `—`. The observation that a
narrower-than-code error comment is an easy, single-file case is also sound;
it turned out to be easy for the panel to catch, not easy to miss.
