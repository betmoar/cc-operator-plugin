// tests/test_workflows.mjs — execution tests for the workflow .js logic.
//
// A workflow script runs top-to-bottom with top-level `await`, calling agent() /
// parallel() / phase() / pipeline() / log() against the live harness. We cannot
// drive the harness in-test, but we CAN load the workflow as a module with
// STUBBED globals: `args` is injected, the agent primitives return canned
// schema-shaped fixtures. The workflow's PURE top-level logic then runs against
// real (stubbed) input — tier validation, the N clamp, the bucket/threshold
// filter — and we assert on what it computes. This tests the ACTUAL code, not a
// re-implementation (the import-forbidden sandbox means we can't factor it out).
//
// Run:  node tests/test_workflows.mjs   (exit 0 iff all pass)
// CI:   added as a step in .github/workflows/validate.yml (node ships on the runner).

import { pathToFileURL } from "node:url";
import path from "node:path";

const ROOT = path.resolve(import.meta.dirname, "..");
const WF = (f) => pathToFileURL(path.join(ROOT, "workflows", f)).href;

let pass = 0, fail = 0;
const ok = (cond, msg) => {
  if (cond) { pass++; console.log(`  ok   ${msg}`); }
  else { fail++; console.log(`  FAIL ${msg}`); }
};
// `expect` is REQUIRED: a substring the thrown message must contain.
//
// The generalized form of the #59-precondition finding (Copilot, PR #67): an
// assertion that accepts ANY throw is satisfied by a throw that has nothing to
// do with the property under test. Measured directly — a `TypeError: undefined
// is not a function` from a broken harness scored as "tier: typo 'Mechanical'
// rejected". Every workflow guard here throws with a specific message, so
// naming a fragment of it costs nothing and is what makes the case discriminate
// between "the guard fired" and "something, somewhere, threw".
//
// It is a required parameter rather than an optional one on purpose: an
// optional tightening is a tightening nobody applies to the next case.
const throws = async (fn, msg, expect) => {
  if (!expect) { ok(false, `${msg} (test bug: throws() needs an expected message fragment)`); return; }
  try { await fn(); ok(false, `${msg} (expected throw, got none)`); }
  catch (e) {
    const m = String(e?.message ?? e);
    ok(m.includes(expect), m.includes(expect) ? msg : `${msg} (threw ${JSON.stringify(m.slice(0, 70))}, expected to contain ${JSON.stringify(expect)})`);
  }
};

// ── stub the workflow runtime globals ───────────────────────────────────────
// phase/log are no-ops. agent() returns a caller-controlled canned value. We
// key the canned return on the agent's `label` so a workflow's multiple agent
// calls each get distinct fixtures. parallel returns its thunks' results in
// order; pipeline runs each item through the stages.
function makeRuntime(agentReturns = {}) {
  const calls = [];
  const agent = async (prompt, opts = {}) => {
    const label = opts.label ?? "_";
    // `isolation` is captured because #23's whole deliverable is WHERE the seat
    // runs, and that lives in the opts the workflow passes — not in its return
    // value. A case asserting only on the prompt would pass on a workflow that
    // describes an isolated run and dispatches a builder-tree one.
    calls.push({ label, model: opts.model, prompt, isolation: opts.isolation });
    return agentReturns[label] ?? null;
  };
  const parallel = async (thunks) => {
    const out = [];
    for (const t of thunks) out.push(await t());
    return out;
  };
  const pipeline = async (items, ...stages) => {
    let out = [];
    for (const item of items) {
      let cur = item;
      for (const stage of stages) cur = await stage(cur, item, items.indexOf(item));
      out.push(cur);
    }
    return out;
  };
  const phase = () => {};
  // Captured, not discarded: log() is the ONLY channel by which a fan-out
  // reports that some of its agents failed to return. A workflow that silently
  // narrows its coverage is a real defect, so the messages are assertable.
  const logs = [];
  const log = (m) => { logs.push(String(m)); };
  return { agent, parallel, pipeline, phase, log, calls, logs };
}

// Load a workflow with injected globals + args, return its result. The workflow
// reads bare `args`/`agent`/etc. as globals; we wrap its source in a Function
// with the stubs as parameters so the top-level logic runs against them.
async function run(file, argsValue, agentReturns) {
  const rt = makeRuntime(agentReturns);
  const fs = await import("node:fs");
  // Strip `export ` — the workflow ships as ESM, but we wrap it in a Function
  // (CommonJS body), where `export const` is a syntax error. `export` only
  // marks meta for the harness; it's inert at runtime.
  const source = fs.readFileSync(new URL(file), "utf8").replace(/\bexport\s+const\s+meta\b/, "const meta");
  const fn = new Function(
    "args", "agent", "parallel", "pipeline", "phase", "log",
    `return (async () => {\n${source}\n})();`
  );
  const result = await fn(argsValue, rt.agent, rt.parallel, rt.pipeline, rt.phase, rt.log);
  return { result, rt };
}

// ── brainstorm: tier validation + N clamp ───────────────────────────────────
console.log("-- Case: brainstorm.js tier validation + directions clamping");

// N clamping: non-numeric directions → default 4; "abc" → 4; 0 → 2; 99 → 6; 3 → 3.
// The number of direction agent calls = N (clamped). Stub agent to return a
// fixed direction per label; count the `direction i/N` calls.
async function brainstormN(directions) {
  const rt = makeRuntime({});
  rt.agent = async (p, o = {}) => { rt.calls.push(o.label); return { stance: "x", sketch: "x", tradeoffs: [], yagnis: "x" }; };
  const fs = await import("node:fs");
  const source = fs.readFileSync(new URL(WF("brainstorm.js")), "utf8").replace(/\bexport\s+const\s+meta\b/, "const meta");
  const fn = new Function("args", "agent", "parallel", "pipeline", "phase", "log",
    `return (async () => {\n${source}\n})();`);
  await fn({ directions }, rt.agent, rt.parallel, rt.pipeline, rt.phase, rt.log);
  return rt.calls.filter((l) => l?.startsWith("direction")).length;
}
ok((await brainstormN("abc")) === 4, "brainstorm N: non-numeric 'abc' → 4 directions (F04)");
ok((await brainstormN(0)) === 2, "brainstorm N: 0 → clamped to 2 (min)");
ok((await brainstormN(99)) === 6, "brainstorm N: 99 → clamped to 6 (max)");
ok((await brainstormN(3)) === 3, "brainstorm N: 3 → 3 (in range)");
ok((await brainstormN(undefined)) === 4, "brainstorm N: undefined → default 4");

// Tier validation: IMPLEMENT (valid-but-unused) accepted; typo rejected; bad
// charset rejected. An id operator does not recognise is ACCEPTED (0.8.3).
// Each rejection is a top-level throw, so the workflow aborts before any
// agent call.
await throws(() => run(WF("brainstorm.js"), { tiers: { Mechanical: "glm-5" } }, {}),
  "brainstorm tier: typo 'Mechanical' rejected (F07 typo guard)", "unknown tier");
// Every whitespace/quote shape now lands on the ONE guard (0.8.3 removed the
// id-shape catalogue). The pre-0.8.3 suite split these across two guards and
// mislabelled which one fired — a review found the "glm 5" case claimed charset
// coverage while actually throwing on ROUTABLE, and neutering BAD_CHARSET in
// all four workflows left the suite green. With one guard the label cannot lie,
// but the list still spans the shapes that used to route differently.
for (const bad of ["glm 5", "glm-5 turbo", "vendor/model x", 'glm-5"q', "claude-opus 5"]) {
  await throws(() => run(WF("brainstorm.js"), { tiers: { MECHANICAL: bad } }, {}),
    `brainstorm tier: charset-bad ${JSON.stringify(bad)} rejected (F01)`,
    "outside the");
}
// The converse: a bracket-marked id is charset-LEGAL and must NOT be rejected
// (a Copilot review asserted `]` was excluded from the allowed set; it is not —
// `\]` inside a JS character class includes a literal `]`).
let bracketOk = true;
try {
  await run(WF("brainstorm.js"), { tiers: { MECHANICAL: "glm-5.2[1m]" } },
    { blindspots: { findings: [] }, converge: { ranked: [], sharedConstraints: [], openQuestions: [] } });
} catch { bracketOk = false; }
ok(bracketOk, "brainstorm tier: bracket-marked id 'glm-5.2[1m]' accepted (charset allows ])");
// 0.8.3: an id operator does not recognise is ACCEPTED, and that is the point.
// The list below is the direct inverse of the pre-0.8.3 cases — `not-routable`
// and `bogus:vendor/model` used to be the two headline rejects, held in place
// by a shape catalogue and a provider allowlist. Both were operator asserting
// which model ids exist. The user picks the model; cc-proxy routes it or
// errors. `deepseek-v4-flash` and `qwen3.8-max` are here because they are real
// ids the old guard refused (measured against a live 409-id catalogue), and
// `bogus:vendor/model` because a namespace this repo has never heard of is
// cc-proxy's business, not ours.
for (const good of ["glm-5.2", "claude-opus-5", "deepseek/deepseek-r1:free",
                    "openrouter:anthropic/claude-3-opus", "vendor/model:free",
                    "deepseek-v4-flash", "qwen3.8-max", "not-routable",
                    "bogus:vendor/model"]) {
  let accepted = true;
  try {
    await run(WF("brainstorm.js"), { tiers: { MECHANICAL: good } },
      { blindspots: { findings: [] }, converge: { ranked: [], sharedConstraints: [], openQuestions: [] } });
  } catch { accepted = false; }
  ok(accepted, `brainstorm tier: id ${JSON.stringify(good)} accepted — operator does not gate the catalogue (0.8.3)`);
}
// IMPLEMENT is in KNOWN_TIERS → accepted (no throw); it's unused but routable.
let implOk = true;
try {
  await run(WF("brainstorm.js"), { tiers: { IMPLEMENT: "claude-sonnet-5" } },
    { blindspots: { findings: [] }, converge: { ranked: [], sharedConstraints: [], openQuestions: [] } });
} catch { implOk = false; }
ok(implOk, "brainstorm tier: IMPLEMENT accepted (F07 — valid-but-unused tier)");

// ── review: bucket + threshold filter ───────────────────────────────────────
console.log("-- Case: review.js scoring bucket + threshold");
// Synthesize a panel whose findings we control, assert the workflow drops <50
// and buckets 75+/60-74/50-59. Stub each lens to return its findings.
const panelFixtures = {
  "lens:spec": { findings: [
    { summary: "drop me", evidence: "x", score: 40 },   // dropped (<50)
    { summary: "consider", evidence: "x", score: 55 },   // consider (50-59)
    { summary: "clarify", evidence: "x", score: 65 },    // should-clarify (60-74)
    { summary: "must", evidence: "x", score: 90 },       // must-resolve (>=75)
  ] },
  "lens:quality": { findings: [] },
};
const { result: rev } = await run(WF("review.js"), {}, panelFixtures);
ok((rev.dropped ?? 0) === 1, "review: drops findings below the 50 threshold");
ok(rev.findings.length === 3, "review: keeps 3 findings at/above 50");
ok(rev.findings[0].score === 90, "review: findings sorted highest-score-first");
ok(rev.findings.find((f) => f.score === 90).bucket === "must-resolve", "review: bucket >=75 → must-resolve");
ok(rev.findings.find((f) => f.score === 65).bucket === "should-clarify", "review: bucket 60-74 → should-clarify");
ok(rev.findings.find((f) => f.score === 55).bucket === "consider", "review: bucket 50-59 → consider");

// A lens whose agent dies resolves to null and is dropped by .filter(Boolean).
// Dropped-lens and found-nothing are then indistinguishable unless the ratio is
// logged — crawl.js logs it for the identical pattern; review.js did not, so a
// panel could silently run at half the coverage the operator asked for.
const ALL_LENSES = ["spec", "testability", "feasibility", "quality", "correctness"];
const everyLens = Object.fromEntries(ALL_LENSES.map((k) => [`lens:${k}`, { findings: [] }]));
const { rt: fullRt } = await run(WF("review.js"), {}, everyLens);
ok(fullRt.logs.some((m) => new RegExp(`\\b${ALL_LENSES.length}/${ALL_LENSES.length} lenses returned`).test(m)) &&
   !fullRt.logs.some((m) => /FAILED/.test(m)),
  "review: logs a full lens ratio, no FAILED, when every lens returns");
// Drop one lens fixture → its agent returns null and is filtered out.
const { rt: partialRt } = await run(WF("review.js"), {},
  Object.fromEntries(Object.entries(everyLens).filter(([k]) => k !== "lens:quality")));
ok(partialRt.logs.some((m) =>
     new RegExp(`\\b${ALL_LENSES.length - 1}/${ALL_LENSES.length} lenses returned`).test(m) &&
     /1 FAILED: quality/.test(m)),
  "review: a dead lens is reported as FAILED coverage, not silently dropped");
const { result: partialRev } = await run(WF("review.js"), {},
  Object.fromEntries(Object.entries(everyLens).filter(([k]) => k !== "lens:quality")));
ok((partialRev.deadLenses ?? []).join() === "quality",
  "review: the dead lens is named in the RESULT, not only the log");

// The Workflow tool JSON-encodes a passed scalar, so a bare target path
// arrives as `"docs/x.md"` — quotes included. They used to survive into
// `target` and ship in every lens prompt as part of the path.
const { rt: quotedRt } = await run(WF("review.js"), JSON.stringify("docs/x.md"), everyLens);
const lensPrompt = quotedRt.calls.find((c) => c.label.startsWith("lens:")).prompt;
ok(lensPrompt.includes("ARTIFACT: docs/x.md\n"),
  "review: a JSON-encoded bare target is unwrapped, not passed with its quotes");
// A plain (un-encoded) path must still work, and invalid JSON must not throw.
const { rt: plainRt } = await run(WF("review.js"), "docs/y.md", everyLens);
ok(plainRt.calls.find((c) => c.label.startsWith("lens:")).prompt.includes("ARTIFACT: docs/y.md\n"),
  "review: a plain bare target still passes through unchanged");
const { rt: junkRt } = await run(WF("review.js"), '"unterminated', everyLens);
ok(junkRt.calls.find((c) => c.label.startsWith("lens:")).prompt.includes('ARTIFACT: "unterminated'),
  "review: unparseable JSON degrades to the raw string, no throw");

// ── plan: decomposition + vet classification ────────────────────────────────
console.log("-- Case: plan.js vet classification (blocked / needs-info / clear)");
// Stub decompose to return 2 tasks; vet lenses return feasible/testable/issues.
// Assert the workflow classifies a 'no' feasibility as blocked, 'needs-info' as
// needsInfo, and clean as neither.
// `blocked` is three OR'd conditions. The original fixture set feasible:"no"
// AND a contradiction issue on the same task, so it proved only that their
// disjunction fires — a regression killing the testable or contradiction branch
// alone would have passed. Each condition now has its own task.
const planFixtures = {
  decompose: { tasks: [
    { id: "clean", title: "t", files: [], produces: "", testCycle: "run x → pass" },
    { id: "blocked", title: "t", files: [], produces: "", testCycle: "run x" },
    { id: "untestable", title: "t", files: [], produces: "", testCycle: "works correctly" },
    { id: "contra", title: "t", files: [], produces: "", testCycle: "run x" },
    { id: "info", title: "t", files: [], produces: "", testCycle: "run x" },
  ], fileStructure: "f: r" },
  // feasibility lens (JUDGMENT) returns per-task via the label; we key on label.
  "feas:clean": { feasible: "yes", testable: "yes", issues: [] },
  "feas:blocked": { feasible: "no", testable: "yes", issues: [] },
  "feas:untestable": { feasible: "yes", testable: "yes", issues: [] },
  // feasible AND testable both clean — only the contradiction issue blocks it.
  "feas:contra": { feasible: "yes", testable: "yes", issues: [{ kind: "contradiction", detail: "x" }] },
  "feas:info": { feasible: "needs-info", testable: "yes", issues: [] },
  "test:clean": { feasible: "yes", testable: "yes", issues: [] },
  "test:blocked": { feasible: "yes", testable: "yes", issues: [] },
  "test:untestable": { feasible: "yes", testable: "no", issues: [] },
  "test:contra": { feasible: "yes", testable: "yes", issues: [] },
  "test:info": { feasible: "yes", testable: "yes", issues: [] },
};
const BIG_SPEC = "SPEC_SENTINEL_" + "s".repeat(5000);
const NORTH_STAR = "A user who has forgotten their password can set a new one and sign in with it. Missed if: any path needs a support agent.";
const { result: plan, rt: planRt } = await run(WF("plan.js"), { spec: BIG_SPEC, northStar: NORTH_STAR }, planFixtures);
const planCalls = planRt.calls;
const blockedIds = (plan.blocked ?? []).map((b) => b.taskId);
const needsInfoIds = plan.needsInfo ?? [];
ok(blockedIds.includes("blocked"), "plan: feasible=no → blocked");
ok(blockedIds.includes("untestable"), "plan: testable=no alone → blocked");
ok(blockedIds.includes("contra"), "plan: contradiction issue alone → blocked");
ok(needsInfoIds.includes("info"), "plan: feasible=needs-info → needsInfo");
ok(!blockedIds.includes("clean") && !needsInfoIds.includes("clean"), "plan: clean task is neither blocked nor needsInfo");

// A lens that dies resolves its slot to null → feasible/testable are undefined,
// which matches neither "no" nor "needs-info". Before the fix that fell through
// to the implicit "clear" bucket: a task whose vetting never ran reported as
// having PASSED. It must surface as vettingIncomplete instead.
const nullFixtures = {
  decompose: { tasks: [
    { id: "dead", title: "t", files: [], produces: "", testCycle: "run x" },
  ], fileStructure: "f: r" },
  // "feas:dead" deliberately absent → the stub returns null for that label.
  "test:dead": { feasible: "yes", testable: "yes", issues: [] },
};
const { result: nullPlan } = await run(WF("plan.js"), { spec: "s", northStar: NORTH_STAR }, nullFixtures);
ok((nullPlan.vettingIncomplete ?? []).includes("dead"),
  "plan: a lens returning null → vettingIncomplete, NOT clear");
ok(!(nullPlan.blocked ?? []).map((b) => b.taskId).includes("dead"),
  "plan: vetting-incomplete is its own bucket, not conflated with blocked");
// F13: the full spec goes to decompose ONCE; the per-task vet lenses get the
// bounded specExcerpt, never the whole spec (it was re-billed T times at the
// judgment tier — pure duplicate input).
const feasCalls = planCalls.filter((c) => c.label.startsWith("feas:"));
// One feasibility lens per decomposed task — derived, not hardcoded, so adding
// a classification fixture does not silently weaken the F13 assertion.
ok(feasCalls.length === planFixtures.decompose.tasks.length &&
   feasCalls.every((c) => !c.prompt.includes(BIG_SPEC)),
  "plan: feasibility vet prompt does NOT carry the full spec (F13)");
ok(planCalls.find((c) => c.label === "decompose").prompt.includes(BIG_SPEC),
  "plan: decompose (once) is the only full-spec consumer");

// ── plan: the north star is required, and a vague one is refused (#58) ───────
console.log("-- Case: plan.js north star — required, falsifiable, decompose-only");
// Every other input to this workflow is guarded; the one saying what the work is
// FOR used to fall back to a placeholder string and be decomposed as if it were
// a spec. Absent, too short, and no-miss-clause each have their own case,
// because a single disjunction test passes when two of the three branches die.
await throws(() => run(WF("plan.js"), { spec: "s" }, planFixtures),
  "plan northStar: absent → refused, not decomposed as a placeholder", "required");
await throws(() => run(WF("plan.js"), { spec: "s", northStar: 42 }, planFixtures),
  "plan northStar: non-string → refused", "required");
await throws(() => run(WF("plan.js"), { spec: "s", northStar: "   " }, planFixtures),
  "plan northStar: whitespace-only → refused", "required");
await throws(() => run(WF("plan.js"), { spec: "s", northStar: "Make the plugin better." }, planFixtures),
  "plan northStar: a vague one-liner → refused (worse than none — it launders drift as alignment)",
  "cannot be falsifiable");
await throws(() => run(WF("plan.js"), {
    spec: "s",
    northStar: "Users can reset their password and sign in with the new one, end to end, unaided.",
  }, planFixtures),
  "plan northStar: long but with no miss clause → refused", "Missed if");

// The measured decision (tests/fixtures/plan-align/MEASUREMENT.md, 2026-08-18):
// the goal goes to DECOMPOSE and NOT to the per-task vet packets. Putting it
// there drew goal-reachability findings from 6/6 seats against the CONTROL
// column — a plan that reaches its goal — so it is noise bought at judgment
// tier. This is the F13 assertion's shape: pin WHERE an input is spent, because
// nothing else would notice it being spent everywhere.
const nsCalls = planRt.calls;
ok(nsCalls.find((c) => c.label === "decompose").prompt.includes(NORTH_STAR),
  "plan northStar: decompose receives it");
ok(nsCalls.filter((c) => c.label.startsWith("feas:") || c.label.startsWith("test:"))
     .every((c) => !c.prompt.includes(NORTH_STAR)),
  "plan northStar: NO vet lens receives it — measured to be undiscriminating (#58 Stage A)");
ok(plan.northStar === NORTH_STAR,
  "plan northStar: returned to the operator, so the spec-coverage check has a referent");

// ── plan: the graph — edges, layers, Amdahl (#66) ────────────────────────────
console.log("-- Case: plan.js graph — real/unverified edges, concurrency, p + ceiling");
// Arithmetic over produces/consumes, no agent call. EVERY part gets a negative
// control: a check that reports "wide" on a chain launders a guess as a
// measurement, which is worse than not reporting one.
const graphVet = (ids) => Object.fromEntries(
  ids.flatMap((id) => [[`feas:${id}`, { feasible: "yes", testable: "yes", issues: [] }],
                       [`test:${id}`, { feasible: "yes", testable: "yes", issues: [] }]]));
const gtask = (id, produces, consumes) => ({
  id, title: "t", files: ["f.py"], produces, consumes, specExcerpt: "x",
  testCycle: "run x → pass", steps: ["s"],
});

// A: a genuine CHAIN — each task consumes what the one before produces.
const chainIds = ["a", "b", "c", "d"];
const chain = {
  decompose: { fileStructure: "f: r", tasks: [
    gtask("a", "make_alpha() -> str", ""),
    gtask("b", "make_beta() -> str", "make_alpha from a"),
    gtask("c", "make_gamma() -> str", "make_beta from b"),
    gtask("d", "make_delta() -> str", "make_gamma from c"),
  ] },
  ...graphVet(chainIds),
};
const { result: chainPlan } = await run(WF("plan.js"), { spec: "s", northStar: NORTH_STAR }, chain);
const cg = chainPlan.graph;
ok(cg.edges.length === 3 && cg.edges.every((e) => e.status === "real"),
  "plan graph: a real chain reports every declared edge real");
ok(cg.layers.length === 4 && cg.graphWidth === 1,
  "plan graph: NEGATIVE CONTROL — a chain has no concurrency (4 layers, width 1)");
ok(cg.p === 0 && cg.ceiling === 1,
  "plan graph: NEGATIVE CONTROL — a chain reports p=0 and a 1.0x ceiling, not 'wide'");
ok(cg.danglingConsumes.length === 0,
  "plan graph: a chain has no unresolved consumes");

// B: FOUR INDEPENDENT tasks — same shape, none consuming anything.
const wideIds = ["w", "x", "y", "z"];
const wide = {
  decompose: { fileStructure: "f: r", tasks: [
    gtask("w", "make_w() -> str", ""), gtask("x", "make_x() -> str", ""),
    gtask("y", "make_y() -> str", ""), gtask("z", "make_z() -> str", ""),
  ] },
  ...graphVet(wideIds),
};
const { result: widePlan } = await run(WF("plan.js"), { spec: "s", northStar: NORTH_STAR }, wide);
const wg = widePlan.graph;
ok(wg.layers.length === 1 && wg.graphWidth === 4,
  "plan graph: four independent tasks collapse to one layer of width 4");
ok(wg.p === 0.75 && wg.ceiling === 4,
  "plan graph: p and the ceiling move with the graph (p=0.75, 4x), not a constant");
ok(wg.edges.length === 3 && wg.edges.every((e) => e.status === "unverified"),
  "plan graph: declared order with no named dependency → unverified, the spurious-serialisation signal");
ok((widePlan.blocked ?? []).length === 0 && (widePlan.needsInfo ?? []).length === 0,
  "plan graph: POLARITY — unverified edges REPORT, they never block a plan (#21's class)");

// C: the dangling consumes #73 measured — a task naming a producer nobody ships.
const dangIds = ["m", "n"];
const dang = {
  decompose: { fileStructure: "f: r", tasks: [
    gtask("m", "make_m() -> str", ""),
    gtask("n", "make_n() -> str", "never_produced_anywhere from q.py"),
  ] },
  ...graphVet(dangIds),
};
const { result: dangPlan } = await run(WF("plan.js"), { spec: "s", northStar: NORTH_STAR }, dang);
ok(dangPlan.graph.danglingConsumes.includes("n"),
  "plan graph: a consumes naming nothing any earlier task produces is reported (#73's question, computed)");
ok(!dangPlan.graph.danglingConsumes.includes("m"),
  "plan graph: NEGATIVE CONTROL — an empty consumes is not a dangling one");
ok((dangPlan.blocked ?? []).length === 0,
  "plan graph: POLARITY — a dangling consumes reports, it does not block");

// D: the arithmetic itself, against the issue's own worked numbers.
// All three, because a single point passes against a table that is right once.
// The k=16 value is the sobering one the issue is about: p=0.75 with 16 workers
// buys 3.37x, not 16x, and the serial tail is the cap.
ok(wg.speedupAt["2"] === 1.6 && wg.speedupAt["4"] === 2.29 && wg.speedupAt["16"] === 3.37,
  "plan graph: S = 1/((1-p) + p/k) at k=2/4/16 → 1.6x / 2.29x / 3.37x, computed not asserted");
ok(typeof cg.dispatchBound === "string" && cg.dispatchBound.includes("CHART-r6"),
  "plan graph: the width is reported WITH the charter bound — one implementer at a time");
ok(!planCalls.some((c) => c.label.startsWith("graph")),
  "plan graph: no agent call — it is arithmetic over data the workflow already holds");

// E: degenerate shapes. The graph runs on whatever the decomposer returned, and
// a decomposer is a model — duplicate ids, a task consuming its own output, and
// a back-reference are all things it can emit. None may throw (that would take
// down a plan over a report) and none may reach blocked/needsInfo. Cycles are
// impossible BY CONSTRUCTION, not by a check: dependsOn scans only tasks EARLIER
// in the list, so the relation is a DAG whatever the text says — the
// back-reference case is what proves that rather than asserting it.
for (const [label, degen] of Object.entries({
  "a single task": [gtask("solo", "make_solo() -> str", "")],
  "duplicate task ids": [gtask("dup", "make_x() -> str", ""), gtask("dup", "make_y() -> str", "make_x from dup")],
  "a task consuming its own output": [gtask("s", "make_s() -> str", "make_s from s")],
  "a back-reference to a later task": [gtask("p", "make_p() -> str", "make_q from q"),
                                       gtask("q", "make_q() -> str", "make_p from p")],
  "no produces anywhere": [gtask("n1", "", ""), gtask("n2", "", "")],
  "punctuation-only contract text": [gtask("u", "→ ✓ ---", "→ ✓ ---")],
})) {
  const fx = { decompose: { fileStructure: "f", tasks: degen }, ...graphVet(degen.map((t) => t.id)) };
  let res = null, threw = null;
  try { ({ result: res } = await run(WF("plan.js"), { spec: "s", northStar: NORTH_STAR }, fx)); }
  catch (e) { threw = e; }
  ok(!threw && res?.graph, `plan graph: ${label} does not throw`);
  ok((res?.blocked ?? []).length === 0 && (res?.needsInfo ?? []).length === 0,
    `plan graph: ${label} reaches neither blocked nor needsInfo (report-only holds)`);
  ok(Number.isFinite(res?.graph?.p) && Number.isFinite(res?.graph?.ceiling) && res.graph.ceiling >= 1,
    `plan graph: ${label} yields finite p and a ceiling >= 1`);
}

// ── crawl: shard fan-out + merge ─────────────────────────────────────────────
console.log("-- Case: crawl.js shard fan-out + merge");
// The operator packs shards; the workflow dispatches one crawler per shard, then
// one merge. Assert: N shards → N crawler calls (labels shard i/N), exactly one
// merge call, and the result carries the merged findings/gaps. Also: no shards
// → an error return (the operator must pack them; the workflow has no fs).
const crawlFixtures = {
  // every shard gets the same canned digest; the merge returns a merged shape.
  // (the stub keys on label; shard labels are "shard 1/3" etc.)
  merge: { findings: [{ fact: "merged", inferred: false }], gaps: [] },
};
// Override: return a shard digest for any "shard i/N" label, merge for "merge".
const fs2 = await import("node:fs");
const crawlSrc = fs2.readFileSync(new URL(WF("crawl.js")), "utf8").replace(/\bexport\s+const\s+meta\b/, "const meta");
const crawlFn = new Function("args", "agent", "parallel", "pipeline", "phase", "log",
  `return (async () => {\n${crawlSrc}\n})();`);
const crawlCalls = [];
const crawlAgent = async (p, o = {}) => {
  crawlCalls.push(o.label);
  if (o.label === "merge") return crawlFixtures.merge;
  return { shard: ["a:1"], findings: [{ fact: "f" + o.label, inferred: false }], gaps: [] };
};
const crawlRes = await crawlFn(
  { question: "how does auth work", shards: [{ paths: ["a"] }, { paths: ["b"] }, { paths: ["c"] }] },
  crawlAgent, makeRuntime().parallel, makeRuntime().pipeline, () => {}, () => {},
);
const shardCalls = crawlCalls.filter((l) => l?.startsWith("shard")).length;
ok(shardCalls === 3, "crawl: 3 shards → 3 crawler dispatches (one per shard)");
ok(crawlCalls.filter((l) => l === "merge").length === 1, "crawl: exactly one merge dispatch");
ok((crawlRes.shardsRequested ?? 0) === 3 && (crawlRes.shardsReturned ?? 0) === 3,
  "crawl: reports shardsRequested/shardsReturned");
ok(Array.isArray(crawlRes.findings) && crawlRes.findings.length === 1,
  "crawl: returns the merged findings");
// no shards → error, not a crash
const noShard = await crawlFn({ question: "x" }, crawlAgent, makeRuntime().parallel, makeRuntime().pipeline, () => {}, () => {});
ok(noShard?.error && /no shards/.test(noShard.error), "crawl: no args.shards → error return (workflow has no fs to pack them)");

// ── F32: a dead TERMINAL single agent must not read as a clean result ────────
console.log("-- Case: dead terminal agents fail loud, not clean (F32)");
// The fan-out accounting (deadLenses, vettingIncomplete) covers agents that die
// mid-fan-out; these cover the single judgment call each workflow ENDS on. The
// stub returns null for any label without a fixture — the same null a schema
// mismatch, timeout, or rate limit produces in production.

// review: the adversarial verifier dies → the gate must fail CLOSED. null and
// CONFIRMED both made `adversarial?.verdict === "REFUTED"` false, so a
// verification that never ran read as a pass.
const { result: deadAdv } = await run(WF("review.js"), "docs/x.md", everyLens);
ok(deadAdv.blocked === true, "review: dead adversarial → blocked (fails closed, not open)");
ok(deadAdv.unverified === true, "review: dead adversarial is named `unverified`, distinct from REFUTED");
const { result: liveAdv } = await run(WF("review.js"), "docs/x.md",
  { ...everyLens, adversarial: { verdict: "CONFIRMED", evidence: "ran x, saw y" } });
ok(liveAdv.blocked === false && liveAdv.unverified === undefined,
  "review: CONFIRMED adversarial → not blocked, not unverified");

// crawl: the merge dies → error return CARRYING the shard digests (the paid
// crawl work), never findings:[] masquerading as "nothing relevant found".
const deadMerge = await crawlFn(
  { question: "q", shards: [{ paths: ["a"] }, { paths: ["b"] }] },
  async (p, o = {}) => o.label === "merge"
    ? null
    : { shard: ["a:1"], findings: [{ fact: "f", inferred: false }], gaps: [] },
  makeRuntime().parallel, makeRuntime().pipeline, () => {}, () => {},
);
ok(deadMerge?.error && /merge agent died/.test(deadMerge.error),
  "crawl: dead merge → error return, not a clean-empty result");
ok(Array.isArray(deadMerge?.digests) && deadMerge.digests.length === 2,
  "crawl: dead-merge error carries the shard digests (re-merge, don't re-crawl)");

// brainstorm: the converge dies → error return carrying the divergent work.
const { result: deadConv } = await run(WF("brainstorm.js"), { topic: "t", noReferences: true },
  Object.fromEntries([1, 2, 3, 4].map((i) =>
    [`direction ${i}/4`, { stance: "s", sketch: "k", tradeoffs: [], yagnis: "y" }])
    .concat([["blindspots", { findings: [] }]])));
ok(deadConv?.error && /converge agent died/.test(deadConv.error),
  "brainstorm: dead converge → error return, not bundle:null");
ok(Array.isArray(deadConv?.directions) && deadConv.directions.length === 4,
  "brainstorm: dead-converge error carries the surviving directions");

// brainstorm: the BLINDSPOTS scan dies → must not launder into `[]` ("nothing
// to account for"). The whole point of the lens is to surface existing
// abstractions the design would duplicate; a dead scan returning a clean empty
// omits all of them silently. Same F31/F32 class, and the adjacent `references`
// lens already signals via .catch+log — blindspots was the one direct agent()
// in divergence with no null guard (pr-review silent-failure hunt, 2026-08-03).
// Stub every lens LIVE except blindspots: a dead blindspots must surface an
// error even when everything else succeeds.
const { result: deadBlind } = await run(WF("brainstorm.js"), { topic: "t", noReferences: true },
  Object.fromEntries([1, 2, 3, 4].map((i) =>
    [`direction ${i}/4`, { stance: "s", sketch: "k", tradeoffs: [], yagnis: "y" }])
    .concat([["converge", { ranked: [], sharedConstraints: [], openQuestions: [] }]])));
ok(deadBlind?.error && /blindspots agent died/.test(deadBlind.error),
  "brainstorm: dead blindspots → error return, not findings:[] masquerading as 'nothing to account for'");
ok(Array.isArray(deadBlind?.directions) && deadBlind.directions.length === 4,
  "brainstorm: the dead-blindspots error return carries the computed directions " +
  "(the message says 'directions below are intact' — they must actually be below)");

// ── #23 (U11): the adversarial seat's execution environment ─────────────────
console.log("-- Case: review.js adversarial isolation (#23)");
// MEASURED: a stale gitignored artifact makes a broken assertion pass in the
// builder's tree and fail in a worktree of the same commit, while F-A1's
// `git status --porcelain` reports CLEAN — porcelain describes the TRACKED tree
// and the contaminant is ignored. These cases pin the three properties that
// distinguish a real fix from a flag that reads like one.
const liveAdvReturn = { adversarial: { verdict: "CONFIRMED", evidence: "ran x, saw y" } };
const isoAdvCall = (rt) => rt.calls.find((c) => c.label === "adversarial");

// 1. Default OFF. Cost is per-dispatch, so every existing caller keeps today's
//    behaviour and today's (weaker, correctly-labelled) claim.
const { result: plainRes, rt: plainIso } = await run(WF("review.js"), "docs/x.md",
  { ...everyLens, ...liveAdvReturn });
ok(isoAdvCall(plainIso).isolation === undefined,
  "review/#23: no args.isolate → the adversarial seat runs in the builder's tree (opt-in, not default)");
ok(plainRes.isolation?.mode === "builder-tree" && plainRes.isolation.requestedCommit === null,
  "review/#23: an un-isolated result SAYS builder-tree — the weaker claim is labelled as such");
ok(/BUILDER'S ENVIRONMENT/.test(plainRes.isolation.bound),
  "review/#23: the un-isolated bound names what the verdict actually describes");
ok(isoAdvCall(plainIso).prompt.includes("F-A1 tree check"),
  "review/#23: un-isolated, F-A1 porcelain check still ships");

// 2. With a sha: the flag reaches agent(), and F-A1 is REPLACED rather than
//    joined. In a fresh worktree porcelain is empty by construction, so keeping
//    F-A1 there would ship a control that cannot fail (#21's vacuous class).
const SHA = "a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0";
const { result: isoRes, rt: isoRt } = await run(WF("review.js"),
  { target: "docs/x.md", isolate: SHA }, { ...everyLens, ...liveAdvReturn });
ok(isoAdvCall(isoRt).isolation === "worktree",
  "review/#23: args.isolate=<sha> passes isolation:'worktree' to the adversarial agent() call");
ok(isoAdvCall(isoRt).prompt.includes(SHA) && isoAdvCall(isoRt).prompt.includes("git rev-parse HEAD"),
  "review/#23: the seat is told to re-derive HEAD in its own tree and compare to the named sha");
ok(!isoAdvCall(isoRt).prompt.includes("F-A1 tree check"),
  "review/#23: under isolation F-A1 is REPLACED, not joined — porcelain cannot fail in a fresh worktree");
ok(/NOT full isolation/.test(isoAdvCall(isoRt).prompt),
  "review/#23: the prompt states the bound (same $HOME, caches, PATH) rather than overclaiming");
ok(isoRes.isolation?.mode === "worktree" && isoRes.isolation.requestedCommit === SHA,
  "review/#23: the result names the REQUESTED commit, under a key that says so");
// The field must NOT be called `commit`: nothing in review.js observes where the
// seat ran, so on a REFUTED (which is exactly what an identity mismatch yields)
// a bare `commit` would label the verdict with a sha the run may never have been
// at — the overclaim the field exists to prevent, reintroduced by naming.
ok(isoRes.isolation?.commit === undefined && "requestedCommit" in isoRes.isolation,
  "review/#23: the field is requestedCommit, not commit — it reports the ASK, not an observation");
ok(isoRes.isolation?.observedCommit === null && /adversarial\.evidence/.test(isoRes.isolation.bound),
  "review/#23: observedCommit is null and the bound points at where the real HEAD is recorded");
// The lenses are NOT isolated: they read the artifact under review, which is
// the working tree the operator asked about. Isolation is the verifier's
// property alone, and a blanket flag would silently change what the panel sees.
ok(isoRt.calls.filter((c) => c.label.startsWith("lens:")).every((c) => c.isolation === undefined),
  "review/#23: the panel lenses stay un-isolated — only the adversarial seat moves");

// 3. Guards. `true` is the silent-wrong case the issue named: an isolated run
//    with no named commit verifies whatever HEAD happens to be and reports
//    CONFIRMED about a tree nobody chose.
await throws(() => run(WF("review.js"), { target: "docs/x.md", isolate: true }, everyLens),
  "review/#23: args.isolate=true is refused — isolation without a named commit is silent-wrong",
  "not `true`");
await throws(() => run(WF("review.js"), { target: "docs/x.md", isolate: "HEAD" }, everyLens),
  "review/#23: a ref name is not a sha — refused", "is not a commit sha");
await throws(() => run(WF("review.js"), { target: "docs/x.md", isolate: 42 }, everyLens),
  "review/#23: a non-string isolate is refused", "must be a commit sha string");
const { rt: offRt } = await run(WF("review.js"), { target: "docs/x.md", isolate: false },
  { ...everyLens, ...liveAdvReturn });
ok(isoAdvCall(offRt).isolation === undefined,
  "review/#23: isolate:false is an explicit opt-out, not a validation error");

// ── F37: an array target must review what was passed, or fail loud ──────────
console.log("-- Case: review.js multi-path target (F37)");
// meta.whenToUse promises "Pass the artifact path(s)" and the normalizer
// explicitly JSON-parses a leading `[`, but `typeof A === "string"` then fell
// through to the "the working diff" default: the panel reviewed something
// OTHER than what was passed, with no error. Silent-wrong is the worst of the
// three possible behaviours (right / loud-wrong / silent-wrong).
const arrRt = (await run(WF("review.js"), JSON.stringify(["docs/a.md", "docs/b.md"]), everyLens)).rt;
const arrPrompt = arrRt.calls.find((c) => c.label.startsWith("lens:")).prompt;
ok(arrPrompt.includes("docs/a.md") && arrPrompt.includes("docs/b.md"),
  "review: an array target reaches the lens prompt (both paths)");
ok(!arrPrompt.includes("the working diff"),
  "review: an array target does NOT silently degrade to the working-diff default");
const oneRt = (await run(WF("review.js"), JSON.stringify(["docs/only.md"]), everyLens)).rt;
ok(oneRt.calls.find((c) => c.label.startsWith("lens:")).prompt.includes("ARTIFACT: docs/only.md\n"),
  "review: a single-element array is rendered exactly like a bare path");
// A malformed array is a caller error: reject it rather than review the wrong
// thing. Loud-wrong beats silent-wrong.
await throws(() => run(WF("review.js"), JSON.stringify([]), everyLens),
  "review: an empty array target is rejected, not defaulted", "is an empty array");
await throws(() => run(WF("review.js"), JSON.stringify(["docs/a.md", 42]), everyLens),
  "review: a non-string array element is rejected", "must be a path or an array");
// The object form may carry an array too — same contract.
const objArrRt = (await run(WF("review.js"), { target: ["docs/x.md", "docs/y.md"] }, everyLens)).rt;
ok(objArrRt.calls.find((c) => c.label.startsWith("lens:")).prompt.includes("docs/y.md"),
  "review: args.target as an array is honored, same as the bare form");

// ── F38: the lenses that ask about the task text must RECEIVE it ────────────
console.log("-- Case: review.js lens context (F38)");
// spec asks "what the task text asked for" and testability asks "for each
// stated requirement" — but doneMeans went only to the adversarial seat, so
// both were structurally forced into op-reviewer.md's NEEDS_CONTEXT branch.
// Measured live: the spec lens returned one finding, score 0, saying exactly
// that. A paid dispatch that cannot answer its own question.
const dmRt = (await run(WF("review.js"),
  { target: "docs/x.md", doneMeans: "DONEMEANS_SENTINEL: ships a --json flag" }, everyLens)).rt;
const byLens = Object.fromEntries(
  dmRt.calls.filter((c) => c.label.startsWith("lens:")).map((c) => [c.label.slice(5), c.prompt]));
for (const k of ["spec", "testability"]) {
  ok(byLens[k].includes("DONEMEANS_SENTINEL"),
    `review: the ${k} lens receives the task text it asks about (F38)`);
}
for (const k of ["quality", "correctness"]) {
  ok(!byLens[k].includes("DONEMEANS_SENTINEL"),
    `review: the ${k} lens does NOT carry the task text (it never asks about it)`);
}
// No doneMeans passed → no dangling empty header in any prompt.
const noDmRt = (await run(WF("review.js"), "docs/x.md", everyLens)).rt;
ok(!noDmRt.calls.some((c) => /TASK TEXT:\s*\n/.test(c.prompt)),
  "review: an absent doneMeans emits no empty TASK TEXT header");

// ── F41: doneMeans is validated like target ─────────────────────────────────
// doneMeans gets target's guard: it was unvalidated where target now is, so a
// non-string rendered "TASK TEXT: [object Object]" into the two lenses that
// ask about it — silent-wrong, the class F37 fixed one field over.
for (const badDm of [{ x: 1 }, ["a"], 42, true]) {
  await throws(() => run(WF("review.js"), { target: "docs/x.md", doneMeans: badDm }, everyLens),
    `review: doneMeans=${JSON.stringify(badDm)} throws rather than stringifying into the prompt`,
    "must be a string");
}
// Whitespace-only is absence, not a header: an empty TASK TEXT starves the
// same two lenses it was meant to feed.
const wsDmRt = (await run(WF("review.js"),
  { target: "docs/x.md", doneMeans: "   \n  " }, everyLens)).rt;
ok(!wsDmRt.calls.some((c) => /TASK TEXT:/.test(c.prompt)),
  "review: a whitespace-only doneMeans is treated as absent, not as an empty header");

// ── F-A1: the adversarial verifier carries the tree-check refutation target ─
console.log("-- Case: review.js adversarial tree-check target (F-A1)");
// The verifier is an AGENT (it touches disk), so it can confirm the working
// tree holds no changes beyond the reviewed artifact — the read-only-seat write
// boundary that prompt-level tool lists don't enforce. The target is a string
// in the adversarial prompt; a worker touching files outside the artifact must
// be a REFUTED basis. Assert the prompt carries it (F40-style, against the call).
const advRt = (await run(WF("review.js"), "docs/x.md", everyLens)).rt;
const advCall = advRt.calls.find((c) => c.label === "adversarial");
ok(advCall && /tree check|working tree|beyond the reviewed/i.test(advCall.prompt),
  "review: the adversarial prompt carries the F-A1 tree-check refutation target");

// ── F39: a malformed verdict is not a passing verdict ───────────────────────
console.log("-- Case: review.js malformed adversarial verdict (F39)");
// F32 made `adversarial == null` fail closed, but a NON-null malformed object
// ({} or {verdict:"MAYBE"}) still yielded blocked:false — the same value a
// CONFIRMED produces. The fix leaned entirely on the harness turning schema
// violations into null; that is a narrower guarantee than "fails closed".
for (const [label, adv] of [["{}", {}], ['{verdict:"MAYBE"}', { verdict: "MAYBE" }],
                            ['{verdict:""}', { verdict: "" }]]) {
  const r = (await run(WF("review.js"), "docs/x.md", { ...everyLens, adversarial: adv })).result;
  ok(r.blocked === true && r.unverified === true,
    `review: a malformed verdict ${label} is unverified + blocked, not a pass`);
}
const refuted = (await run(WF("review.js"), "docs/x.md",
  { ...everyLens, adversarial: { verdict: "REFUTED", evidence: "e" } })).result;
ok(refuted.blocked === true && refuted.unverified === undefined,
  "review: REFUTED blocks but is NOT unverified (a real verdict was returned)");

// ── F40: meta must not misstate what a dispatch costs ───────────────────────
console.log("-- Case: review.js cost contract (F40)");
// meta advertised "narrow lenses at cheap tiers" while 2 of 5 dispatch at
// JUDGMENT — the cost shown in the tool picker was wrong. Assert the text
// against the LENSES table itself so the two cannot drift apart again.
const metaSrc = (await import("node:fs")).readFileSync(new URL(WF("review.js")), "utf8");
const judgmentLenses = (metaSrc.match(/tier:\s*JUDGMENT/g) ?? []).length;
const metaBlock = metaSrc.slice(0, metaSrc.indexOf("};"));
// The panel's own cost must be described honestly. "cheap tiers" UNQUALIFIED is
// the lie (2 of 5 lenses are JUDGMENT); "most at cheap tiers and two at
// judgment tier" is the truth, so the check is for an unhedged claim, not for
// the substring. `phases[].detail` is what the tool picker shows, so it must
// not say "cheap tiers" flatly either.
const unhedgedCheap = /(?<!most |mixed )(?:at |, )cheap tiers(?! and)/.test(metaBlock);
ok(judgmentLenses > 0 && /judgment/i.test(metaBlock) && !unhedgedCheap,
  "review: meta does not claim 'cheap tiers' while lenses dispatch at JUDGMENT (F40)");

// The check above is the SHAPE half of the contract and was the whole of it
// until a review panel repro'd the gap: flipping `correctness` to JUDGMENT
// makes 3 of 5 lenses judgment-tier while meta still advertises "two", and the
// suite stayed green at 63/63. `judgmentLenses > 0` is the only table-derived
// assertion there, so the COUNT meta states was free to go stale. Bind the
// spelled number in meta to the table, and "most" to the actual majority.
const NUMBER_WORD = { one: 1, two: 2, three: 3, four: 4, five: 5, six: 6 };
const mechanicalLenses = (metaSrc.match(/tier:\s*MECHANICAL/g) ?? []).length;
const claimedJudgment = metaBlock.match(/\b(one|two|three|four|five|six)\b\s+at\s+judgment\s+tier/i);
ok(claimedJudgment != null && NUMBER_WORD[claimedJudgment[1].toLowerCase()] === judgmentLenses,
  `review: meta's judgment-lens COUNT matches the LENSES table (F40; meta says ${claimedJudgment?.[1] ?? "nothing"}, table has ${judgmentLenses})`);
ok(!/\bmost at cheap tiers\b/.test(metaBlock) || mechanicalLenses > judgmentLenses,
  `review: meta's "most at cheap tiers" holds against the table (F40; ${mechanicalLenses} cheap vs ${judgmentLenses} judgment)`);

// ── the id guard is APPLIED in every workflow (#60) ─────────────────────────
// The static pin (validate_plugin.check_workflows) compares the BAD_CHARSET
// literal across the copies, so it sees any change to the regex TEXT — but it
// cannot see a correct regex that is never applied (the F30 vacuity shape).
// Measured on the pre-change pair of guards: neutering a call site to
// `false && …` left the static pin at 0 findings, and the runtime caught it
// ONLY where an assertion existed (brainstorm 77/2, review 79/0). Three of the
// four workflows had nothing covering it — a workflow whose guard does nothing
// shipped with every gate green.
//
// That matters more now, not less: 0.8.3 removed the id-shape catalogue, so
// BAD_CHARSET is the ONLY id guard left. There is no second regex to catch what
// a neutered call site lets through.
//
// One assertion per file, each exercising that file's own call site: a shared
// helper looping over them would pass with all but one deleted.
await throws(() => run(WF("review.js"), { tiers: { MECHANICAL: "not routable" } }, {}),
  "review tier: charset-bad id rejected — the guard is applied, not merely present (#60)", "outside the");
await throws(() => run(WF("crawl.js"), { tiers: { MECHANICAL: "not routable" }, shards: ["x"] }, {}),
  "crawl tier: charset-bad id rejected — the guard is applied, not merely present (#60)", "outside the");
await throws(() => run(WF("plan.js"), { tiers: { MECHANICAL: "not routable" }, spec: "s", northStar: NORTH_STAR }, {}),
  "plan tier: charset-bad id rejected — the guard is applied, not merely present (#60)", "outside the");

// ── dispatch: one seat, one model (#55) ─────────────────────────────────────
console.log("-- Case: dispatch.js routes a seat to a caller-supplied model (#55)");
// The gap this closes: the plain Agent tool's `model` parameter is enum-locked
// to sonnet|opus|haiku|fable, so a cc-proxy id is rejected BEFORE dispatch and
// a seat cannot run on its configured tier without rendering. This workflow is
// the one route by which a resolved id reaches a seat at all.
const DISPATCH_OK = { "dispatch:mechanic": { ok: true } };

// The two things that must BOTH be right, asserted on the actual call opts
// rather than on the return value: the seat picks the agentType, and the
// caller's id survives to `model`. Either alone is not the feature.
const { rt: dRt } = await run(WF("dispatch.js"),
  { seat: "mechanic", prompt: "do the thing", model: "deepseek:deepseek-v4-flash" },
  DISPATCH_OK);
const dCall = dRt.calls.find((c) => c.label === "dispatch:mechanic");
ok(dCall?.model === "deepseek:deepseek-v4-flash",
  "dispatch: the caller's model id reaches the agent call (the whole point of #55)");
ok(dCall?.prompt === "do the thing",
  "dispatch: the prompt reaches the seat unmodified");
// A second seat, so the case cannot pass against a hardcoded agentType.
const { rt: dRt2 } = await run(WF("dispatch.js"),
  { seat: "scout", prompt: "find it", model: "glm-5-turbo" },
  { "dispatch:scout": { ok: true } });
ok(dRt2.calls.find((c) => c.label === "dispatch:scout")?.model === "glm-5-turbo",
  "dispatch: a second seat routes independently (not a hardcoded pair)");
// The `op-` prefix is optional everywhere else in this project; a caller
// copying a name out of an agent filename must not be refused.
const { rt: dRt3 } = await run(WF("dispatch.js"),
  { seat: "op-mechanic", prompt: "p", model: "glm-5-turbo" }, DISPATCH_OK);
ok(dRt3.calls.some((c) => c.label === "dispatch:mechanic"),
  "dispatch: the 'op-' prefix is optional, as in tiers.env and --model");

// The caller-supplied id gets the SAME guard as a tiers.env binding — no more
// and no less. Less makes this workflow a bypass around check_routable; more
// makes it the one place that second-guesses the caller's model choice.
await throws(() => run(WF("dispatch.js"),
  { seat: "mechanic", prompt: "p", model: "not routable" }, DISPATCH_OK),
  "dispatch: a charset-bad args.model is rejected", "outside the");
await throws(() => run(WF("dispatch.js"),
  { seat: "mechanic", prompt: "p", model: 'glm-5"q' }, DISPATCH_OK),
  "dispatch: a quote-bearing args.model is rejected", "outside the");
// ...and the inverse, which is the 0.8.3 correction: an id operator does not
// recognise DISPATCHES. `bogus:vendor/model` was the headline reject here until
// the guard learned it was not operator's call; `deepseek-v4-flash` is a real
// id the old shape catalogue refused. Both must reach agent() untouched.
for (const id of ["bogus:vendor/model", "deepseek-v4-flash", "qwen3.8-max"]) {
  const { rt } = await run(WF("dispatch.js"),
    { seat: "mechanic", prompt: "p", model: id }, DISPATCH_OK);
  ok(rt.calls.some((c) => c.model === id),
    `dispatch: unrecognised-but-well-formed id ${JSON.stringify(id)} reaches agent() (0.8.3)`);
}
// An unknown seat must REFUSE, not fall through to some default agentType:
// args.seat is caller input, and without the literal table it would become an
// arbitrary agentType string.
await throws(() => run(WF("dispatch.js"),
  { seat: "nosuchseat", prompt: "p", model: "glm-5-turbo" }, {}),
  "dispatch: an unknown seat is refused, never coerced into an agentType",
  "unknown seat");
// A prototype-chain name must be refused like any other unknown seat. SEATS is
// a plain object literal, so a bare `SEATS[seat]` returns a truthy native
// function for `constructor`/`toString`/`valueOf`/`hasOwnProperty`/`__proto__`
// — sailing past the `!agentType` guard and reaching agent() as a function
// instead of a string. Found by review after 0.8.3; the file's own comment
// claims the table BOUNDS what a caller can dispatch, so the bound has to hold
// for every string a caller can send, not just for the ones that look like
// seats. Each name is asserted separately: `__proto__` resolves to an object
// rather than a function and would survive a typeof-based fix.
for (const evil of ["constructor", "toString", "valueOf", "hasOwnProperty", "__proto__"]) {
  await throws(() => run(WF("dispatch.js"),
    { seat: evil, prompt: "p", model: "glm-5-turbo" }, {}),
    `dispatch: prototype-chain seat ${JSON.stringify(evil)} is refused, not dispatched`,
    "unknown seat");
}
await throws(() => run(WF("dispatch.js"), { prompt: "p", model: "glm-5-turbo" }, {}),
  "dispatch: a missing seat is refused", "must be a seat name");
await throws(() => run(WF("dispatch.js"), { seat: "mechanic", model: "glm-5-turbo" }, {}),
  "dispatch: an empty prompt is refused (a paid seat with no task)",
  "must be a non-empty string");

// No args.model: falls back to a tier default rather than throwing, and SAYS
// SO. A silent fallback is how a caller who meant to pass a binding never finds
// out they dispatched on something else.
const { result: dFall, rt: dFallRt } = await run(WF("dispatch.js"),
  { seat: "mechanic", prompt: "p" }, DISPATCH_OK);
ok(dFall?.model === "claude-opus-5",
  "dispatch: no args.model falls back to the JUDGMENT tier default");
// The command it names must be one a user can actually TYPE. It used to say
// `ops-render.sh --model <seat>`, which is neither installed into
// .operator/bin/ (only the five gate CLIs are) nor reachable via
// ${CLAUDE_PLUGIN_ROOT} in the Bash tool env (#62) — a Copilot review of this
// PR caught the fallback pointing at a command that does not exist in a
// project shell. Pin the seat name too: naming the wrong seat is as useless as
// naming no command.
ok(dFallRt.logs.some((m) => /no args\.model given/.test(m)
    && /\/cc-operator:tiers/.test(m) && /mechanic/.test(m)),
  "dispatch: the fallback is LOGGED and names a command a user can actually run");

// A dead agent returns null. Reporting that as a result would let a caller read
// "the seat ran and said nothing" from "the seat never ran" — the fail-open
// shape review.js's dead-lens accounting exists to close.
const { result: dDead } = await run(WF("dispatch.js"),
  { seat: "mechanic", prompt: "p", model: "glm-5-turbo" }, {});
ok(dDead?.dead === true && /agent died/.test(dDead?.error ?? ""),
  "dispatch: a dead agent is reported as dead, not as an empty result");
ok(dDead?.result === undefined,
  "dispatch: a dead agent carries no `result` key a caller could read as output");

console.log(`\n== summary: ${pass} passed, ${fail} failed ==`);
if (fail > 0) process.exit(1);
