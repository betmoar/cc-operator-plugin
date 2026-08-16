# stdout-copies — modeled on #70 instance 2 (uniform-parity blind spot)

**Claim, verbatim across three files (`drifted/ops-verdict.sh`,
`drifted/ops-adopt.sh`, `drifted/CHANGELOG-fragment.md`):** "a leaked
lock-holder process would otherwise write its retry warnings into a closed
stdout and be lost silently."

**The code that falsifies it:** every copy's actual `warn_lock_ceiling`
writes with `echo ... >&2` — stderr, not stdout — and does so
unconditionally, not "otherwise" (conditionally). The sentence describes a
failure mode (writing into a closed stdout) that the code, in all three
copies, never does: it always targets fd 2. This is issue #70's own real
instance: a reviewer caught the wrong sentence in `CHANGELOG.md`, it was
fixed there, and the identical sentence was left standing in two shipped
scripts — "one copy of three updated."

**`true/`** carries the corrected sentence in all three files, in sync:
"Every lock warning is written to `&2` unconditionally... so a leaked
lock-holder process still gets its retry warning delivered." Function
bodies are byte-identical to `drifted/` in both `.sh` files; only the
comment block differs.

**Which lens should have caught it and why it does not:** this is exactly
the case `docs/spec` (via issue #21) calls out for parity checks —
`check_lock_parity`-style byte comparison between the two `.sh` copies
**passes** here, because both copies are equally wrong. Parity holds
perfectly under uniform drift; it cannot detect this. Among the five
review lenses, none reads three files together looking for a shared
sentence and checks it once against the code: `feasibility` checks claims
against the file it is reviewing, one file at a time, so a drift landing
identically in sibling copies produces the same (non-)finding three times
over rather than a single caught divergence. `quality` and `correctness`
are also per-file. No lens's stated question is "does this sentence, which
also appears in N other files, actually describe what the code in each of
them does."

**What a correct detection must name to count as detected:** the specific
mechanism — "the comment says stdout, the code writes to `&2`" — in EACH
copy it appears in, or better, a single finding that names all three
occurrences of the shared sentence and the one dataflow fact that falsifies
it (echo target is fd 2, not fd 1, and the write is unconditional, not
contingent on stdout state). A detection that only flags one of the three
copies has reproduced the exact "one copy of three updated" failure this
fixture models.

**Functional-identity verification:** `warn_lock_ceiling` is
character-for-character identical between `drifted/ops-verdict.sh` and
`true/ops-verdict.sh` (and likewise for the `ops-adopt.sh` pair) below the
comment block — same `echo ... >&2`, same message text. Diffed directly:

```
$ diff tests/fixtures/drift/stdout-copies/{drifted,true}/ops-verdict.sh
2,4c2,4
< # closed stdout and be lost silently.
---
> # ...conditionally...
$ diff tests/fixtures/drift/stdout-copies/{drifted,true}/ops-adopt.sh
(same shape)
```

Both variants, run directly, print the identical warning to stderr:

```
$ bash -c 'source tests/fixtures/drift/stdout-copies/drifted/ops-verdict.sh; warn_lock_ceiling' 2>&1 1>/dev/null
WARNING: lock spin ceiling reached, forcing acquisition
$ bash -c 'source tests/fixtures/drift/stdout-copies/true/ops-verdict.sh; warn_lock_ceiling' 2>&1 1>/dev/null
WARNING: lock spin ceiling reached, forcing acquisition
```

## Measured 2026-08-16

The prediction above said parity checks pass under this uniform drift and
cannot detect it, and that none of the five lenses reads three files together
looking for a shared sentence, so each would produce the same non-finding
three times over.

What actually happened (per `tests/fixtures/drift/MEASUREMENT.md`, drifted
column): `testability` **72**, `feasibility` **78**, `quality` **76**,
`correctness` **60**, `spec` **—**. Four lenses detected it.

The prediction was **wrong** about the panel's outcome — it predicted the
per-file review pattern would produce a non-finding in each copy, and instead
four lenses named the mismatch.

What still holds: the byte-parity-blindness reasoning is sound and orthogonal
to this result — a `check_lock_parity`-style diff between the two `.sh`
copies still passes under uniform drift, because that is a different
mechanism than an `op-reviewer` seat's free-text read of the claim against
the code. The measurement did not test parity-checking; it tested review
lenses, and those turned out not to need cross-file sentence-tracking to
catch this — each lens's own read of a single copy against its own code was
enough.
