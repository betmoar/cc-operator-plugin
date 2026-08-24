# Charter citation tags — the in-tree resolution index

Every `[DOC:spec-*]` tag in `templates/OPERATOR.md` resolves HERE, in every
clone. This file is **not** the original design spec: that document
(`chief-operator-spec.md`, D1–D6) was deliberately never committed — it quoted
a prior project's evidence base that 0.3.0 removed from the tree — and no copy
survives in the maintainer's local tree either (verified absent 2026-08-21).
What follows is the honest register of what each tag *anchors as shipped*: the
rule's meaning as the mechanisms implement it, written from the code and the
charter's own usage, not recovered spec prose. Where the original rationale
matters and is lost, the entry says so.

`check_charter` enforces that every `[DOC:spec-<key>]` in the charter has a
`### spec-<key>` heading here — a new tag without an entry fails the build, so
this index cannot silently fall behind the charter.

`[D:*]` tags (`CHART-*`, `GATES-*`, `roadmap-*`) are decision references from
the same lost planning documents; they name the charter's own sections and are
self-describing at their use sites. Only `DOC:` tags carry an external-document
claim, so only they are indexed.

---

### spec-D1.2

Done-criteria are *produced by the Discovery discipline*, not invented at
BAR-writing time: interview / blindspot / plan-workflow output feeds the BAR
block's criteria. Implemented as the ENGAGEMENT CONTRACT's closing clause.

### spec-D1.5

The measurement rules — the dominant observed failure class in the pilots was
trusting an unverified meter. Three shipped rules: destination check (echo the
resolved path before writing to a derived location), meter check (state what
would invalidate a verification result, then check it), and the caps' framing.
The pilot evidence behind "dominant observed failure class" is in the removed
evidence bundle (git history ≤ v0.2.0).

### spec-D1.6

When a reviewer verdict contradicts the ledger, audit the *dispatch packet*
before the artifact — the packet is the cheaper and more common defect site.
Implemented as the ORCHESTRATED MODE rule after the four-status protocol.

### spec-D2

The operator role and the two modes: SOLO (direct work, three bindings) vs
ORCHESTRATED (begins at first dispatch; context diet — no worker transcripts
or raw diffs, `--stat` and reports only; plumbing carve-out for direct
infrastructure action, logged). The mode boundary and the diet are the spec's
central design decision; the shipped mechanism is the charter prose plus the
30-line worker-report cap.

### spec-D4

The evidence gate. A BAR block is a *structural* requirement (multi-file /
multi-session / named done-state — no ease exemption), and every done-claim
routes through the single-writer ledger: `ops-task.sh` opens the sentinel,
`ops-verdict.sh` writes the row and clears it, `ops-claims.sh` checks CHANGED
against the diff, `--defer` is the honest exit for a blocked task, and the
source-state stamp is provenance, never proof. The mechanisms live in
`.operator/bin/`; the Stop hook enforces the sentinel side.

### spec-D5

Review is gated to consequence: DONE on merge/publish/depended-on work routes
to the review workflow (narrow lenses, then the adversarial seat; REFUTED is
unoutvotable); probes and drafts skip review. Implemented in the four-status
protocol and `workflows/review.js`.

### spec-D6

The two handoffs. Worker→operator: status line + ACCOMPLISHED (evidence
inline) + UNVERIFIED (why + what verifies it), with UNVERIFIED transferred to
the ledger as pending, never silently accepted. Operator→human: the six-section
handoff (`/cc-operator:handoff`).

### spec-O8

Precedence: the charter outranks skills, and no skill's content merges into
it — a skill that would amend the charter is a conflict to log, not adopt.
Implemented as the PRECEDENCE section; the numbered O-decisions (O1–O8) are in
the lost spec, and O8 is the only one the charter cites.

### spec-compress

The compressor's spill contract (`scripts/ops-compress.mjs`): in an operated
project, elided output is spilled to a file and the marker names the path, so
evidence citing compressed output MUST cite the spill path — the middle of the
stream is gone from the transcript. Outside one (no `.operator/`), elide still
fires but is marked "not spilled" — there is no citable artifact. The
compressor's own header documents the I1–I5 invariants.

### spec-concurrent

Concurrent-session ownership — the one spec that *was* written up separately
(`concurrent-sessions.md`, also never committed, also absent locally). The
shipped design it specified: sentinel ownership keyed on the session id
(0.9.0: in the filename, `pending/<sid>__<task>`), Stop blocks on mine +
unowned and reports foreign, unowned fails closed, `ops-adopt.sh` is the
recovery path after an id change, and the SessionStart hook injects the id
because `CLAUDE_SESSION_ID` is not in the Bash tool env. What a green suite
does not prove was that document's honest register; its surviving heirs are
the _"sentinel ownership"_ test cases and `docs/LANDMINES.md`.

### spec-unk

The unknowns discipline: surface unknowns *before* building; route by stage
(fuzzy → interview, unfamiliar code → blindspot, ready → plan workflow,
about-to-claim-done → adversarial seat); a reframe-invalidating unknown is a
STOP. The register of record is GitHub issues (`label:unknown`) —
`docs/UNKNOWNS.md` holds the convention.

### spec-wf

The workflow layer: review, brainstorm, plan, crawl, dispatch, debate are
the orchestration primitives; `/cc-operator:tiers` resolves tier→model bindings
(the operator's job — workflows carry harness-alias defaults only, #76
step 2). The workflows themselves are `workflows/*.js`; their guard
architecture is in `docs/PLAYBOOK.md` ("Adding a workflow").
