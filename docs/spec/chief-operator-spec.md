# Chief-Operator Prompt — Design Specification and Phased Implementation Plan

**Authored:** 2026-07-06, Fable 5, against `cc-harness-plugin.zip` (branch `chore/v0.2-work-order`, main at `0e25606`).
**Implementer:** Opus 4.8 or the human.
**Deliverable of this spec:** not a prompt — the decisions, boundaries, and mechanisms the prompt must encode, each with rationale and confidence, plus the build plan that produces and validates it incrementally.

> **Reading note (added 0.4.0):** every path in the evidence base below is relative to the *prior*
> project this spec was derived from (`cc-harness-plugin` / `unknowns-harness`), not to this
> repository. None of them resolve here and none are meant to — they record what was read to reach
> these decisions. The spec's own conclusions are self-contained.

**Evidence base (all read in full):** `CLAUDE.md` (373-line orchestration charter v2 as installed), `evals/results/DECISIONS.md` (43 entries), `evals/results/GATES.md` (7 gates + preflight, with self-audit lines), `evals/SCORECARD.md` (v0.1 actuals + v0.2 NOT-SHIPPED verdict, $79.48 / 117 runs), `evals/results/v0.1/DELTA.md`, `evals/results/baseline/SUMMARY.md` (5 failure patterns), `docs/superpowers/plans/unknowns-harness-roadmap.md` (stop conditions), `docs/superpowers/plans/v0.2-work-order.md`, `unknowns-harness/skills/surfacing-unknowns/SKILL.md` (shipped v0.1, 201 lines, 9 references), `.claude/agents/{harness-author,harness-mechanic,harness-reviewer}.md`, `scripts/run-eval.sh` (current, with GREEN_DIR fix), `evals/results/v0.2/FORK-DECISION.md`, `.reload/model`, `.reload/session.md`, git log (53+ commits). Hook semantics verified against current Claude Code documentation (2026-07-06).

---

## 0. Corrections to the brief

You asked me to say where the framing is wrong. Four places.

### 0.1 "Two-skill Fable structure" is stale

The shipped harness is a **single skill**, `surfacing-unknowns`, with nine reference files. The F13 collapse was executed on 2026-07-05 on 6/10 cross-skill routing misses (DECISIONS.md, `2.1 | DECISION | F13 RESOLVED: collapse to single skill`), the confound was logged honestly, and DELTA.md's v0.1.1 rescore confirmed the collapse fixed S5 and cost S7 before tuning recovered it. Everything in this spec integrates with the one-skill topology. **Confidence: high** (read the shipped SKILL.md and the ledger entry).

### 0.2 The failure log exists — but it recorded a Fable operator, not an Opus one

`.reload/model` reads `claude-fable-5` with a 1M window. The prior build was orchestrated by Fable itself; Opus 4.8 appears in the record only as pinned subagents (`harness-author`, `harness-reviewer` — preflight probes returned `claude-opus-4-8[1m] READY`). Consequences, and they cut in a specific direction:

- The operator-failure record is a **floor**, not a delta measurement. Failure classes that occurred even under a Fable operator (plumbing bugs, packet defects, diet violations under pressure) will occur at Opus tier at least as often. Those are validated targets.
- The **Fable→Opus judgment delta is unobserved.** No Opus instance has run this charter as main-session operator. Every seam justified purely by "Opus will judge worse than Fable did" is a hypothesis and is marked as such below. Phase 1 of the implementation plan exists specifically to convert those hypotheses into observations.
- There *is* direct evidence of what a strong model does **unsupervised**: the headless eval sessions (sonnet-5, no charter) produced the baseline's five failure patterns, S13-r2's invented wire contract, and S14's asserted-but-unexecuted checkmarks. That is the closest observed proxy for "capable frontier operator with no guard," and it is where the fabrication/theater seams actually manifested.

**Confidence: high** on what the log shows; **the seam-delta analysis below is explicitly part-validated, part-hypothesis, labeled per seam.**

### 0.3 The rank-vs-capability conflation is mostly avoided this time — but a subtler cousin is present

The brief correctly refuses to treat Opus as weak. The residual error is **attributing the observed failures to judgment at all**. Tallying the 43 DECISIONS entries and the gate self-audits: the dominant failure class in the real run was the **measurement surface and harness plumbing** — baseline run 1 invalidated by CLAUDE.md leak and missing fixtures; the eval allowlist omitting the Skill tool and silently invalidating Phase-2 scores; the hardcoded OUTDIR that truncated `v0.1/S1.json` before the abort (a near-loss of shipped evidence); the S6 pass criterion that was unsatisfiable against its own fixture; user-level skill contamination that made S2's four iterations partly meaningless. Judgment, meanwhile, *held* under exactly the pressures where you'd expect it to crack: the operator stopped at the treadmill instead of running round 3, logged the F13 confound instead of burying it, probed streams before editing text, and amended a buggy criterion with its reasoning on the record.

So the corrected design center: **mechanize procedure and evidence (tier-independent, proven necessary), and spend prose only on the small set of judgment behaviors the log shows were load-bearing** — the ones a Fable operator exercised and an Opus operator might not. Designing primarily "for the delta" would aim the spec at the smaller observed problem. **Confidence: high** that plumbing dominated the record; **moderate** that this ordering transfers to arbitrary sessions (the build was unusually measurement-heavy; a generic session has less meter to break — but also less meter watching it).

### 0.4 "Generalize the harness" hides a discontinuity: generic sessions have no plan to gate against

The charter's strongest mechanism — phase gates with enumerated exit criteria — presupposes a plan document that enumerates them. A random session arrives with a user request, not a criteria list. The operator prompt therefore cannot inherit gates; it must **synthesize** them: for any non-trivial engagement, the operator's first structural duty is to produce the done-condition set (bar, budget, loop caps) *before* work begins, and that duty composes with — does not duplicate — the `surfacing-unknowns` skill, whose interview/implementation-plan routes are exactly the tool for producing it. This is the single largest genuine design decision in the generalization, and it was not in the brief. **Confidence: high** that the discontinuity is real; the mechanism chosen for it is Decision D4.

---

## 1. Which seams to guard (Decision D1)

Verdicts on your four candidates, then the two observed classes you didn't list. For each kept seam: the minimal guardrail, and why nothing heavier is warranted. The overriding sizing evidence for "minimal" is the v0.2 treadmill itself: DECISIONS.md 28–29 shows that *adding and consolidating rules* (the B1 round) regressed trace emission 6/8 → 4/8. Instruction mass is not free; in this harness it has been measured to have negative marginal value past a point. Every guardrail below is sized against that measurement.

### D1.1 Plausible-fabrication-that-survives-self-review — KEEP, retargeted to completion claims

- **Evidence:** Not observed in the supervised operator across 7 gates (GATES.md evidence cells are uniformly command output or reviewer verdict lines; Gate 5's honest-limitation note is the *opposite* of fabrication). Observed repeatedly in unsupervised strong-model sessions: S13-r2 "guessed wire contract for the unimplementable registry item instead of halting"; S14 "checkmarks asserted-verified with nothing executed"; baseline pattern 3 "unevidenced completion claims on build artifacts."
- **Reading:** fabrication is not a function of model tier; it is a function of **supervision structure at the moment of a completion claim**. The ledger discipline suppressed it to zero at operator level; its absence permitted it at delegate level. An Opus chief operator in a random session is, by default, in the *unsupervised* condition.
- **Minimal guardrail:** the evidence-gate mechanism of §4 — a done-claim on a tracked task requires an appended ledger row whose evidence cell is pasted command output, enforced by a Stop hook (mechanized, see §4.2), plus the already-shipped skill's self-verification route for claim formatting.
- **Why nothing heavier:** mandatory second-model review of every claim is the heavier option; the log prices it. Review loops were the identified cost sink v1→v2 (loop cap added), and the observed operator-level fabrication rate under ledger discipline was 0/7 gates. Pay for a hook and a row schema, not for a standing reviewer. **Confidence: high** on the mechanism; **moderate** that Opus-as-operator matches the observed 0-rate — Phase 1 measures it.

### D1.2 Premature convergence — DEMOTE to a composition rule; do not re-encode

- **Evidence:** Not observed at operator tier (the observed behavior was the reverse: conservative stop at the treadmill, halt-and-report per charter). Observed downstream as baseline pattern 2 (build-framed asks flip recon into build-then-mention) — which is precisely the failure the shipped `surfacing-unknowns` skill targets, with measured v0.1 results (triggers 8/8, routes 7/8, S4 silent-port → gated-port being the flagship delta).
- **Minimal guardrail:** one line in the operator charter: the operator runs with the `surfacing-unknowns` plugin installed and does not restate its methodology. That's it.
- **Why nothing heavier:** re-encoding discovery methodology in the operator prompt is the B1 accretion anti-pattern with a measured cost. The skill is the product of $79.48 of eval evidence; the operator prompt free-riding on it is the point of having built it. **Confidence: high.**

### D1.3 Verification theater — KEEP, already solved structurally; generalize the solve

- **Evidence:** the definitional trick in the charter — "A row without evidence is FAIL by definition. Workers' assertions are not evidence" — held for the whole build. Where theater appeared (S14's checkmarks), no ledger existed. Also relevant: GATES.md Gate-4 note, "final-message transcripts systematically under-show mid-run behavior; stream probes are the authoritative source for behavioral gates" — theater has a *passive* form, where an honest final message simply omits what happened mid-run.
- **Minimal guardrail:** carry the row schema and the definitional rule verbatim into the generalized ledger (§3); add one generalized line from the Gate-4 lesson: *behavioral claims about a process are evidenced from the process record (stream, log, diff), not from its final summary.*
- **Why nothing heavier:** it already worked at zero marginal cost. **Confidence: high.**

### D1.4 Scope drift on long runs — REPLACE with unbounded-iteration / missing stop conditions

- **Evidence:** scope drift proper did not occur; TodoWrite + ledgers + recovery protocol contained a 53-commit multi-day build. What *did* occur is the failure your hypothesis gestures at but misnames: the **edit treadmill** — iterating on fixes without a pre-declared bar, each round regressing neighbors (DECISIONS.md 42; roadmap §1: "two edit rounds showed a treadmill... Conservative stop per charter rather than a round 3"). The roadmap's §4 stop conditions are the distilled countermeasure, written *after* the failure was observed: pre-declared bar and budget per cycle, loop caps (2 identical review rejections; 2 scenario rewrites; 2 fix rounds regressing neighbors → permanent stop), no open-ended tuning.
- **Minimal guardrail:** Decision D4's engagement contract — bar, budget, caps declared before work — plus a single generalized cap table (one place, three caps, from the charter + roadmap, deduplicated per §3 overlap O4).
- **Why nothing heavier:** the caps are cheap, proven, and self-executing (a cap trip is a defined state transition — stop and report — not a judgment call). Heavier alternatives (mandatory human check-ins on a timer) reintroduce the "should I continue?" interrupts the charter explicitly engineered out. **Confidence: high** — this is the best-evidenced seam in the record.

### D1.5 NEW — Dirty measurement surface / verify-the-verifier (the dominant observed class)

- **Evidence:** baseline run 1 invalidated (charter leak via parent-dir walk-up, missing fixtures, Write denied confounding the jump-to-code metric); Skill tool absent from the allowlist invalidating Phase-2 routing scores; `--max-turns` caps producing empty, unscorable result fields; OUTDIR hardcoded to `v0.1` truncating shipped evidence on the v0.2 launch ("Preflight gap: output-dir versioning was not checked before launch" — the operator's own words); S6's pass criterion unsatisfiable against a fixture that deliberately ships a pre-existing notes file; user-level skill contamination unfixable at platform level (keychain-bound OAuth blocks `CLAUDE_CONFIG_DIR`). Seven distinct incidents. Nothing else in the record comes close.
- **Generalized seam:** *any verification step whose own preconditions are unverified*. In a generic session this covers: running tests against the wrong environment, trusting a green CI that didn't run the changed code, writing outputs to a path that clobbers prior results, and scoring behavior from a summary rather than the record.
- **Minimal guardrail:** two rules and one habit, all traceable to specific incidents:
  1. **Destination check** — before any command that writes to a derived/versioned path, echo the resolved destination and confirm it is not a prior result set (from the OUTDIR clobber).
  2. **Meter check** — before trusting a verification result, state in one line what would make this result invalid, and check it (from the allowlist and isolation incidents; this is the preflight principle detached from the build-specific preflight).
  3. **Record over summary** — D1.3's line covers the S6/S12 scoring lesson.
- **Why nothing heavier:** a full generalized preflight checklist for arbitrary sessions would be mostly inapplicable per session (the build's 7-step preflight is plan-specific) and would be skipped — the observed preflight gap happened *despite* a written preflight, because the checklist didn't contain that item. Principles that generate checks beat checklists that enumerate them, for an operator at Opus tier. **Confidence: high** on the incidents; **moderate** on the principle-over-checklist bet — Phase 1/4 revisits it if destination/meter incidents recur.

### D1.6 NEW — Dispatch-packet defects (orchestrated mode only)

- **Evidence:** the protocol's second-NEEDS_CONTEXT rule fired correctly on the isolation task ("packet deficient per protocol"); and the one false alarm of the build — the roadmap review "blocker" — was traced to the *operator's own review prompt* miscounting the not-doing list ("discrepancy was in the review dispatch, not the artifact").
- **Minimal guardrail:** keep the existing second-NEEDS_CONTEXT rule verbatim; add one line: *when a reviewer verdict contradicts the ledger, audit the dispatch packet before the artifact.*
- **Why nothing heavier:** one incident, self-diagnosed, zero product damage. **Confidence: high** on the rule's cheapness; **low** on its frequency mattering — it's included because it costs one line and the ledger shows the failure shape exactly once, resolved exactly this way.

### Explicit anti-scope for D1

Stochastic skill activation (S2, four probes four outcomes), question-ending trace omission (0/3 vs 5/5 artifact-endings), and the S13/S14 completion-evidence cluster are **product-skill defects on the v0.3 backlog with defined entry conditions** (roadmap §3). The operator prompt must not attempt to compensate for them in prose — that is treadmill round 3 by another name, and roadmap stop-condition 1 forbids it. **Confidence: high.**

---

## 2. Guardrail vs. trusted judgment (Decision D2)

**The boundary test (named, per your constraint):** a behavior goes in the operator prompt only if (a) a specific ledger entry, gate note, or verified platform constraint shows it failing or needing definition without the rule, **and** (b) the rule is enforceable or checkable — a self-audit question, a hook, a schema, or a cap; not an adverb. A rule that cites no incident and defines no check is deleted. The prompt carries its citations inline (short tags like `[D-2026-07-06-v0.2.V]`) so Phase 4's prune pass can audit rule-by-rule.

**Trusted unsupervised — the prompt says nothing about:**

- **Task decomposition and sequencing.** The Opus-tier subagents executed single-task packets flawlessly across ~50 dispatches; nothing in the record suggests decomposition needs scaffolding at this tier. The one decomposition-shaped rule that earns its place is the ladder's rung 3 (split on task-too-large), which is a *response to a failure signal*, not upfront structure.
- **Tool selection, file navigation, language/framework judgment, commit message quality.** Zero incidents in 53 commits.
- **Prose and artifact quality.** The judgment tier's output was the product and it shipped.
- **When to ask the user vs. decide.** The skill's question-calibration content (blast radius / reversibility) and the charter's rung-4 rule ("only plan-level contradictions reach the human") cover the two ends; the middle is judgment and the record shows it exercised well (conservative-option-and-log on edge cases).
- **Discovery methodology in its entirety.** D1.2 — the skill owns it.
- **Model routing within a dispatch**, beyond the two-line tier principle retained from the charter ("route by task nature; correctness of the product beats token savings; judgment work never below judgment tier") — which is kept because it was load-bearing and cheap, not because Opus can't infer it.
- **Parallelization judgment**, beyond the retained one-implementer rule (kept: it is a race-condition invariant, not a judgment aid).

**The context diet is retargeted, not inherited — this is the largest deliberate divergence from the charter.** The charter's diet (rules 1–5: read almost nothing, never implement) was designed for a maximally-priced 1M-window Fable orchestrating a plan where every task's text existed in a document. Two facts break its transfer: (i) even in the build, the diet was violated four logged times, every one of them a *reasonable plumbing action* the operator took and disclosed (two `sed`s on runner scripts, two diagnostic micro-reads) — the rule as written was measurably too rigid for its own author; (ii) in a random session, the Opus operator frequently *is* the appropriate implementer — forcing dispatch overhead onto a 40-line solo fix inverts the economics the topology exists to serve. **Resolution: the operator prompt defines two modes.** In **solo mode** (default), no diet, no dispatch machinery; the evidence gate, caps, and D1.5 rules still bind. In **orchestrated mode** (entered when the operator dispatches its first subagent for the engagement), the diet applies in a relaxed form: no ingesting worker transcripts or raw diffs (inspect via `--stat` and reports), 30-line report cap, plus an explicit **plumbing carve-out** — direct action on harness/infrastructure files is permitted and logged, which converts the four observed "violations" into the rule. The self-audit checkpoint (§3, O1) applies in orchestrated mode only. **Confidence: high** on the mode split's necessity; **moderate** on the exact diet relaxation — Phase 3 exercises it.

**Sizing:** the operator charter template targets **≤150 lines** including the schemas (the build charter is 373 with appendices; the generalized core minus plan-specific content and appendices fits, and the cap forces the prune discipline this section promises). The test: `wc -l` at Phase 0's gate.

---

## 3. Harness integration — what lives where (Decision D3)

**Delivery vehicle.** Four candidates, one pick:

| Vehicle | Verdict | Grounds |
|---|---|---|
| (a) Global `~/.claude/CLAUDE.md` section | REJECT as primary | Pollutes every session including trivial ones; collides with the existing CORE_RULES/ENGINEERING_PRINCIPLES global content; un-versioned per project. |
| (b) Plugin skill with trigger description | REJECT as sole carrier | Skill activation is the *single best-measured unreliability in this repo* (S2: four probes, four outcomes; S14: zero Skill tool_use in 407 events). A charter that must always be present cannot ride a stochastic trigger. Retained as the discovery/reference front door only. |
| (c) Slash command that materializes the charter into the project | **ADOPT** | CLAUDE.md persistence is the one delivery mechanism this record *proves* survives a multi-day, multi-compaction run (charter design note; recovery protocol exercised). A `/operator:start` command copies the charter template into the worktree (appended to project `CLAUDE.md`, or as `OPERATOR.md` referenced from a two-line CLAUDE.md stanza — Phase 1 tests which re-injection behaves identically; **unverified fact U3**), initializes the ledgers, and installs the hook config. |
| (d) Agent definition | REJECT | Agents are subagents; the operator is the main thread. Category error. |

The deliverable is therefore a **plugin** (`chief-operator/`) containing: the charter template, the `/operator:start` (and `/operator:handoff`) commands, `scripts/ops-verdict.sh`, the Stop-hook script + hook config fragment, three generic agent definitions, and a thin skill whose only body content is routing ("if the user asks how to run an orchestrated engagement, run `/operator:start`"). This matches the OKF-style plugin conventions already in use. **Confidence: high** on (c) over (b) given the activation evidence; **moderate** on plugin packaging details vs. current plugin-spec drift — Phase 0 validates with `claude plugin validate`.

**Ledger placement.** Per-project `.operator/` directory: `.operator/VERDICTS.md` (the GATES.md generalization — same four-column row schema verbatim: `| Gate | Criterion | Evidence | PASS/FAIL |`, with "Gate" now the engagement/task ID), `.operator/DECISIONS.md` (identical greppable line schema), `.operator/pending/` (sentinel files, §4). Schemas are carried unchanged because they are proven and because identical grammar means the human's grep habits and any future tooling transfer. The build harness's `evals/results/` ledgers stay untouched and build-scoped. **Confidence: high.**

**Every overlap, named and resolved:**

| # | Overlap | Resolution |
|---|---|---|
| O1 | Self-audit checkpoint (charter rule 7) vs. new charter | Lives **only** in the charter template, orchestrated-mode section, generalized to two questions: (a) since the last verdict, did I ingest worker transcripts/diffs? (b) did I act outside the plumbing carve-out without logging? Not restated in skill, agents, or hook. |
| O2 | Completion-claim discipline: skill's `self-verification` reference vs. ledger vs. hook | Three layers, no duplication: the **skill** owns claim *formatting* (Claim/Evidence/Status table — its reference file is the single source); the **ledger** owns claim *storage* (the row); the **hook** owns claim *timing* (no stop while a verdict is pending). The charter contains one sentence pointing at each. The known product gap — S14 never produced the table, S13 regressed — is a v0.3 skill item; the operator layer's hook+row still binds regardless, which is why the operator remains safe to ship before v0.3 lands. |
| O3 | Dispatch packet + status protocol: charter vs. agent bodies | Packet schema and four-status protocol live in the charter (orchestrated section), carried verbatim minus build-specific fields; the CONSTRAINTS field becomes a free slot (the F1–F13 citations were build-specific). Agent bodies keep only their role-side halves (read INPUTS only, NEEDS_CONTEXT on underspecification, ≤30 lines, status vocabulary) — exactly the split the build used, which produced zero protocol ambiguities in the record. |
| O4 | Loop caps: charter (review ×2) + roadmap (scenario ×2; treadmill ×2 rounds) | One cap table in the charter, three rows: identical-rejection ×2 → escalate; same-target-rework ×2 → stop reworking that target, log, move on or escalate; fix-round-regressing-neighbors ×2 → end the engagement's tuning permanently and report (roadmap stop-condition 1, generalized). Removed from everywhere else. |
| O5 | Preflight: build's 7-step Appendix C vs. generic sessions | Not carried as a checklist (D1.5 rationale). `/operator:start` mechanizes the mechanizable subset (branch-not-main warning, ledger init, hook install); agent probes run only on entering orchestrated mode (first dispatch is preceded by the probe packet — carried verbatim, it caught nothing but cost nothing and proves pinning). The rest of preflight becomes D1.5's meter/destination principles. |
| O6 | Recovery protocol | Carried nearly verbatim (re-read charter → read `.operator/DECISIONS.md` → `git log --oneline -20` → read VERDICTS.md → rebuild todos → resume; never trust memory over ledgers). It is the proven compaction countermeasure and costs six lines. |
| O7 | Cost telemetry CSV | **Not generalized.** It is coupled to headless `claude -p` JSON output; interactive-session cost capture is version-dependent and unverified (**U4**). Where an engagement spawns headless runs, the runner-script convention applies as-is. The charter says only: headless runs go through a runner script with explicit allowlist, turn cap, JSON output, and cost row — the four requirements Appendix B proved, requirements not flag spellings. |
| O8 | Charter vs. `superpowers` skills (subagent-driven-development, verification-before-completion, etc.) | Same precedence rule the build used, verbatim: charter wins on conflict, conflict logged in DECISIONS. No content merged from them into the charter. |

---

## 4. The evidence-gate mechanism (Decision D4)

**The engagement contract (synthesized gates — the §0.4 discontinuity's mechanism).** On any non-trivial engagement (test: multi-file, or multi-session, or the user asked for "done/complete/working" as a deliverable state), the operator's first ledger action is a **BAR block** appended to VERDICTS.md: the enumerated done-criteria (each phrased as a command + expected output where possible), the budget (time/cost/iteration), and the applicable caps. Trivial requests are exempt by the same test. This is where the skill composes: producing the criteria *is* an implementation-plan/interview route, and the operator lets the skill fire rather than instructing it. Rationale: the build's gates worked because criteria pre-existed the work; the roadmap's stop-condition 4 ("each future cycle needs a pre-declared bar and budget; no open-ended tuning") is the same lesson stated as policy after the treadmill. **Confidence: high** on requiring the bar; **moderate** on the exact non-triviality test — Phase 1 tunes it.

**Structural enforcement — three layers, cheapest first:**

1. **Definitional (prose, proven):** the row schema plus the sentence that does the real work: *"A row without evidence is FAIL by definition; assertions are not evidence; command output, diffs, and reviewer verdict lines are."* Zero fabricated evidence cells across 7 gates under this rule.

2. **Mechanical (new — and it overturns a prior conclusion):** the v2 charter concluded orchestrator-only rules "can't be cleanly mechanized today" because hooks also fire for subagent tool calls. That was correct for PreToolUse-shaped enforcement and **remains correct there**, but it does not apply to the completion case: current Claude Code separates **`Stop`** (main agent turn end) from **`SubagentStop`**, so a Stop hook gates only the operator, never blinds reviewers, and exit 2 blocks the stop while feeding stderr back as instruction. Verified against current docs, 2026-07-06 (`stop_hook_active` guard required to prevent loops). Mechanism, deliberately dumb so it cannot misfire on NLP: opening a tracked task drops a sentinel `.operator/pending/<task-id>`; `scripts/ops-verdict.sh <task-id> <criterion> <evidence> <verdict>` appends the row *and* clears the sentinel (single writer, append-only preserved by construction); the Stop hook exits 2 with "pending verdict for <ids> — run ops-verdict or log a DECISION deferring it" whenever `.operator/pending/` is non-empty and `stop_hook_active` is false. The deferral path exists because a legitimately blocked engagement must be able to end — deferring writes a DECISIONS line, which is the honest state. **Confidence: high** on Stop/SubagentStop separation and exit-2 semantics (official docs + multiple corroborating sources); **moderate** on payload/config details surviving version drift — the hook install step re-verifies, exactly as the runner script's preflight step did for CLI flags (**U2**).

3. **Optional hardening (Phase 2+, only if Phase 1 shows tampering or accidental edits):** a PreToolUse `Edit|Write` matcher denying direct mutation of `VERDICTS.md` outside `ops-verdict.sh`. Not shipped by default: the record contains zero ledger-tampering incidents, and this hook *does* fire for subagents, so it needs the `agent_id` field check — complexity with no observed incident behind it.

**Tie to the existing GATES.md:** same grammar, different scope, single writer script. The build's ledger is not reused as the generic ledger because its rows are keyed to the build's plan; conventions transfer, files don't.

---

## 5. The delegation contract (Decision D5)

**Observed chain and weakest links.** Operator → in-session subagents {`harness-author` opus-4-8, `harness-reviewer` opus-4-8 read-only, `harness-mechanic` **sonnet-4-6**} and → headless `claude -p` sessions (**sonnet-5, unsupervised**). Two distinct "weakest" axes, and the contract must handle both because they fail differently:

- **Weakest by capability: the sonnet-4-6 mechanic tier.** Observed mitigation that worked and generalizes verbatim: fully-specified single-target tasks, verbatim content in the packet, and the NEEDS_CONTEXT-instead-of-inventing instruction — which the record shows firing correctly, twice, on the one genuinely underspecified task (isolation), escalating properly through the packet-deficiency rule. The mechanic never fabricated; it refused. That is the contract working.
- **Weakest by supervision: headless sessions.** Every observed fabrication (S13-r2, S14) came from this link — a *stronger* model than the mechanic. Therefore the contract keys trust to supervision, not tier: **any headless output is Unverified until scored by a reviewer dispatch or checked by command**, and behavioral claims about a headless run come from its stream record, not its final message (Gate-4 lesson).

**Contract contents (all carried from the proven set, generalized):** the dispatch packet (TASK / FULL TASK TEXT / SCENE / INPUTS / FORBIDDEN / CONSTRAINTS / DONE MEANS / REPORT ≤30 lines with SHA); the four-status protocol (DONE / DONE_WITH_CONCERNS / NEEDS_CONTEXT / BLOCKED); the escalation ladder rungs 1–4 with rung 4 reserved for genuine contradictions; two-stage review (spec then quality, never reversed) with the ×2 loop cap; one implementer at a time, parallel read-only on disjoint inputs; reverts via mechanic dispatch. Generic agent trio ships in the plugin (`op-author`, `op-mechanic`, `op-reviewer`) as project-agnostic copies of the harness agents with the F1–F13 constraint text replaced by the packet's CONSTRAINTS slot, model fields carrying the same tier intent with the preflight-probe rule for spelling drift.

**What scales down for generic sessions (named test, not "as appropriate"):** two-stage review applies to work that will be **merged, published, or depended on by a later task in the engagement**; exploratory/throwaway artifacts (probes, spikes, drafts the operator will rewrite) skip review. Grounds: review cost was the identified v1→v2 economic risk; the build reviewed everything because everything shipped; a generic session does not. **Confidence: high** on the packet/status/ladder transfer (heavily exercised, zero ambiguity incidents); **moderate** on the review-scope test's calibration — Phase 3 exercises it and Phase 4 audits it.

---

## 6. The handoff schema (Decision D6)

Two handoffs, two proven templates already in the repo — the spec's job is to canonize them, not invent.

**Worker → operator (per dispatch).** The REPORT block becomes structured: status line first, then exactly two lists — **ACCOMPLISHED**, each line carrying its evidence inline (command output line or SHA; a line without evidence is written under Unverified instead, by the D1.3 definitional rule), and **UNVERIFIED**, each line carrying *why* it is unverified and *what command would verify it*. This is the skill's Claim/Evidence/Status table refit to the 30-line report format, and it makes the Gate-5 honesty pattern ("no positive demonstration of X — logged") the required shape rather than a virtue. The operator transfers UNVERIFIED lines into VERDICTS.md pending state rather than silently accepting them.

**Operator → human (per engagement / session end, via `/operator:handoff`).** The roadmap document is the proven artifact — it survived a cold-start actionability review and an adversarial count check. Its skeleton, generalized verbatim as the handoff schema: (1) **Verdict** — shipped / not-shipped / partial, against the BAR block, one table; (2) **Banked** — what holds regardless of verdict, each item ledger-cited; (3) **Unverified / open** — the explicit not-accomplished list with what would verify each item; (4) **Conditional next steps** — each with an entry condition that must be checked before starting (the roadmap's "probe before building on it" pattern); (5) **Stop conditions** — when *not* to continue; (6) **Not-doing list** — explicit anti-scope. Sections 3 and 5/6 are the unverified-vs-accomplished separation you asked for, held at document-structure level so their absence is visible, not just discouraged. **Confidence: high** — this is the least speculative decision in the spec; the template already passed review in production.

---

## 7. Unverified facts this design depends on

Flagged per your constraint; none papered over. **U1:** Opus 4.8 as *main-session operator* is unobserved — the entire judgment-delta layer of D1 is hypothesis until Phase 1; if Phase 1 shows Opus violating the ledger discipline a Fable operator held, D1.1's "nothing heavier" verdict re-opens. **U2:** hook config/payload details drift across Claude Code versions; the install step re-verifies (the runner-script precedent). **U3:** whether `OPERATOR.md`-referenced-from-CLAUDE.md gets the same re-injection persistence as inline CLAUDE.md content — Phase 1 tests both, inline is the fallback (it is the exact proven configuration). **U4:** interactive-session cost capture — excluded from scope rather than assumed (O7). **U5:** the D1.5 principle-over-checklist bet — falsifiable by recurrence of destination/meter incidents in Phase 1–4 ledgers; the fallback is a short mechanized checklist in `/operator:start`.

---

## 8. Phased implementation plan

Sequenced so each phase produces a testable artifact against the real harness; no phase's verification depends on a later phase. Executor per phase named by tier. Budget discipline per roadmap stop-condition 4: each phase carries its bar here; if a phase exceeds ~2× its expected effort without meeting its done-condition, stop and report rather than iterate (the caps apply to building the operator too).

**Phase 0 — Extract and scaffold** (mechanic-tier with author-tier for the charter prose). Build the `chief-operator/` plugin: charter template (solo + orchestrated sections, cap table, recovery protocol, schemas, rule citations inline), `/operator:start` and `/operator:handoff` commands, `ops-verdict.sh`, Stop-hook script + config fragment, three generic agents, router skill.
*Done-condition:* plugin validates; charter ≤150 lines; **every rule line carries a citation tag**; ledger schemas byte-identical to the proven ones where carried.
*Verification:* `claude plugin validate` clean; `wc -l` on the charter; `grep -c '\[D-'` equals the rule count (a rule without a tag fails the gate); diff of row/line schemas against `evals/results/GATES.md` / `DECISIONS.md` headers.

**Phase 1 — Solo-mode pilot, and the U1/U3 measurements** (Opus 4.8 as operator — this is the point). In a scratch repo with the plugin and `surfacing-unknowns` v0.1 installed: run 3 real solo engagements of mixed size (one trivial — must *not* produce a BAR block; two non-trivial). Run the U3 A/B: one engagement with the charter inline in CLAUDE.md, one with the OPERATOR.md pointer, forcing at least one compaction each (long transcript or manual `/compact`), then probing rule recall post-compaction.
*Done-condition:* both non-trivial engagements show BAR blocks appended before first implementation commit; every done-claim has a VERDICTS row with a command-output evidence cell; zero unevidenced completion claims in final messages; the trivial engagement shows no operator ceremony; U3 verdict recorded with the post-compaction probe as evidence.
*Verification:* grep VERDICTS.md for rows whose evidence cell lacks output-shaped content (must be zero); ledger timestamps vs. `git log` ordering for bar-before-work; the compaction-recall probe transcripts.

**Phase 2 — Stop-hook evidence gate** (mechanic to build, operator-in-scratch to test). Implement sentinel + hook + `ops-verdict.sh` wiring.
*Done-condition:* three demonstration transcripts: (a) a done-attempt with a pending sentinel is blocked (exit 2, stderr instruction visible, operator then appends the row and stops cleanly); (b) `stop_hook_active` prevents a loop; (c) a dispatched subagent's completion does **not** trip the main Stop hook (the SubagentStop-separation claim, tested not assumed); plus (d) the deferral path writes its DECISIONS line and releases.
*Verification:* the four transcripts, each cited in the phase's VERDICTS rows — the mechanism validates itself through its own ledger.

**Phase 3 — Orchestrated mode** (Opus operator, real multi-task job — e.g., one item off the Hum or html-artifacts backlog). Enter orchestrated mode: agent probes, ≥4 dispatches spanning author and mechanic tiers, ≥1 two-stage review on shipping work, ≥1 exploratory artifact correctly skipping review (D5's scope test exercised), and one synthetic underspecified packet to confirm NEEDS_CONTEXT still fires under the generic agents.
*Done-condition:* probe rows present before first real dispatch; every dispatch has a packet-conformant record and a ≤30-line structured report (ACCOMPLISHED-with-evidence / UNVERIFIED); the review-scope decision logged with its test named; the relaxed diet's self-audit lines present at each verdict.
*Verification:* ledger inspection per above; the NEEDS_CONTEXT transcript.

**Phase 4 — Failure-log-driven prune** (operator + human). After **5** real engagements post-Phase 3 (count fixed now so the trigger isn't judgment), audit `.operator/DECISIONS.md` across them: every charter rule is scored exercised / violated / inert. Inert rules are deleted (the Gate-7 prune policy applied to the operator itself); new rules admitted only against logged incidents, one per incident class, subject to the ≤150-line cap.
*Done-condition:* a revision commit whose message body carries per-rule keep/delete evidence — the exact shape of the v0.1 prune decision record.
*Verification:* the commit itself; charter still ≤150 lines; citation-tag gate re-run.

**Standing condition (from roadmap stop-condition 2, applied to this artifact):** on the next model release, re-run Phase 1 baseline-style — an uncharted Opus-successor operator on the same 3 engagements. Any rule whose behavior now appears unaided is a deletion candidate. If most of the charter falls to baseline, retire it gracefully; that is the harness philosophy applied to its own operator layer, and it is success.

---

## 9. Decision index

| ID | Decision | Confidence |
|---|---|---|
| 0.1–0.4 | Brief corrections: one-skill topology; failure log measures Fable not Opus; plumbing dominates judgment; gates must be synthesized per engagement | high / high / high–moderate / high |
| D1 | Seams: fabrication→completion-claim gate (keep, retargeted); premature convergence→skill composition only; verification theater→carry the definitional rule + record-over-summary; scope drift→replaced by unbounded-iteration caps; + NEW dirty-measurement-surface and dispatch-packet-defect seams | per-seam above; delta layer part-hypothesis pending Phase 1 |
| D2 | Trust boundary: decomposition/tools/prose/asking untouched; two-mode charter (solo default, orchestrated diet with plumbing carve-out); ≤150 lines; every rule cites its incident | high; diet relaxation moderate |
| D3 | Delivery: plugin with `/operator:start` materializing the charter into CLAUDE.md/OPERATOR.md; skill as front door only (activation proven stochastic); `.operator/` ledgers with byte-identical schemas; 8 overlaps resolved O1–O8 | high; U3 pending |
| D4 | Evidence gate: BAR block per engagement; definitional rule; sentinel + `ops-verdict.sh` + Stop-hook exit-2 (overturns the v2 "can't mechanize" conclusion for the completion case — Stop ≠ SubagentStop, verified); append-only by single-writer construction | high; U2 on version drift |
| D5 | Delegation: trust keyed to supervision not tier (headless = Unverified until scored); packet/status/ladder/caps carried verbatim; review scoped by merged-published-or-depended-on test | high; review-scope calibration moderate |
| D6 | Handoff: worker report = ACCOMPLISHED-with-evidence / UNVERIFIED-with-verifier; human handoff = the roadmap skeleton (verdict / banked / unverified / conditional-next-with-entry-conditions / stop conditions / not-doing) | high |
