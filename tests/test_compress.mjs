// tests/test_compress.mjs — replay tests for the input-axis compressor.
//
// The spec (docs/spec/input-axis-compressor.md, "Validator guardrails" §3) names
// these cases; this file is that list, executable. Every assertion is against a
// PINNED default, never a tilde — "a test against a tilde is not a test"
// (audit F25/F27). The pinned numbers live in ONE place, scripts/ops-compress.mjs,
// and are read from there rather than restated here.
//
// Run:  node tests/test_compress.mjs   (exit 0 iff all pass)

import path from "node:path";
import fs from "node:fs";
import os from "node:os";
import { pathToFileURL } from "node:url";

const ROOT = path.resolve(import.meta.dirname, "..");
const MOD = pathToFileURL(path.join(ROOT, "scripts", "ops-compress.mjs")).href;
const { compress, DEFAULTS } = await import(MOD);

let pass = 0, fail = 0;
const ok = (cond, msg) => {
  if (cond) { pass++; console.log(`  ok   ${msg}`); }
  else { fail++; console.log(`  FAIL ${msg}`); }
};

// A scratch project so spill files never touch the real tree.
const TMP = fs.mkdtempSync(path.join(os.tmpdir(), "opscompress-"));
fs.mkdirSync(path.join(TMP, ".operator"), { recursive: true });

// `compress` is pure w.r.t. its inputs: it takes the hook payload and an env
// override map, and returns either null (skip — emit nothing) or the
// hookSpecificOutput object. No process.env reads inside, so a test never has
// to mutate global state to pin a tunable.
const run = (payload, env = {}) => compress(payload, { env, cwd: TMP });

// Each case gets a FRESH session id. Dedup is stateful per (session, tool), so
// two cases reusing one session make the second hit the dedup marker instead of
// the tier under test — which is a bug in the TEST, and it bit exactly once here
// (the spill case silently measured dedup). Isolation is not optional for a
// stateful tier.
let sessN = 0;
const bash = (stdout, extra = {}) => ({
  tool_name: "Bash",
  tool_use_id: "toolu_test",
  session_id: `SESS-T${++sessN}`,
  tool_response: { stdout, stderr: "", ...extra },
});

// ── I1: allowlist, never blocklist ──────────────────────────────────────────
console.log("-- Case: I1 allowlist (excluded tools are never mutated)");
const big = "x".repeat(50000);
for (const t of ["Read", "Edit", "Write", "NotebookEdit"]) {
  ok(run({ tool_name: t, tool_use_id: "t", session_id: "S", tool_response: { stdout: big, stderr: "" } }) === null,
    `${t} output is never compressed (eliding it breaks exact-match edits)`);
}
ok(run({ tool_name: "mcp__foo__bar", tool_use_id: "t", session_id: "S", tool_response: { stdout: big, stderr: "" } }) === null,
  "mcp__* is excluded entirely (payload carries no read-only indicator)");
ok(run({ tool_name: "SomeFutureTool", tool_use_id: "t", session_id: "S", tool_response: { stdout: big, stderr: "" } }) === null,
  "an UNKNOWN tool defaults to uncompressed/safe (allowlist, not blocklist)");
// Agent: scrub+dedup MAY apply, elide MUST NOT.
const agentOut = run({ tool_name: "Agent", tool_use_id: "t", session_id: "S", tool_response: { stdout: big, stderr: "" } });
const agentText = agentOut?.hookSpecificOutput?.updatedToolOutput?.stdout ?? big;
ok(agentText.length >= big.length || !/\[elided/.test(agentText),
  "Agent output is never ELIDED (the verdict-from-report flow consumes it whole)");

// ── I2.2: the ledger passes through, by PATH not by CLI name ────────────────
console.log("-- Case: I2.2 ledger-path carve-out");
for (const cmd of [
  "cat .operator/VERDICTS.md",
  "grep PASS .operator/VERDICTS.md | tail -50",
  "tail -100 .operator/DECISIONS.md",
  "cat .operator/verdicts.d/SESS-A.md",
]) {
  ok(run({ ...bash(big), tool_input: { command: cmd } }) === null,
    `ledger render passes through untouched: ${cmd.slice(0, 34)}`);
}
ok(run({ ...bash(big), tool_input: { command: "cat .operator/bin/ops-verdict.sh" } }) === null,
  "a gate-CLI invocation passes through untouched (I2.1)");
// The carve-out must NOT swallow ordinary commands that merely mention a word.
const ordinary = run({ ...bash(big), tool_input: { command: "cat README.md" } });
ok(ordinary !== null, "an ordinary command is still compressed (carve-out did not overreach)");

// ── I2.3: spill-and-cite ────────────────────────────────────────────────────
console.log("-- Case: I2.3 elide spills the verbatim original and cites it");
const spillRes = run({ ...bash(big), tool_input: { command: "npm test" } });
const spillText = spillRes.hookSpecificOutput.updatedToolOutput.stdout;
const m = spillText.match(/\.operator\/\.compress-spill\/[^\s\]]+/);
ok(m != null, "an elide appends a marker line naming the spill path");
if (m) {
  const p = path.join(TMP, m[0]);
  ok(fs.existsSync(p), "the spill file exists on disk");
  ok(fs.readFileSync(p, "utf8") === big, "the spill holds the VERBATIM original (not the compressed form)");
}

// ── I3: never throws ────────────────────────────────────────────────────────
console.log("-- Case: I3 never throws on malformed input");
for (const bad of [null, undefined, {}, { tool_name: "Bash" }, { tool_name: "Bash", tool_response: null },
                   { tool_name: "Bash", tool_response: "a bare string" }, { tool_name: 42 }, []]) {
  let threw = false, out;
  try { out = run(bad); } catch { threw = true; }
  ok(!threw, `malformed payload ${JSON.stringify(bad)?.slice(0, 28)} does not throw`);
  ok(threw || out === null || typeof out === "object", "  …and returns null or a shape, never garbage");
}

// ── I4: no-op when no shrink (pinned at MIN_SHRINK exactly) ─────────────────
console.log("-- Case: I4 MIN_SHRINK floor, asserted at the exact boundary");
ok(DEFAULTS.MIN_SHRINK === 64, "MIN_SHRINK default is pinned at 64");
ok(DEFAULTS.MAX_CHARS === 8000, "MAX_CHARS default is pinned at 8000");
ok(DEFAULTS.HEAD_BYTES === 6144 && DEFAULTS.TAIL_BYTES === 4096, "HEAD/TAIL bytes pinned at 6144/4096");
ok(DEFAULTS.SCRUB_MIN === 1024, "SCRUB_MIN pinned at 1024");
ok(DEFAULTS.LINE_CHARS === 400, "LINE_CHARS pinned at 400");
ok(DEFAULTS.SALVAGE_LINES === 12, "SALVAGE_LINES pinned at 12");
// A payload whose only compressible content is blank lines: shrink is exactly
// MIN_SHRINK-1 → must be kept whole.
// N trailing newlines collapse to 1, so the saving is exactly N-1. Assert BOTH
// sides of the floor: a threshold test that only checks the reject side passes
// just as well when the feature is switched off entirely.
const base = "a".repeat(2000);
const savingOf = (n) => base + "\n".repeat(n + 1);   // → saves exactly n
const underRes = run({ ...bash(savingOf(DEFAULTS.MIN_SHRINK - 1)), tool_input: { command: "echo hi" } });
ok(underRes === null, "a saving of MIN_SHRINK-1 is a no-op (never credit savings the harness refused)");
const atRes = run({ ...bash(savingOf(DEFAULTS.MIN_SHRINK)), tool_input: { command: "echo hi" } });
ok(atRes !== null, "…and a saving of exactly MIN_SHRINK DOES compress (the floor is >=, not >)");

// ── I5: rebuild the original response shape ─────────────────────────────────
console.log("-- Case: I5 response shape is rebuilt, never handed back bare");
const shaped = run({ ...bash(big, { stderr: "boom" }), tool_input: { command: "npm test" } });
const upd = shaped.hookSpecificOutput.updatedToolOutput;
ok(typeof upd === "object" && upd !== null && !Array.isArray(upd),
  "updatedToolOutput is an OBJECT (a bare string is rejected on every call)");
ok(typeof upd.stdout === "string", "the {stdout,stderr} shape is preserved");
ok(upd.stderr === "", "stderr is folded into the compressed text then blanked (no duplication)");
ok(/boom/.test(upd.stdout), "…and the folded stderr content actually survives");
ok(shaped.hookSpecificOutput.hookEventName === "PostToolUse", "hookEventName is PostToolUse");
// An unrecognized shape → skip, not a guess.
ok(run({ tool_name: "Bash", tool_use_id: "t", session_id: "S", tool_response: { weird: 1 } }) === null,
  "an unrecognized response shape is skipped (emit nothing), never rebuilt blind");

// ── salvage: the one line that mattered survives the cut ────────────────────
console.log("-- Case: salvage rescues error lines from the elided middle");
const mid = ["START", ...Array(4000).fill("noise line"), "Error: the thing broke", ...Array(4000).fill("noise"), "END"].join("\n");
const sal = run({ ...bash(mid), tool_input: { command: "npm test" } })
  .hookSpecificOutput.updatedToolOutput.stdout;
ok(/Error: the thing broke/.test(sal), "a mid-log Error line is salvaged");
// TAP: the spec calls this out by name — `not ok 12` matches no error WORD.
const tap = ["START", ...Array(4000).fill("ok 1 - fine"), "not ok 12 - the failing assertion", ...Array(4000).fill("ok 2 - fine"), "END"].join("\n");
const tapOut = run({ ...bash(tap), tool_input: { command: "npm test" } })
  .hookSpecificOutput.updatedToolOutput.stdout;
ok(/not ok 12/.test(tapOut), "a TAP 'not ok' line is salvaged (it matches no error WORD — spec calls this out)");

// ── bytes, not lines ────────────────────────────────────────────────────────
console.log("-- Case: retention is bounded in BYTES, not lines");
const oneLine = "z".repeat(3_000_000); // a single newline-less multi-MB line
const bytesRes = run({ ...bash(oneLine), tool_input: { command: "cat blob" } });
const bytesText = bytesRes.hookSpecificOutput.updatedToolOutput.stdout;
ok(bytesText.length < 60000,
  `a 3MB newline-less line is byte-capped, not passed through (got ${bytesText.length})`);

// ── dedup: stateful tier, per (session, tool) ───────────────────────────────
console.log("-- Case: dedup marks a byte-identical repeat");
const dedupPayload = { ...bash("y".repeat(20000)), session_id: "SESS-DEDUP", tool_input: { command: "npm test" } };
run(dedupPayload);                       // prime
const second = run(dedupPayload);        // identical → marker
ok(second !== null && /identical|unchanged|repeat/i.test(second.hookSpecificOutput.updatedToolOutput.stdout),
  "a byte-identical repeat collapses to a marker");
ok(run({ ...dedupPayload, session_id: undefined }) !== null,
  "dedup is skipped when the payload carries no session_id (never crashes on it)");

// ── kill switches ───────────────────────────────────────────────────────────
console.log("-- Case: kill switches are honored");
ok(run({ ...bash(big), tool_input: { command: "npm test" } }, { CC_OPERATOR_COMPRESS: "0" }) === null,
  "CC_OPERATOR_COMPRESS=0 disables the hook entirely");
const noElide = run({ ...bash(big), tool_input: { command: "npm test" } },
  { CC_OPERATOR_COMPRESS_MAX_CHARS: "999999" });
ok(noElide === null, "a raised MAX_CHARS threshold suppresses the elide tier");

fs.rmSync(TMP, { recursive: true, force: true });
console.log(`\n== summary: ${pass} passed, ${fail} failed ==`);
if (fail > 0) process.exit(1);
