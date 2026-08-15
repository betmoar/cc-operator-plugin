# Security fixture corpus — the measurement instrument for the U12 experiment

Issue #24 asks a question the review panel cannot answer about itself: which
security-relevant defects are systematically outside its five lenses. The honest
way to answer it is to run the panel over defects whose answer is already known,
and count. This directory is that set of defects.

**Nothing here is wired into the plugin.** These are inert fixtures under
`tests/fixtures/`; no `scripts/` file reads them, no hook sources them, and the
validator's globs (`scripts/*.sh`, `workflows/*.js`, `agents/*.md`) do not reach
them. They exist to be reviewed, not to run in production.

## The discriminating property

Every fixture is **functionally correct and passes its own tests**. That is the
whole design constraint, and it is what makes the corpus a measurement rather
than a demo. Anything that fails its own tests is already caught by machinery
this repo has had since 0.1 — a fixture like that would measure the test runner,
not the panel.

So each fixture ships as a 2×2:

|            | `vuln.sh`      | `fixed.sh`     |
| ---------- | -------------- | -------------- |
| functional | **ok**         | **ok**         |
| exploit    | **fires**      | **blocked**    |

The left column is what a review seat is shown. The row above it is why no
existing gate objects. `tests/test-scripts.sh` asserts all four cells for every
fixture — a fixture whose exploit does not fire, or whose fixed variant breaks
the feature, is a broken instrument and fails the build.

The `fixed.sh` column is not decoration either. It is the false-positive
control: a "security lens" that flags both columns equally has not detected
anything, it has pattern-matched on the topic. Any detection-rate claim made
from this corpus must report both columns or it is not a rate.

## Why these five shapes

Drawn from this codebase's actual surface, per #24's instruction to avoid
generic OWASP examples. ~4,000 lines of shell that parse untrusted input, build
filenames out of parsed values, `rm -f` inside a scaffolded directory, and run
as PreToolUse/Stop/SessionStart hooks.

| fixture | class | modeled on |
| --- | --- | --- |
| `frag-traversal` | parsed field becomes a path component | the 0.4.0 sentinel-body traversal (`session_id: ../../PWNED` reaching a fragment filename), found by hand-audit before the panel existed |
| `sweep-rm` | parsed field reaches an `rm -rf` argument | the compressor tempdir sweep that `ops-sessionstart-hook.sh` re-derives in shell |
| `guard-two-of-three` | guard applied at 2 of 3 call sites | the F30 shape — this repo's most-repeated bug, and a security bug whenever the guard is a traversal guard |
| `ext-source` | provenance of a sourced dependency | `.operator/` files are, in this repo's own words, "ordinary files a merge, checkout, or patch can supply" |
| `secret-in-error` | secret reachable in an error message | evidence cells get pasted verbatim into `VERDICTS.md` and CI logs |

`guard-two-of-three` is the one to watch. Its defect is not a missing guard —
the guard exists, is correct, and is tested. The defect is a call site. That is
the shape the `correctness` lens's "missing validation" wording is least likely
to reach, because validation is not missing anywhere a reader is looking.

## Layout

```
<fixture>/
  vuln.sh    the defective version   — functionally correct
  fixed.sh   the corrected version   — same CLI, same behaviour, guard added
  probe.sh   <script> → prints FUNCTIONAL: ok|fail and EXPLOIT: fired|blocked
  NOTES.md   the defect line, why each existing lens misses it, and what a
             detection must SAY to count as one
```

`probe.sh` does all its work inside a `mktemp -d` sandbox and every traversal
target resolves back inside it. Run one by hand:

```
bash tests/fixtures/security/frag-traversal/probe.sh \
     tests/fixtures/security/frag-traversal/vuln.sh
```

Fixtures are invoked as `bash <path>`, never executed directly, so no fixture
needs a mode bit and none is portable-idiom-scanned.

## What this corpus does NOT establish

It is step 1 of #24's three steps. It gives the experiment something to measure;
it measures nothing on its own. Until the panel has actually been run over it
and the per-lens detection recorded, no claim about the panel's security
coverage — in either direction — is supported by this directory existing.

It is also five defects chosen by one person from one repo's shape. A class
absent here is not a class the panel catches; it is a class nobody wrote a
fixture for.
