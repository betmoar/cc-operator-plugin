// tests/test_compress.mjs — replay tests for the input-axis compressor.
//
// The spec (docs/spec/input-axis-compressor.md §3) names these cases; every
// assertion is against a PINNED default, never a tilde (audit F25/F27). Pinned
// numbers live in ONE place, scripts/ops-compress.mjs, and are read from there.
//
// Run:  node tests/test_compress.mjs   (exit 0 iff all pass)

import path from "node:path";
import fs from "node:fs";
import os from "node:os";
import crypto from "node:crypto";
import { pathToFileURL, fileURLToPath } from "node:url";

// `import.meta.dirname` is Node >=20.11; ubuntu:24.04 ships 18.19, where it's
// undefined. fileURLToPath has no floor.
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

// `compress` is pure w.r.t. its inputs: hook payload + env override map, 
// returns null (skip) or the hookSpecificOutput object. No process.env reads
// inside, so a test never has to mutate global state to pin a tunable.
const run = (payload, env = {}) => compress(payload, { env, cwd: TMP });

// Each case gets a FRESH session id: dedup is stateful per (session, tool), so
// two cases reusing one session make the second hit the dedup marker instead
// of the tier under test (measured once, the spill case silently hit dedup).
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
// MIN_SHRINK-1 → must be kept whole. N trailing newlines collapse to 1, so
// assert both sides of the floor.
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
// elide cut stdout+stderr — a Bash failure on stderr vanished from both the
// model's view and the spill (reproduced: spill held 1560 B of 36589 B).
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
// spill(text) after scrub collapses repeats and strips ANSI, breaking
// "verbatim original" (I2.3) — the spill must hold what the tool PRODUCED,
// byte-identical.
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
console.log("-- Case: spill failure leaves an explicit marker, not silence");
// spill() returns null on any write failure; elided text with no marker is
// indistinguishable from complete output (I2.3's failure-path class). Force
// the failure via a .compress-spill that's a regular FILE.
const badCwd = fs.mkdtempSync(path.join(os.tmpdir(), "opsbadspill-"));
fs.mkdirSync(path.join(badCwd, ".operator"));
fs.writeFileSync(path.join(badCwd, ".operator", ".compress-spill"), "");
const failRes = compress({ ...bash("y".repeat(50000)), tool_input: { command: "npm test" } },
  { env: {}, cwd: badCwd });
{
  const failOut = failRes?.hookSpecificOutput?.updatedToolOutput?.stdout ?? "";
  ok(/NO spill copy/.test(failOut),
    "elided output whose spill failed carries the explicit no-spill marker");
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
// Before containment it mkdir'd `.operator/` (with no .gitignore, since no
// ops-init ran) in repos that never ran /cc-operator:start.
console.log("-- Case: ephemera are self-ignoring and never materialize .operator/");
{
  // (A) a project WITH .operator/ keeps spilling in-tree; each ephemera root
  //     carries its own `*` ignore so the tree is clean without ops-init.
  const spillRoot = path.join(TMP, ".operator", ".compress-spill");
  ok(fs.existsSync(spillRoot), "an initialized project spills under .operator/");
  ok(fs.readFileSync(path.join(spillRoot, ".gitignore"), "utf8").trim() === "*",
    "the spill root carries its own .gitignore holding '*'");
  ok(fs.readFileSync(path.join(TMP, ".operator", ".compress-state", ".gitignore"), "utf8").trim() === "*",
    "the dedup-state root carries its own .gitignore holding '*'");

  // (B) a project WITHOUT .operator/ gets no directory and no spill: elide
  //     still fires, the marker says "not spilled".
  const virgin = fs.mkdtempSync(path.join(os.tmpdir(), "opsvirgin-"));
  const vres = compress({ ...bash(big), tool_input: { command: "npm test" } },
    { env: {}, cwd: virgin });
  const vout = vres?.hookSpecificOutput?.updatedToolOutput?.stdout ?? "";
  ok(!fs.existsSync(path.join(virgin, ".operator")),
    "a project that never ran /cc-operator:start gets NO .operator/ directory");
  ok(/chars elided/.test(vout) && /NO spill copy/.test(vout),
    "elide still fires outside an operated project, marked 'not spilled'");
  ok(!/full output spilled to/.test(vout),
    "no spill cite in an un-operated project (there is no spill file to cite)");
  // Dedup is off there too: the same big output twice must not collapse to
  // the identical-marker (no .compress-state root to hold the hash).
  const vres2 = compress({ ...bash(big), tool_input: { command: "npm test" } },
    { env: {}, cwd: virgin });
  const vout2 = vres2?.hookSpecificOutput?.updatedToolOutput?.stdout ?? "";
  ok(!/identical to this tool's previous output/.test(vout2),
    "dedup is skipped in an un-operated project (no state root, no false HIT)");
  fs.rmSync(virgin, { recursive: true, force: true });
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
// `.` resolves to `base` itself, so the sid names no subdirectory and every
// session shares one bucket — spill()'s `keep` cleanup then prunes OTHER
// sessions' unredacted spills (Copilot review of PR #56, round 2).
console.log("-- Case: a dot-only session_id gets its own subdir, never the root");
{
  const spillRoot = path.resolve(TMP, ".operator", ".compress-spill");
  // The neighbour must be a FILE directly under the root, with more than
  // SPILL_KEEP entries present. Both were wrong in the first draft: a
  // subdirectory victim is structurally immune (unlinkSync throws EPERM,
  // swallowed by the best-effort catch) and ~5 entries against SPILL_KEEP=50
  // left the eviction slice empty (found by the review panel, round 3).
  fs.mkdirSync(spillRoot, { recursive: true, mode: 0o700 });
  const victim = path.join(spillRoot, "aaa-neighbour-spill");
  fs.writeFileSync(victim, "neighbour spill", { mode: 0o600 });
  // Oldest by mtime => first in line for eviction, or the padding below could
  // be evicted instead and the case would pass by luck.
  const old = Date.now() / 1000 - 86400;
  fs.utimesSync(victim, old, old);
  for (let i = 0; i < DEFAULTS.SPILL_KEEP + 10; i++) {
    const pad = path.join(spillRoot, `pad-${i}`);
    fs.writeFileSync(pad, "pad", { mode: 0o600 });
    fs.utimesSync(pad, old + 1 + i, old + 1 + i);
  }

  for (const sid of [".", "..", "..."]) {
    // Vary the body per iteration: all three sids resolve to the same
    // "nosession" bucket, so identical text would dedup-suppress the later
    // two and the case would pass by not testing anything.
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
      // never the root itself — `===` on the parent is what `.` used to give.
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
  // Seed an entry, then remove it right before spill()'s readdir+stat pass —
  // simulating the race the F18 fix guards (present at readdir, gone by stat).
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
  ok(!/NO spill copy/.test(rText),
    "the vanished entry does not throw spill() into the outer no-spill branch");
}

// ── #59: the case above never ENTERS the guarded window ─────────────────────
// Measured: stripping spill()'s try/catch entirely still leaves the suite
// green, because a ghost unlinked BEFORE spill() runs never appears in its
// own readdirSync. The guarded window is the gap BETWEEN readdirSync and the
// following statSync. Entered structurally via a dangling symlink (listed by
// readdirSync, ENOENT on statSync — the identical throw a vanished entry
// produces, deterministically on every run) rather than a timing race.
console.log("-- Case: #59 the F18 guard is ENTERED — an entry listed but unstattable");
{
  const winSession = `SESS-WINDOW${++sessN}`;
  const spillRoot = path.join(TMP, ".operator", ".compress-spill");
  const dir = path.join(spillRoot, winSession);
  fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
  // Points at a name that never exists: present to readdir, absent to stat —
  // the two halves of the window, held open permanently.
  fs.symlinkSync(path.join(dir, "no-such-target"), path.join(dir, "dangling"));
  // The precondition assertion: if a future Node stops listing dangling
  // symlinks, or resolves them in statSync, this case silently stops testing
  // the guard.
  ok(fs.readdirSync(dir).includes("dangling"),
    "#59 precondition: the entry IS listed by readdirSync (it enters the map)");
  // ENOENT specifically, not "any throw" (Copilot review) — an EACCES or ELOOP
  // would satisfy a bare `threw` while silently no longer modelling the
  // vanished-entry race.
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
  // WITHOUT the guard these two fail: the statSync throws out of the map,
  // into spill()'s outer catch, returning null — the FAILED marker replaces
  // a spill cite even though the write succeeded.
  ok(/full output spilled to/.test(wText),
    "#59 spill still cites a real path when an entry is listed but unstattable");
  ok(!/NO spill copy/.test(wText),
    "#59 the unstattable entry does not collapse the spill into the no-spill branch");
  // And the spill file is really on disk — a cite pointing at nothing would
  // satisfy the regex above while the guard did nothing useful.
  const cited = /full output spilled to ([^\s]+)/.exec(wText);
  ok(!!cited && fs.existsSync(path.resolve(TMP, cited[1])),
    "#59 the cited spill path exists on disk (the write completed past the guard)");
}

// ── #59, second half: the guarded VALUE, not just the absence of a throw ────
// The case above proves the guard doesn't throw, but never reaches the code
// that USES the guard's return (eviction only runs past SPILL_KEEP entries).
// The `-Infinity` polarity — "sort oldest-first so it's preferred for
// deletion" — was untested: flipping it to `Infinity` left both suites green
// (95/0, 638/0) while an unstattable entry became permanently un-evictable and
// displaced real spills every pass.
console.log("-- Case: #59b the unstattable entry sorts OLDEST — evicted, not kept");
{
  const evSession = `SESS-EVICT${++sessN}`;
  const spillRoot = path.join(TMP, ".operator", ".compress-spill");
  const dir = path.join(spillRoot, evSession);
  fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
  // Fill to the bound so the eviction loop actually runs: SPILL_KEEP existing
  // files plus the dangling symlink, then spill() adds one more.
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
  // The whole point: -Infinity sorts the unstattable entry FIRST so it's the
  // one deleted; `Infinity` sorts it last, evicting a real spill instead.
  ok(!after.includes("dangling"),
    "#59b the unstattable entry is EVICTED (it sorted oldest, as -Infinity intends)");
  // The complement: the newest real file must still be there — asserting only
  // the deletion would pass a bound that evicted everything.
  ok(after.includes(`f${String(KEEP - 1).padStart(3, "0")}`),
    "#59b a real spill file was NOT evicted in the ghost's place");
}

// ── audit F120: scrub must not eat plain text — the ESC anchor is the regex ──
console.log("-- Case: F120 scrub is lossless on ]-bearing plain text, still strips real ANSI");
{
  // 0.10.0 stripped the raw ESC bytes from scrub's regex literals; without the
  // anchor the OSC pattern matched from the first bare `]` to end-of-string
  // (measured: a 3KB "[ok]…[FAIL]" log came back as ONE char, no marker, no
  // spill — the I2.3 falsification class). Plain text with brackets must come
  // back untouched: nothing to scrub means nothing to shrink means null.
  const lines = [];
  for (let i = 0; i < 40; i++) lines.push(`[ok] test ${i} passed (case-${i})`);
  lines.push("array literal: [1, 2, 3] and a bare ] plus [x");
  lines.push("[FAIL] CRITICAL: data corruption in refund path");
  const bracketText = lines.join("\n") + "\n";
  const bres = run({ ...bash(bracketText), tool_input: { command: "npm test" } });
  ok(bres === null,
    "F120 ]-bearing plain text is untouched (scrub lossless → below MIN_SHRINK → skip)");
  // The complement: REAL ANSI/OSC sequences are still removed and the payload
  // around them survives — the pin must not pass by scrub doing nothing at all.
  let ansi = "\x1b]0;window title\x07";
  for (let i = 0; i < 60; i++) ansi += `\x1b[31m[FAIL]\x1b[0m case ${i} evidence-${i}\n`;
  const ares = run({ ...bash(ansi), tool_input: { command: "npm test" } });
  const atext = ares?.hookSpecificOutput?.updatedToolOutput?.stdout ?? "";
  ok(ares !== null && !atext.includes("\x1b"),
    "F120 real ANSI escapes are stripped (scrub still scrubs)");
  ok(atext.includes("[FAIL] case 7 evidence-7"),
    "F120 the text AROUND the escapes survives the strip");
}

// ── audit F121: a spilled output must not also claim it was not spilled ─────
console.log("-- Case: F121 spilled output carries the spill cite and no contradicting marker");
{
  const sres = run({ ...bash(big), tool_input: { command: "npm test" } });
  const stext = sres?.hookSpecificOutput?.updatedToolOutput?.stdout ?? "";
  ok(/full output spilled to/.test(stext),
    "F121 an operated project's elide cites its spill path");
  ok(!/not spilled/.test(stext) && !/NO spill copy/.test(stext),
    "F121 the elide marker no longer contradicts the spill cite (neutral marker)");
}

// ── audit F122: a symlinked .operator/ is never ours — no spill through it ──
console.log("-- Case: F122 symlinked .operator/ refused (spills stay inside the project)");
{
  const symBase = fs.mkdtempSync(path.join(os.tmpdir(), "opssym-"));
  const symTarget = fs.mkdtempSync(path.join(os.tmpdir(), "opssymtarget-"));
  fs.symlinkSync(symTarget, path.join(symBase, ".operator"));
  const symRes = compress({ ...bash(big), tool_input: { command: "npm test" } },
    { env: {}, cwd: symBase });
  const symText = symRes?.hookSpecificOutput?.updatedToolOutput?.stdout ?? "";
  ok(/NO spill copy/.test(symText) && !/full output spilled to/.test(symText),
    "F122 a symlinked .operator/ is treated as absent (elide fires, nothing spilled)");
  ok(!fs.existsSync(path.join(symTarget, ".compress-spill")),
    "F122 nothing was written through the link into the target");
  fs.rmSync(symBase, { recursive: true, force: true });
  fs.rmSync(symTarget, { recursive: true, force: true });
}

// ── Copilot PR #97: NESTED symlinks refused too — root-only lstat was not
// containment; a planted link at the ephemera root, the session dir, or the
// spill file itself still carried unredacted output outside the project.
console.log("-- Case: nested symlinks under .operator/ are refused (spill root + session dir)");
{
  const nb = fs.mkdtempSync(path.join(os.tmpdir(), "opsnest-"));
  const nt = fs.mkdtempSync(path.join(os.tmpdir(), "opsnesttarget-"));
  fs.mkdirSync(path.join(nb, ".operator"));
  fs.symlinkSync(nt, path.join(nb, ".operator", ".compress-spill"));
  const nres = compress({ ...bash(big), tool_input: { command: "npm test" } },
    { env: {}, cwd: nb });
  const ntext = nres?.hookSpecificOutput?.updatedToolOutput?.stdout ?? "";
  ok(/NO spill copy/.test(ntext) && !/full output spilled to/.test(ntext),
    "a symlinked spill ROOT under a real .operator/ is refused (no spill cite)");
  ok(fs.readdirSync(nt).length === 0,
    "nothing was written through the root link into the target");
  fs.rmSync(nb, { recursive: true, force: true });
  const sb = fs.mkdtempSync(path.join(os.tmpdir(), "opsnestsess-"));
  const st2 = fs.mkdtempSync(path.join(os.tmpdir(), "opsnesstarget2-"));
  fs.mkdirSync(path.join(sb, ".operator", ".compress-spill"), { recursive: true });
  const sessPayload = { ...bash(big), tool_input: { command: "npm test" } };
  fs.symlinkSync(st2, path.join(sb, ".operator", ".compress-spill", sessPayload.session_id));
  const sres = compress(sessPayload, { env: {}, cwd: sb });
  const stext = sres?.hookSpecificOutput?.updatedToolOutput?.stdout ?? "";
  ok(/NO spill copy/.test(stext) && !/full output spilled to/.test(stext),
    "a symlinked SESSION dir is refused (no spill cite)");
  ok(fs.readdirSync(st2).length === 0,
    "nothing was written through the session link into the target");
  fs.rmSync(sb, { recursive: true, force: true });
  fs.rmSync(nt, { recursive: true, force: true });
  fs.rmSync(st2, { recursive: true, force: true });
}

fs.rmSync(TMP, { recursive: true, force: true });
console.log(`\n== summary: ${pass} passed, ${fail} failed ==`);
if (fail > 0) process.exit(1);
