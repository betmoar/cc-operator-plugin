---
name: surfacing-unknowns
description: >
  Use at the start of any non-trivial coding, design, refactor, or build
  task — especially when the request is ambiguous, long-horizon, touches an
  unfamiliar codebase or domain, or when a previous attempt came back wrong.
  Do NOT use for small fully-specified edits, single-file mechanical changes,
  or when the user says "just do it". Use also when a blindspot pass,
  brainstorm, interview, reference port, implementation plan, implementation
  notes, pitch doc, or pre-merge quiz is needed.
when_to_use: >
  Trigger phrases: "help me plan", "I'm not sure how", "blindspot pass",
  "unknown unknowns", "brainstorm", "prototype", "interview me", "port
  semantics", "implementation plan", "implementation notes", "pitch doc",
  "comprehension quiz", "verify before done", "build a feature", "add X to
  this codebase", "this came back wrong", "I've never touched", "help me get
  started", "port the semantics", "port X to", "has the exact behavior I
  want", or any large/vague handoff.
user-invocable: true
allowed-tools: Read, Grep, Glob, Task, Bash, Write, WebSearch, WebFetch
---

# Surfacing Unknowns

Your job is not to rush to code. It is to close the gap between the
**map** (the prompt, skills, CLAUDE.md, context) and the **territory**
(the actual codebase, constraints, real world). That gap is the set of
**unknowns**; output quality is bottlenecked by how well they surface.

Core rule: a strong model's failures are quiet and compounding. It takes the
map at face value and executes thoroughly, which is exactly what makes an
unstated assumption expensive. Spend effort up front to make it cheap.

## Stop conditions — when NOT to run the loop
Skip discovery and just execute when ANY of these hold:
- The change is small and fully specified (single file, mechanical).
- A 30-second quadrant pre-scan finds only known knowns.
- The user explicitly declines discovery ("just do it", "skip the questions").
- The same task already went through discovery this session.
Not every technique is used every time. Discovery that doesn't change a
decision is waste.

## The four quadrants (classify every task)
- **Known knowns** — stated in the prompt. Already actionable.
- **Known unknowns** — the user knows they haven't decided (e.g. Redis vs.
  in-memory cache). Ask or plan for these.
- **Unknown knowns** — obvious-once-seen, never written down (e.g. "8px border
  radius" — they'll reject 4px on sight). Surface with prototypes/brainstorms.
- **Unknown unknowns** — not considered at all (e.g. a rate limiter already
  exists in the codebase). Surface with a blindspot pass.

Only quadrant 1 makes it into prompts by default. Quadrants 2–4 are where
rework comes from. Aim to have few unknowns but ALWAYS expect them.

## Calibrate specificity
Too specific → the model rigidly follows a flawed instruction. Too vague →
industry-default decisions that don't fit this task. When you don't account
for unknowns you fail both ways. Ask the user for their starting context:
where they are in their thinking and what experience they have with the problem.

## The unknowns-discovery loop
1. **Orient.** Restate the task. Ask the user for their starting point/expertise.
2. **Classify** the task across the four quadrants.
3. **Select lifecycle stage** — pre-, during-, or post-implementation.
4. **Route to a technique** using the `## Technique dispatch` section below.
5. **Dispatch heavy exploration to a subagent.** For blindspot passes and
   reference reads, delegate to a forked Explore subagent via the Task tool to
   keep the main thread clean. Subagents can't spawn their own subagents, so
   keep delegation one level deep.
6. **Observe before re-routing.** After every technique's artifact, write a
   three-line trace IN THE RESPONSE (literal labeled lines, visible to the
   user) before doing anything else:
   - **Thought:** what unknown was I targeting?
   - **Action:** which technique ran, on what scope?
   - **Observation:** what did the artifact actually reveal? Which quadrant
     did each finding move to (unknown → known)?
   The Observation decides the next move: more unknowns in a quadrant →
   route again; framing invalidated → reframe check (step 7); quadrants
   clear → proceed to plan/build. Never chain two techniques without an
   Observation between them.
7. **Reframe check.** If a surfaced unknown invalidates the task's framing
   (the problem should be solved a different way entirely), STOP and
   propose the reframe to the user before continuing. Do not optimize a
   plan for the wrong problem.

### Example trace
Task: add an auth-provider to the service.
- **Thought:** unknown unknowns around request throttling before I add login.
- **Action:** blindspot pass over `src/middleware/`.
- **Observation:** artifact surfaced an existing token-bucket limiter at
  `src/middleware/rate_limit.py:42` — moves "need new throttling" from
  unknown unknown to known known. Next move: route to **reference-port**
  against that file, not write new throttling code.

## Technique dispatch
Before responding to a matched request, Read the technique's reference file
and produce its **Output contract exactly**: same sections, same counts,
same ordering rules. If the contract says an artifact is a file, WRITE the
file (Write tool) in this same response — describing it is not producing it.
If the contract says four directions, produce four, not three. Matching a
technique and not reading its file — or reading it and not delivering its
contract — is a routing failure.

Dispatch sequence, in order, before any other tool call:
1. Name the matching technique out loud in one line ("Technique: blindspot pass").
2. Read its `references/<name>.md`.
3. Deliver its Output contract in this same response (asking the reference's
   own gating question first counts as delivering — e.g. the interview's Q1
   or the pitch doc's audience question).
4. After the artifact — and BEFORE any further work in the same response
   (e.g. "do X first, then implement") — insert this block verbatim, filled in:

   Thought: <the unknown I targeted>
   Action: <technique> on <scope>
   Observation: <what the artifact revealed; which findings moved unknown → known>

   The Observation line decides what follows it. A response that goes
   artifact → implementation with no trace block between them is
   non-compliant even if the routing was right.

When several techniques could match, pick by the user's lifecycle stage,
not by which unknowns you can see:
- Requirements still fuzzy ("haven't fully thought it through") → **interview**,
  and ask Q1 NOW — offering to interview is not interviewing.
- User says they're ready and wants a reviewable plan ("plan it out",
  "for my review") → **implementation plan**. Do not restart discovery the
  user has already closed.
- User says implement/build now → **implementation notes**: create the notes
  file first, then build; surface blockers inside the notes file's
  Discoveries section, not instead of it.
- Unfamiliar territory is a modifier, not a router: it adds a blindspot pass
  BEFORE the stage-matched technique, never replaces it.
- About to claim done/fixed/passing → **Self-verification audit** (mandatory
  before the comprehension quiz; the quiz checks the human, this checks the
  model).

Pre-implementation:
- **Blindspot pass** (→ unknown unknowns) — When: working in an unfamiliar part
  of the codebase, fearing landmines; cues: 'never touched', 'unfamiliar',
  'help me get started' in an existing codebase area. Read
  `references/blindspot-pass.md` and follow its Output contract before responding.
- **Brainstorm & multi-direction prototype** (→ unknown knowns) — When: many
  unknown knowns; taste- or visually-driven work; scope undefined. Read
  `references/brainstorm-prototype.md` and follow its Output contract before responding.
- **The interview** (→ known & unknown unknowns) — When: ambiguity remains and
  some answers would change the architecture. Read `references/interview.md` and
  follow its Output contract before responding.
- **Reference (source-code-first)** (→ unknown knowns) — When: a working
  implementation of the desired behavior exists elsewhere, even in another
  language. Read `references/reference-port.md` and follow its Output contract before responding.
- **Decision-first implementation plan** — When: direction is clear and you're
  ready to build. Read `references/implementation-plan.md` and follow its Output
  contract before responding.

During implementation:
- **implementation-notes.md with Deviations** — When: actively building; best in
  a new session with the spec + prototype passed in; user says they want to learn
  from surprises, capture learnings, or expects a long build. Read
  `references/implementation-notes.md` and follow its Output contract before responding.
  First action on ANY implement/build request with learning intent: CREATE `docs/notes/<feature>-implementation-notes.md` (empty Confirmations/Discoveries/Deviations headings) BEFORE asking any questions — open questions go under Discoveries. A blocking question does not defer the file: create the notes file with the question logged under Discoveries, then ask.

Post-implementation:
- **Pitch / explainer doc** — When: you need understanding or approvals from
  other people. Read `references/pitch-doc.md` and follow its Output contract before responding.
- **Pre-merge comprehension quiz** — When: about to merge and you must confirm
  you understand the change. Read `references/quiz.md` and follow its Output
  contract before responding. The walkthrough alone is not the contract — it
  ends with the comprehension quiz.
- **Self-verification audit** (→ model-side verification) — When: about to claim
  work is complete, fixed, or passing. Read `references/self-verification.md` and
  follow its Output contract before responding.

## Guardrails
- Prefer cheap discovery now over expensive rework later. Every explainer,
  brainstorm, interview, prototype, and reference is a cheap way to find what
  you didn't know.
- Discovery serves the deliverable: when the user asked for an artifact (plan,
  options, port), produce it in the same response as the discovery — questions
  gate refinement, not delivery.
- On edge cases during a build: pick the conservative option, log it, keep going.
- Produce artifacts as self-contained HTML when they benefit from layout, color,
  diagrams, interactivity, or side-by-side comparison; use markdown for short notes.
- Build-framed requests ("show me", "port", "package") get the same pre-scan as plan-framed ones.
- State a consequential assumption BEFORE acting on it, not in the wrap-up.
- Before any build, check `docs/notes/` for prior implementation notes on this feature; deviations there are constraints now.

## Honesty
This skill encodes a public working methodology. It does not replicate
any model's internals; never claim otherwise.

## Additional resources
- Full technique recipes (When / Prompt pattern / Output contract) live in
  `references/*.md`; the `## Technique dispatch` section selects among them.
