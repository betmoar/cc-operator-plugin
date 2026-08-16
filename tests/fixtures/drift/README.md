# Drift fixture corpus — the measurement instrument for #70's sixth-lens question

Issue #70 measured a defect class the review panel misses: a **claim** — a
sentence in a comment, docstring, changelog or `meta.description` asserting
something about behaviour — that no longer matches the code, or that
matches in one copy and not in sibling copies carrying it verbatim. Twenty
instances measured across four PRs, none caught by the five shipped lenses
as they ship in `workflows/review.js`. This directory is the fixture set
`#70` itself proposes for deciding whether a sixth lens earns its cost,
following the same fixture-first discipline #24 required of the security
corpus (build the fixture, measure the panel against it, decide only after).

**Nothing here is wired into the plugin.** These are inert fixtures under
`tests/fixtures/`; no `scripts/`, `hooks/`, `workflows/` or `agents/` file
references any path here, and none of these files carries an execute bit.

## Why the shape differs from the security corpus

The security corpus's unit of defect is a single file: `vuln.sh` vs
`fixed.sh`, same CLI, one added guard. A drift defect is structurally
different — it is a **disagreement between two artifacts**, not a missing
check in one. Sometimes that's a comment above code it misdescribes
(`errno-claim`, `lock-ceiling`); sometimes it's the same sentence copied
into several files, correct in the fix and stale in the rest
(`stdout-copies`); sometimes it's a claim in one file about a *different*
file's mechanism (`agenttype-anchor`, `doc-regex-table`); sometimes it's
metadata describing a table in the same file (`tier-split-meta`). So each
fixture here is a small **set** of files, not one file, and the discipline
moves from "does the exploit fire" to "does the claim in this set hold
against the code in this set."

## The discriminating property

Every fixture is a **2×2**, same idea as the security corpus, restated for
prose instead of exploits:

|            | `drifted/`         | `true/`             |
| ---------- | ------------------- | -------------------- |
| functional | **identical to true/** | **identical to drifted/** |
| claim      | **false**            | **holds**             |

The code paths in `drifted/` and `true/` are identical once whole-line
comments are removed — only the prose differs. Stated that way rather than
"byte-identical", which is what an earlier draft said and is false of
`tier-split-meta`, whose claim lives in a `meta.description` **string**: the
two columns differ in a string literal, and that literal is exactly what the
fixture models. The property that matters is behavioural, not textual — no
input distinguishes the two columns. That is the whole design constraint. If
`drifted/` and
`true/` behaved differently, this would be a functional-bug corpus, and
this repo already has machinery (its own tests, the security corpus) for
that. What this corpus isolates is a lens's ability to notice that a
*sentence*, not the code, changed meaning — or failed to change when the
code did.

Each `NOTES.md` states how functional identity was verified for its own
fixture: a `diff` of the code region showing only comment/prose lines
differ, and for `lock-ceiling`, running both variants and showing identical
output.

**That claim is pinned by the suite, not only asserted here.** `#70 drifted/
and true/ differ ONLY in prose` in `tests/test-scripts.sh` strips whole-line
comments from both columns of every fixture and compares what is left; a
fixture whose columns diverge in code fails the build, naming the file. It
carries two controls, because a comparison that cannot see a difference
reports every fixture identical — which is the same value that means clean:
one proves a real code difference IS detected, the other proves a
comment-only difference is NOT.

Three members are exempt and named individually in the case rather than
matched by a pattern: every `.md` member (`doc-regex-table/tiers.md`,
`stdout-copies/CHANGELOG-fragment.md`), where the prose *is* the content,
and `tier-split-meta/review.mjs`, whose claim lives in a
`meta.description` **string** — that is the shape it models, metadata
describing its own table, so its two columns necessarily differ outside
comments. Naming them keeps the exemption auditable; a pattern would grow
silently.

## The false-positive control

`true/` is not decoration. A "drift lens" that flags both columns equally —
that reports `true/lock.sh`'s correct "3s ceiling" comment as suspicious,
or `true/dispatch.mjs`'s corrected anchor claim as still wrong — has not
detected a drift, it has pattern-matched on the topic (comments near
numbers, comments near guard names). Every `NOTES.md` states explicitly
what a *generic* finding ("verify this claim," "add error handling") would
be: equally true of `true/`, and therefore a false positive if raised
there. Any detection-rate claim made from this corpus must report both
columns or it is not a rate — this repo's own `MEASUREMENT.md` already
recorded that a stale control tree produces a confident wrong answer; the
same discipline applies here on the code side.

## The six fixtures

Each traces to a real instance measured in issue #70 (not a generic or
textbook example, per the issue's own instruction).

| fixture | class | #70 instance |
| --- | --- | --- |
| `errno-claim` | comment names a specific exception the code does not actually require | #1 — `statSync` claimed to throw ENOENT; the `catch` accepts any throw |
| `lock-ceiling` | comment states a numeric bound the constant contradicts | #4 — "2s ceiling" comment vs `LOCK_MAX_SPINS=30 × 0.1s = 3s` |
| `stdout-copies` | one sentence duplicated verbatim in 3 files, correct in the fix, stale in 2 — the uniform-parity blind spot | #2 — "closed stdout" claim; the real fix updated `CHANGELOG.md` and left two shipped scripts unfixed |
| `tier-split-meta` | `meta.description` describes a tier/count split the table contradicts | #3 — "two at judgment" vs `correctness` also being judgment-tier (three) |
| `agenttype-anchor` | comment asserts a checker anchors on X (a key) when it anchors on Y (a value) | #7 — `check_workflow_agent_types` claimed to anchor on `agentType:`, actually anchors on the string value |
| `doc-regex-table` | doc table row asserting a behaviour (a specific regex) the code stopped having | #11/#12 — `tiers.md` quotes the deleted `^glm-\|/\|^claude-` regex verbatim as "the validation" after 0.8.3 removed it |

`stdout-copies` and `doc-regex-table` are the ones to watch. `stdout-copies`
is the shape `check_lock_parity`-style byte comparison **cannot** catch —
parity holds perfectly when every copy is equally stale, which is #21's own
lesson replayed in prose. `doc-regex-table` (and `agenttype-anchor`) are the
"claims about the artifact, living somewhere else" shape #70's own writeup
identifies as the reason `feasibility` — the nearest-miss lens — still
missed 12 of 14 instances in the measured PR #71 round 2: its brief reaches
claims in the file under review, not claims elsewhere in the tree about a
file that did not change in the diff.

## Layout

```
<fixture>/
  drifted/   the variant whose claim is FALSE, functionally identical to true/
  true/      the variant whose claim HOLDS, functionally identical to drifted/
  NOTES.md   the claim, the code that falsifies it, which lens should have
             caught it and why it does not, and what a correct detection
             must NAME to count as one
```

Fixtures are read as file sets, not executed — `lock-ceiling`'s `lock.sh`
is the one exception with runnable code (`source`d in `NOTES.md` to show
identical behaviour), and it carries no execute bit either. No fixture
needs a mode bit and none is portable-idiom-scanned.

## What this corpus does NOT establish

Same caveat as the security corpus, restated: this is step 1 only. It gives
a future drift-lens experiment something to measure; it measures nothing on
its own. Until a panel — five lenses, or five plus a proposed sixth — is
actually run over these six fixtures (both columns) and the per-lens
detection recorded, no claim about drift coverage, in either direction, is
supported by this directory existing.

It is also six defects chosen by one person from four PRs in one repo's
history. #70 itself notes the base rate on ordinary (non
documentation-heavy) changes is unknown, and a class absent from this
corpus is not a class a future lens catches — it is a class nobody wrote a
fixture for.
