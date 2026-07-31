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
const throws = async (fn, msg) => {
  try { await fn(); ok(false, `${msg} (expected throw, got none)`); }
  catch { ok(true, msg); }
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
    calls.push({ label, model: opts.model });
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
  const log = () => {};
  return { agent, parallel, pipeline, phase, log, calls };
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
// charset rejected; unroutable rejected. Each is a top-level throw, so the
// workflow aborts before any agent call.
await throws(() => run(WF("brainstorm.js"), { tiers: { Mechanical: "glm-5" } }, {}),
  "brainstorm tier: typo 'Mechanical' rejected (F07 typo guard)");
await throws(() => run(WF("brainstorm.js"), { tiers: { MECHANICAL: "glm 5" } }, {}),
  "brainstorm tier: whitespace in id rejected (F01 charset)");
await throws(() => run(WF("brainstorm.js"), { tiers: { MECHANICAL: "not-routable" } }, {}),
  "brainstorm tier: unroutable id rejected");
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

// ── plan: decomposition + vet classification ────────────────────────────────
console.log("-- Case: plan.js vet classification (blocked / needs-info / clear)");
// Stub decompose to return 2 tasks; vet lenses return feasible/testable/issues.
// Assert the workflow classifies a 'no' feasibility as blocked, 'needs-info' as
// needsInfo, and clean as neither.
const planFixtures = {
  decompose: { tasks: [
    { id: "clean", title: "t", files: [], produces: "", testCycle: "run x → pass" },
    { id: "blocked", title: "t", files: [], produces: "", testCycle: "run x" },
    { id: "info", title: "t", files: [], produces: "", testCycle: "run x" },
  ], fileStructure: "f: r" },
  // feasibility lens (JUDGMENT) returns per-task via the label; we key on label.
  "feas:clean": { feasible: "yes", testable: "yes", issues: [] },
  "feas:blocked": { feasible: "no", testable: "yes", issues: [{ kind: "contradiction", detail: "x" }] },
  "feas:info": { feasible: "needs-info", testable: "yes", issues: [] },
  "test:clean": { feasible: "yes", testable: "yes", issues: [] },
  "test:blocked": { feasible: "yes", testable: "yes", issues: [] },
  "test:info": { feasible: "yes", testable: "yes", issues: [] },
};
const { result: plan } = await run(WF("plan.js"), { spec: "s" }, planFixtures);
const blockedIds = (plan.blocked ?? []).map((b) => b.taskId);
const needsInfoIds = plan.needsInfo ?? [];
ok(blockedIds.includes("blocked"), "plan: feasible=no (or contradiction) → blocked");
ok(needsInfoIds.includes("info"), "plan: feasible=needs-info → needsInfo");
ok(!blockedIds.includes("clean") && !needsInfoIds.includes("clean"), "plan: clean task is neither blocked nor needsInfo");

console.log(`\n== summary: ${pass} passed, ${fail} failed ==`);
if (fail > 0) process.exit(1);
