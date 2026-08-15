# sweep-rm — parsed field reaches an `rm -rf` argument

**Defect:** `vuln.sh` line 30-33 — `target="$ROOT/$sid"` then `rm -rf "$target"`,
where `$sid` came out of a file the script does not control.

**Why the input is untrusted.** Same class as `frag-traversal`: the session file
is an ordinary file on disk. The real analogue is the ephemeral-spill sweep that
`ops-sessionstart-hook.sh` re-derives in shell from the compressor's tempdir
convention — it runs at every session start, unattended.

**Impact.** Recursive deletion outside the intended root. Strictly worse than
the traversal-write class: a write leaves a file you can find, a delete leaves
nothing to find.

## The specific trap in this one

The vulnerable line is **correctly quoted**. `rm -rf "$target"` has no
word-splitting bug, no glob bug, and a reviewer scanning for unquoted expansions
— the shell-security habit — passes over it. Its own comment says the removal is
"scoped under `$ROOT` by construction of the path", which is the plausible and
wrong reading: `"$ROOT/../victim"` is under `$ROOT` lexically and outside it
after resolution.

## What each existing lens would say

| lens | verdict on this file |
| --- | --- |
| `spec` | a sweeper that sweeps; nothing unasked |
| `testability` | criterion exists and passes — own dir gone, neighbour intact |
| `feasibility` | the claim "quoted, so no word-splitting" is TRUE. The false claim is the *scoping* one, and checking it needs a path-resolution model, not a read of the line |
| `quality` | quoted expansions, guarded inputs, an explicit `-d` test before removal |
| `correctness` | "missing validation" — but the empty-id case, the missing-root case, and the not-a-directory case are all handled. The nearest true statement a correctness reader makes is that nothing is missing |

**A detection must say:** that `$sid` reaches `rm -rf` without a bare-name check,
and — the discriminating half — that quoting does not scope it. A finding that
only says "validate the session id" scores the same against `fixed.sh`.

## Measured — this prediction did not hold

The table above is what I expected the panel to say. It was then run (`../MEASUREMENT.md`, 2026-08-15) and **both judgment-tier lenses detected this defect at the mechanism level**. The prediction was wrong for feasibility and quality; it held for the cheap tier. The table is kept as written rather than rewritten to match the result — a hypothesis edited after its own experiment is not a hypothesis.
