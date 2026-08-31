# Principal-architect audit — 2026-08-31 (autonomous)

Audited: the whole plugin at `b653c25` (0.11.3). Method: full direct read of the
gate layer by the auditing operator; four parallel audit arms (workflows,
validator/release-gate, compressor/statusline, docs-vs-code) whose findings were
each re-verified against source or re-reproduced before entering the ledger;
vacuity probes run as real mutations on /tmp copies. The complete finding
ledger, in the admissible evidence schema, is `AUDIT_LOG.md` at the repo root
(34 findings, F101–F134 — numbered above F95 because the repo's own history
owns F01–F95). Every fix in the remediation landed with a test that was run RED
against the pre-fix code; red-run outputs are recorded in the ledger's Phase 3
events.

## Verdict

Salvageable-with-work at the start, healthy at the end — with one grave caveat.
The architecture is right and the discipline is real: the sentinel-ownership
gate, the lock, the partition rule, and the reader-bounds culture all held up
under adversarial review. What failed was exactly what the repo's own doctrine
predicts: silent regressions in places the tests could not see (a stripped
control byte, a mention-satisfiable pin), and a fixed defect class (F01, #94)
left unfixed in a sibling component.

## The one thing to tell users

**Evidence collected under 0.10.0 through 0.11.3 in operated projects may have
been falsified by the compressor** (F120): `scrub()`'s ANSI regexes lost their
ESC anchors in the 0.10.0 debloat, so any `]`-bearing tool output over 1KB that
went through the PostToolUse hook was silently truncated at the first `]` — no
marker, no spill — before the model read it. A verdict row whose evidence
quotes tool output from that window deserves re-verification. The stamp on each
row (`@<sha>`) bounds which rows are affected.

## Findings by severity (fixed unless marked otherwise)

| ID | Sev | One line |
|----|-----|----------|
| F120 | P0 | scrub regexes lost `\x1b` anchors — silent output destruction at the first `]` |
| F126 | P1 | the partition.sh sourcing pin was satisfied by a comment mentioning the filename |
| F101 | P2 | SessionStart exact-matched `$cwd/.operator` — silent no-op from subdirectories |
| F102 | P2 | SessionStart banner prescribed relative CLI paths (the #94 shape) |
| F103 | P2 | debate: agent output could overwrite a seat's pinned letter/model/dead |
| F104 | P2 | brainstorm: zero surviving directions still paid the converge, shipped a clean bundle |
| F105 | P2 | crawl: `[object Object]` shard elements dispatched paid crawlers |
| F106 | P2 | the adversarial verifier had no untrusted-data rule; OBSERVED_HEAD forgeable from content |
| F107 | P2 | review crashed post-panel on a non-array `findings` |
| F108 | P2 | CLAUDE.md pointed at `validate_plugin.DECISIONS_KINDS`, which never existed |
| F121 | P2 | elide marker claimed "not spilled" on spilled output |
| F127–F130 | P2 | four more vacuity classes in the guard layer (raw-text, presence-only, unanchored) |
| F131 | P2 | release_gate truncated notes at `^\[` and resolved defs inside code fences |
| F109–F119, F122–F125, F132–F134 | P3 | see AUDIT_LOG.md — all fixed except F118/F123 (deferred, below) |

## Guardrail catalog (what now locks each class in)

| Invariant | Enforcement | Artifact |
|---|---|---|
| scrub is lossless on plain text; both regexes carry `\x1b` | test + validator pin | tests/test_compress.mjs "F120" block; check_compressor anchor pins |
| both hooks resolve the project by the same walk-up | bash cases | tests/test-scripts.sh "SessionStart resolves the project by WALKING UP" |
| session guidance prescribes absolute quoted CLI paths | bash cases | tests/test-scripts.sh "banner prescribes ABSOLUTE" |
| seat identity survives agent output in every debate round | node case with forged keys | tests/test_workflows.mjs F103 cases |
| dead fan-outs refuse the converge spend | node cases | tests/test_workflows.mjs F104 cases |
| a pin fires on the mutation it was written against | red python test per repaired pin | tests/test_validate_plugin.py F126–F134 cases |
| spilled output carries exactly one spill status | test | tests/test_compress.mjs F121 case |
| release notes never silently truncate | red tests | tests/test_release_gate.py F131 cases |

## Residual risks (known, not fixed)

| Risk | Sev | Why not fixed | Mitigation |
|---|---|---|---|
| Historical evidence falsified by F120 (0.10.0–0.11.3 window) | P1 (historic) | cannot be fixed retroactively | source stamps bound the window; note above tells users to re-verify |
| F106's data-rule is prompt armor, not a mechanism | P3 | a model can still be steered; no harness-level provenance exists for OBSERVED_HEAD | rule + provenance sentence in prompt and agent file; live run would confirm effect |
| F118: a planted `A__B__C` sentinel blocks with an id the CLIs refuse | P3 | needs a design call — degrading double-separator names to unowned changes what the gate blocks on | threat model is drift, not planted files; manual `rm` clears |
| F123: U+FFFD at the elide byte boundary | P3 | cosmetic; spill stays byte-verbatim | none needed |
| GitignoreParityTest's marker-grep pin cannot distinguish the detection grep from a confirmation grep | P3 | found during remediation, out of scope | noted in tests/test_validate_plugin.py beside the repaired case |
| Autobar cannot attribute a shared-worktree delta to a session | accepted | priced trade, documented in lib/autobar.sh | one bounded self-announcing false arm per session |

## Prioritized backlog (pickup-able cold)

1. **Run the REPLAY-CHARTER (R0–R8) against this tree** — context: the repo's
   own doctrine requires a live re-proof of the harness seam after plugin
   changes this large; R0's build-identity `cmp` matters doubly now that
   SessionStart's upgrade path changed. First step: follow
   docs/REPLAY-CHARTER.md R0 in a scratch project. Done-when: every phase
   recorded as a verdict row through the gate it audits.
2. **Publish 0.11.4** — context: the version bump and the `[0.11.4]` heading
   already landed on this branch (CI's `test_real_repo_gate_passes` forced
   them in the same commit); what remains is the publish itself. First step:
   after merge, verify locally with `python3 scripts/release_gate.py v0.11.4`
   (the argument is the TAG, `v`-prefixed), then tag `v0.11.4` on the merge
   commit. Done-when: both forges' release workflows green.
3. **F118 design call** — context: AUDIT_LOG.md F118; decide whether
   `sentinel_owner_of_name` should degrade a double-`__` remainder to unowned
   (fails closed, names a clearable path) or scan_pending should flag the id as
   malformed. First step: write the failing bash case from the ledger's
   "what confirms" line. Done-when: the block message for that shape names a
   command that actually clears it.
4. **commands/handoff.md still prescribes a relative CLI path** — context:
   F102 fixed the banner; the handoff command's prose (and its allowed-tools
   pattern, which cannot be absolute) still assumes root cwd. First step: make
   the command's prose tell the model to use the absolute path the banner/Stop
   hook provided. Done-when: the "/cc-operator:handoff carries the six-section
   contract" case pins it.
5. **F123 UTF-8 boundary backoff in elide** — context: AUDIT_LOG.md F123; back
   off to a UTF-8 boundary before decoding head/tail. Done-when: a
   boundary-split test asserts zero U+FFFD in output.
6. **Distinguish detection vs confirmation greps in check_gitignore_parity**
   — context: the E-arm collision note in tests/test_validate_plugin.py.
   Done-when: a mutation removing only the DETECTION grep fires with the
   confirmation grep still present.

## Provenance

- Auditing session: autonomous principal-architect audit, 2026-08-31, branch
  `claude/principal-audit-autonomous-8e8cw1`, PR #97.
- Working ledgers: `AUDIT_LOG.md` (append-only events + all 34 findings with
  evidence), `AUDIT_STATE.md` (phase cursor; final state).
- Suite deltas, baseline → end: pytest 229→247, bash 732→744, workflows
  354→384, compress 90→97; validator and shellcheck (CI-pinned 0.10.0) green
  throughout the final tree.
