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
import crypto from "node:crypto";
import { pathToFileURL, fileURLToPath } from "node:url";

// `import.meta.dirname` is Node >=20.11 and ubuntu:24.04 ships 18.19, where it is
// undefined and path.resolve throws "paths[0] must be of type string" — an error
// naming nothing about Node versions. fileURLToPath has no floor.
const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
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

// ── spill holds the VERBATIM original INCLUDING stderr ──────────────────────
console.log("-- Case: spill preserves stderr, not just stdout (I2.3 verbatim contract)");
// F50: spill(original) lost stderr because `original` was stdout alone while
// elide cut stdout+stderr. For a Bash failure landing on stderr, the verbatim
// artifact vanished from BOTH the model's view and the spill — breaking the
// citation contract for exactly the FAIL case it exists to protect. Proven by
// reproduction before the fix: spill held 1560 B of a 36589-B combined output.
const stderrBig = "x".repeat(2000);
const stderrMid = "not ok 99 - the failing test\n" + "z".repeat(20000);
const stderrRes = run({ ...bash(stderrBig, { stderr: stderrMid }), tool_input: { command: "npm test" } });
const stderrOut = stderrRes.hookSpecificOutput.updatedToolOutput.stdout;
const sm = stderrOut.match(/\.operator\/\.compress-spill\/[^\s\]]+/);
ok(sm != null, "a Bash result with bulky stderr elides and cites the spill");
if (sm) {
  const spillFile = path.join(TMP, sm[0]);
  const spillContent = fs.readFileSync(spillFile, "utf8");
  ok(spillContent.includes("not ok 99 - the failing test"),
    "the spill holds the stderr middle (the failing-test line survives verbatim)");
  ok(spillContent.includes(stderrBig),
    "the spill holds stdout too (the spill is the combined output elide cut, not stdout alone)");
}

// ── spill is VERBATIM — pre-scrub, lossless (finding 6) ─────────────────────
console.log("-- Case: spill is the verbatim pre-scrub original, not the scrubbed text");
// spill(text) after scrub collapses repeats and strips ANSI — a lossy transform
// that broke "verbatim original" (I2.3) in a second dimension. The spill must
// hold what the tool PRODUCED, byte-identical, so a cited artifact is
// recoverable. Construct output scrub WOULD mutate: 9 identical lines + ANSI.
const repeatLine = "same line\n".repeat(9);
const ansiLine = "\x1b[31mred\x1b[0m and text\n";
const noisy = repeatLine + ansiLine + "z".repeat(10000);
const verbatimRes = run({ ...bash(noisy), tool_input: { command: "npm test" } });
const vm = verbatimRes.hookSpecificOutput.updatedToolOutput.stdout.match(/\.operator\/\.compress-spill\/[^\s\]]+/);
ok(vm != null, "noisy output elides and cites the spill");
if (vm) {
  const spillContent = fs.readFileSync(path.join(TMP, vm[0]), "utf8");
  ok(spillContent === noisy,
    "the spill is BYTE-IDENTICAL to the original (repeats uncollapsed, ANSI intact — not the scrubbed form)");
}

// ── a FAILED spill must be marked, not silent (pr-review 2026-08-03) ────────
console.log("-- Case: spill failure leaves an explicit TRUNCATED marker, not silence");
// spill() returns null on any write failure (disk full, perms). Elided text
// with no marker is indistinguishable from complete output — the I2.3
// falsification class through the failure path. Force the failure inside the
// IN-PROJECT branch: a cwd that has `.operator/` (so containment does not divert
// to the tempdir) whose `.compress-spill` is a regular FILE, making mkdirSync
// throw. Pointing cwd at a file no longer works as injection — that path now
// falls back to the tempdir and succeeds, which is the containment fix working.
const badCwd = fs.mkdtempSync(path.join(os.tmpdir(), "opsbadspill-"));
fs.mkdirSync(path.join(badCwd, ".operator"));
fs.writeFileSync(path.join(badCwd, ".operator", ".compress-spill"), "");
const failRes = compress({ ...bash("y".repeat(50000)), tool_input: { command: "npm test" } },
  { env: {}, cwd: badCwd });
{
  const failOut = failRes?.hookSpecificOutput?.updatedToolOutput?.stdout ?? "";
  ok(/TRUNCATED and the spill to disk FAILED/.test(failOut),
    "elided output whose spill failed carries the explicit failure marker");
  ok(!/full output spilled to/.test(failOut),
    "a failed spill never cites a spill file that does not exist");
}

// ── kill switches ───────────────────────────────────────────────────────────
console.log("-- Case: kill switches are honored");
ok(run({ ...bash(big), tool_input: { command: "npm test" } }, { CC_OPERATOR_COMPRESS: "0" }) === null,
  "CC_OPERATOR_COMPRESS=0 disables the hook entirely");
const noElide = run({ ...bash(big), tool_input: { command: "npm test" } },
  { CC_OPERATOR_COMPRESS_MAX_CHARS: "999999" });
ok(noElide === null, "a raised MAX_CHARS threshold suppresses the elide tier");

// ── ephemera containment ────────────────────────────────────────────────────
// The compressor fires in every project where the plugin is merely INSTALLED.
// Before containment it created `.operator/` (mkdir recursive) in repos that
// never ran /cc-operator:start — and, with no ops-init to write one, a
// `.operator/` carrying no .gitignore at all: untracked dirty state the user
// never asked for.
console.log("-- Case: ephemera are self-ignoring and never materialize .operator/");
{
  // (A) a project WITH .operator/ keeps spilling in-tree, and each ephemera root
  //     carries its own `*` ignore so the tree is clean without ops-init.
  const spillRoot = path.join(TMP, ".operator", ".compress-spill");
  ok(fs.existsSync(spillRoot), "an initialized project spills under .operator/");
  ok(fs.readFileSync(path.join(spillRoot, ".gitignore"), "utf8").trim() === "*",
    "the spill root carries its own .gitignore holding '*'");
  ok(fs.readFileSync(path.join(TMP, ".operator", ".compress-state", ".gitignore"), "utf8").trim() === "*",
    "the dedup-state root carries its own .gitignore holding '*'");

  // (B) a project WITHOUT .operator/ gets no directory at all — the roots move
  //     to a cwd-keyed tempdir, and spill/cite keep working.
  const virgin = fs.mkdtempSync(path.join(os.tmpdir(), "opsvirgin-"));
  const vres = compress({ ...bash(big), tool_input: { command: "npm test" } },
    { env: {}, cwd: virgin });
  const vout = vres?.hookSpecificOutput?.updatedToolOutput?.stdout ?? "";
  ok(!fs.existsSync(path.join(virgin, ".operator")),
    "a project that never ran /cc-operator:start gets NO .operator/ directory");
  const vm = vout.match(/full output spilled to (\S+)/);
  ok(vm != null, "the spill still happens and is still cited");
  if (vm) {
    ok(path.isAbsolute(vm[1]), "an out-of-tree spill is cited by ABSOLUTE path, never a ../.. walk");
    ok(fs.readFileSync(vm[1], "utf8") === big, "the out-of-tree spill holds the verbatim original");
  }
  // The wipe path the SessionStart hook recomputes in shell must match. The
  // shared segment carries the uid: /tmp is world-writable on Linux and the key
  // is a plain sha256 of cwd, so a uid-less shared root was readable — and
  // pre-plantable — by any other local user.
  const key = crypto.createHash("sha256").update(virgin).digest("hex").slice(0, 16);
  const uid = typeof process.getuid === "function" ? process.getuid() : "nouid";
  const tmpBase = path.join(os.tmpdir(), `cc-operator-${uid}`);
  ok(fs.existsSync(path.join(tmpBase, key, ".compress-spill")),
    "the tempdir root is <tmp>/cc-operator-<uid>/sha256(cwd)[:16] — the path SessionStart wipes");
  ok(!fs.existsSync(path.join(os.tmpdir(), "cc-operator", key)),
    "nothing is written to the legacy uid-less shared root");

  // Modes: the spill holds UNREDACTED tool output, so no group/other bits on
  // any segment or on the file itself.
  // lstat only what exists. When the tempdir root is HOSTILE — pre-planted as a
  // symlink by another local user, which is the attack the uid scoping and the
  // 0700 modes exist for — ephemeralRoot correctly returns null and no segment
  // is created. Verified on Linux with a real world-writable /tmp: /etc was
  // untouched. But this loop then lstat'd a path that rightly did not exist and
  // the whole suite died on a raw ENOENT stack trace instead of reporting a
  // verdict, which is the "raw error as operator guidance" class in JS. Say what
  // happened; a refused hostile root is a legitimate environment, not a crash.
  for (const p of [tmpBase, path.join(tmpBase, key),
                   path.join(tmpBase, key, ".compress-spill")]) {
    if (!fs.existsSync(p)) {
      ok(false, `tempdir segment absent (hostile or unwritable ${os.tmpdir()}?): ${path.basename(p)}`);
      continue;
    }
    ok((fs.lstatSync(p).mode & 0o077) === 0, `tempdir segment is 0700-tight: ${path.basename(p)}`);
  }
  if (vm && fs.existsSync(vm[1])) {
    ok((fs.lstatSync(vm[1]).mode & 0o077) === 0, "the spill FILE is 0600 — pre-scrub output is not world-readable");
  }

  // A hijacked root must not be written through. Point the keyed segment at a
  // symlink and assert the compressor declines rather than following it.
  const hijackCwd = fs.mkdtempSync(path.join(os.tmpdir(), "opshijack-"));
  const hkey = crypto.createHash("sha256").update(hijackCwd).digest("hex").slice(0, 16);
  const elsewhere = fs.mkdtempSync(path.join(os.tmpdir(), "opselsewhere-"));
  fs.mkdirSync(tmpBase, { recursive: true, mode: 0o700 });
  fs.symlinkSync(elsewhere, path.join(tmpBase, hkey));
  const hres = compress({ ...bash(big), tool_input: { command: "npm test" } },
    { env: {}, cwd: hijackCwd });
  const hout = hres?.hookSpecificOutput?.updatedToolOutput?.stdout ?? "";
  ok(!/full output spilled to/.test(hout),
    "a symlinked tempdir root is refused — no spill, no cite, rather than writing pre-scrub output where another user chose");
  ok(fs.readdirSync(elsewhere).length === 0,
    "nothing was written through the planted symlink");
  fs.unlinkSync(path.join(tmpBase, hkey));
  fs.rmSync(elsewhere, { recursive: true, force: true });
  fs.rmSync(hijackCwd, { recursive: true, force: true });
  fs.rmSync(virgin, { recursive: true, force: true });
  fs.rmSync(path.join(tmpBase, key), { recursive: true, force: true });
}

// ── F3: a traversal session_id must not escape the spill root ──────────────
console.log("-- Case: F3 traversal session_id stays inside the spill root");
{
  const traversalRes = run({
    tool_name: "Bash",
    tool_use_id: "toolu_traversal",
    session_id: "../../escaped",
    tool_input: { command: "npm test" },
    tool_response: { stdout: big, stderr: "" },
  });
  const tText = traversalRes?.hookSpecificOutput?.updatedToolOutput?.stdout ?? "";
  const tm = tText.match(/\.operator\/\.compress-spill\/[^\s\]]+/);
  ok(tm != null, "a traversal session_id still elides and cites a spill");
  if (tm) {
    const spillRoot = path.resolve(TMP, ".operator", ".compress-spill");
    const resolved = path.resolve(TMP, tm[0]);
    ok(resolved === spillRoot || resolved.startsWith(spillRoot + path.sep),
      "the resolved spill path stays INSIDE the spill root despite the traversal session_id");
    ok(fs.existsSync(resolved) && fs.readFileSync(resolved, "utf8") === big,
      "the spill file itself exists in-root and holds the verbatim original");
  }
}

// ── A dot-only session_id must not COLLAPSE the spill dir onto its root ─────
// Not the traversal above: `.` resolves to `base` itself, so the containment
// test passed it — the sid then names no subdirectory and every session shares
// one bucket. spill()'s `keep` cleanup unlinks the oldest entries of whatever
// dir it is given, so a collapsed session prunes OTHER sessions' spills, and
// those hold unredacted tool output. Asserted on the observable path, not on
// the sanitizer's return value, so it survives a refactor of the helper.
// (Copilot review of PR #56, round 2.)
console.log("-- Case: a dot-only session_id gets its own subdir, never the root");
{
  const spillRoot = path.resolve(TMP, ".operator", ".compress-spill");
  // The neighbour must be a FILE directly under the root, and the root must
  // hold more than SPILL_KEEP entries. Both were wrong in the first draft: the
  // victim was a subdirectory (spill()'s cleanup calls unlinkSync, which throws
  // EPERM on a non-empty dir and is swallowed by its best-effort catch — the
  // victim was structurally immune) and the root held ~5 entries against
  // SPILL_KEEP=50, so the eviction loop's slice was empty and never ran. The
  // assertion could not fail in either direction. A collapsed session's spills
  // land as plain files at the top level, which is what is modelled now.
  // (Both facts measured; found by the review panel, round 3.)
  fs.mkdirSync(spillRoot, { recursive: true, mode: 0o700 });
  const victim = path.join(spillRoot, "aaa-neighbour-spill");
  fs.writeFileSync(victim, "neighbour spill", { mode: 0o600 });
  // Oldest by mtime => first in line for eviction. Without this the padding
  // below could be evicted instead and the case would pass by luck.
  const old = Date.now() / 1000 - 86400;
  fs.utimesSync(victim, old, old);
  for (let i = 0; i < DEFAULTS.SPILL_KEEP + 10; i++) {
    const pad = path.join(spillRoot, `pad-${i}`);
    fs.writeFileSync(pad, "pad", { mode: 0o600 });
    fs.utimesSync(pad, old + 1 + i, old + 1 + i);
  }

  for (const sid of [".", "..", "..."]) {
    // Vary the body per iteration: all three sids correctly resolve to the SAME
    // "nosession" bucket, so identical text would be suppressed as a dedup HIT
    // and the later two would never reach spill() at all — the case would pass
    // by not testing anything. (Cost one red run to notice.)
    const res = run({
      tool_name: "Bash",
      tool_use_id: `toolu_dot${sid.length}`,
      session_id: sid,
      tool_input: { command: "npm test" },
      tool_response: { stdout: `${"d".repeat(sid.length)}${big}`, stderr: "" },
    });
    const dText = res?.hookSpecificOutput?.updatedToolOutput?.stdout ?? "";
    const dm = dText.match(/\.operator\/\.compress-spill\/[^\s\]]+/);
    ok(dm != null, `session_id ${JSON.stringify(sid)} still elides and cites a spill`);
    if (dm) {
      const resolved = path.resolve(TMP, dm[0]);
      ok(resolved.startsWith(spillRoot + path.sep),
        `session_id ${JSON.stringify(sid)}: the spill stays inside the root`);
      // The real assertion: the spill's PARENT is a subdirectory of the root,
      // never the root itself. `===` on the parent is what `.` used to give.
      ok(path.dirname(resolved) !== spillRoot,
        `session_id ${JSON.stringify(sid)}: the spill dir is NOT the shared root ` +
        `(a collapsed sid mixes sessions and lets one prune another's spills)`);
    }
  }
  ok(fs.existsSync(victim) && fs.readFileSync(victim, "utf8") === "neighbour spill",
    "a neighbouring session's spill survives the dot-session's cleanup pass");
}

// ── F18: a vanished entry between readdirSync and statSync must not fail spill ──
console.log("-- Case: F18 a vanished spill-dir entry does not fail the spill");
{
  const raceSession = `SESS-RACE${++sessN}`;
  const spillRoot = path.join(TMP, ".operator", ".compress-spill");
  const dir = path.join(spillRoot, raceSession);
  fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
  // Seed an entry, then remove it right before spill() runs its readdir+stat
  // pass — simulating the race the F18 fix guards (an entry present at
  // readdirSync but gone by statSync, e.g. a concurrent spill's own cleanup).
  const ghost = path.join(dir, "ghost");
  fs.writeFileSync(ghost, "gone", { mode: 0o600 });
  fs.unlinkSync(ghost);
  const raceRes = run({
    tool_name: "Bash",
    tool_use_id: "toolu_race",
    session_id: raceSession,
    tool_input: { command: "npm test" },
    tool_response: { stdout: big, stderr: "" },
  });
  const rText = raceRes?.hookSpecificOutput?.updatedToolOutput?.stdout ?? "";
  ok(/full output spilled to/.test(rText),
    "spill() still returns a valid, non-null path when a listed entry has already vanished");
  ok(!/TRUNCATED and the spill to disk FAILED/.test(rText),
    "the vanished entry does not throw spill() into the outer FAILED-spill branch");
}

// ── #59: the case above never ENTERS the guarded window ─────────────────────
// Measured: strip the try/catch from spill()'s map entirely and the whole suite
// stays green. The reason is that the "ghost" is unlinked BEFORE spill() runs,
// so its own readdirSync never lists it — the map never visits it, and the
// statSync that would throw is never reached. The case proves the
// already-a-ghost path, which needs no guard.
//
// The guarded window is the gap BETWEEN readdirSync and the statSync that
// follows: an entry present at enumeration and unstattable a moment later.
// Racing a real deletion into that gap would be timing-dependent, and this
// project's standing rule is structural over timing (the #23 fixture's mtime
// stamp exists for the same reason — a 1-in-3 test looks fixed and is a coin
// flip). So the window is entered structurally instead: a DANGLING SYMLINK is
// listed by readdirSync and makes statSync throw ENOENT, which is the identical
// throw a vanished entry produces, on the identical line, deterministically and
// on every run. Verified directly before writing this: readdirSync returns the
// name, statSync throws ENOENT, lstatSync succeeds.
console.log("-- Case: #59 the F18 guard is ENTERED — an entry listed but unstattable");
{
  const winSession = `SESS-WINDOW${++sessN}`;
  const spillRoot = path.join(TMP, ".operator", ".compress-spill");
  const dir = path.join(spillRoot, winSession);
  fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
  // Points at a name that does not exist, and never will. Present to readdir,
  // absent to stat — the two halves of the window, held open permanently.
  fs.symlinkSync(path.join(dir, "no-such-target"), path.join(dir, "dangling"));
  // The precondition is the assertion that makes the rest mean anything: if a
  // future Node stops listing dangling symlinks, or starts resolving them in
  // statSync, this case silently stops testing the guard — the exact failure
  // the case exists to end.
  ok(fs.readdirSync(dir).includes("dangling"),
    "#59 precondition: the entry IS listed by readdirSync (it enters the map)");
  // ENOENT specifically, not "any throw" (Copilot, PR review). The comment
  // above claims the symlink reproduces the vanished-entry failure, and only
  // ENOENT is that failure — an EACCES from a mode change, or an ELOOP from a
  // symlink cycle, would satisfy a bare `threw` while the case silently stopped
  // standing in for the race it was built to model. Pinning the code keeps the
  // precondition as strong as the sentence that justifies it.
  let statErr = null;
  try { fs.statSync(path.join(dir, "dangling")); } catch (e) { statErr = e; }
  ok(statErr?.code === "ENOENT",
    `#59 precondition: statSync on that same entry throws ENOENT (got ${statErr?.code ?? "no throw"})`);

  const winRes = run({
    tool_name: "Bash",
    tool_use_id: "toolu_window",
    session_id: winSession,
    tool_input: { command: "npm test" },
    tool_response: { stdout: big, stderr: "" },
  });
  const wText = winRes?.hookSpecificOutput?.updatedToolOutput?.stdout ?? "";
  // WITHOUT the guard these two fail: the statSync throws out of the map, into
  // spill()'s outer catch, which returns null — so the spill cite is replaced by
  // the FAILED marker even though the write itself succeeded.
  ok(/full output spilled to/.test(wText),
    "#59 spill still cites a real path when an entry is listed but unstattable");
  ok(!/TRUNCATED and the spill to disk FAILED/.test(wText),
    "#59 the unstattable entry does not collapse the spill into the FAILED branch");
  // And the spill file is really on disk — a cite pointing at nothing would
  // satisfy the regex above while the guard was doing nothing useful.
  const cited = /full output spilled to ([^\s]+)/.exec(wText);
  ok(!!cited && fs.existsSync(path.resolve(TMP, cited[1])),
    "#59 the cited spill path exists on disk (the write completed past the guard)");
}

// ── #59, second half: the guarded VALUE, not just the absence of a throw ────
// The case above proves the guard does not throw. It does not reach the code
// that USES what the guard returned, because the eviction loop only runs past
// SPILL_KEEP entries and that directory holds two.
//
// So the `-Infinity` at the catch site was untested, and its polarity is a
// stated behaviour: "Sort it oldest-first so it is preferred for deletion
// rather than kept." Measured — flip it to `Infinity` and BOTH suites stay
// green (95/0, 638/0) while an unstattable entry becomes permanently
// un-evictable AND displaces a real spill file from the bound on every pass.
// That is the #59 class exactly: a line whose purpose no test observes,
// surviving inside the fix for a line whose purpose no test observed.
console.log("-- Case: #59b the unstattable entry sorts OLDEST — evicted, not kept");
{
  const evSession = `SESS-EVICT${++sessN}`;
  const spillRoot = path.join(TMP, ".operator", ".compress-spill");
  const dir = path.join(spillRoot, evSession);
  fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
  // Fill to the bound so the eviction loop actually runs: SPILL_KEEP existing
  // files plus the dangling symlink, and spill() then adds one more.
  const KEEP = DEFAULTS.SPILL_KEEP;
  for (let i = 0; i < KEEP; i++) {
    fs.writeFileSync(path.join(dir, `f${String(i).padStart(3, "0")}`), "x", { mode: 0o600 });
  }
  fs.symlinkSync(path.join(dir, "no-such-target"), path.join(dir, "dangling"));
  const before = fs.readdirSync(dir).length;
  ok(before > KEEP,
    "#59b precondition: the directory is over SPILL_KEEP, so eviction runs");

  run({
    tool_name: "Bash",
    tool_use_id: "toolu_evict",
    session_id: evSession,
    tool_input: { command: "npm test" },
    tool_response: { stdout: big, stderr: "" },
  });

  const after = fs.readdirSync(dir);
  // The whole point: -Infinity sorts the unstattable entry FIRST, so it is the
  // one deleted. With `Infinity` it sorts last, survives every pass forever,
  // and a real spill file is evicted in its place.
  ok(!after.includes("dangling"),
    "#59b the unstattable entry is EVICTED (it sorted oldest, as -Infinity intends)");
  // The complement, and the half that shows the cost of getting it wrong: the
  // newest real file must still be there. Asserting only the deletion would
  // pass a bound that evicted everything.
  ok(after.includes(`f${String(KEEP - 1).padStart(3, "0")}`),
    "#59b a real spill file was NOT evicted in the ghost's place");
}

fs.rmSync(TMP, { recursive: true, force: true });
console.log(`\n== summary: ${pass} passed, ${fail} failed ==`);
if (fail > 0) process.exit(1);
