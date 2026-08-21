export const meta = {
  name: "dispatch",
  description:
    "Run ONE agent seat on a caller-supplied model id. The plain Agent tool's model parameter is enum-locked to Anthropic aliases, so a seat cannot be dispatched on a configured cc-proxy model without a workflow; this is that workflow, and nothing more.",
  whenToUse:
    "When you need a single seat (author, mechanic, scout, verifier, crawler, brainstorm) to run on the model its tier is bound to, and you have not rendered project-layer agent files. Resolve the id first with `/cc-operator:tiers` (its render branch prints one id per seat) and pass it as args.model; args.seat picks the seat and args.prompt is the task.",
  phases: [{ title: "Dispatch", detail: "one seat, one model, one call" }],
};

// --- tier resolution (shared block; see workflows/review.js) ----------------
// The workflow sandbox forbids import() (measured 2026-07-30), so this block is
// copy-pasted across every workflow; check_workflow_parity holds BAD_CHARSET
// byte-identical across the copies.
// DEFAULTS ARE HARNESS ALIASES, NOT MODEL IDS (#76 step 2). The old defaults
// named vendor ids — a catalogue of another system's facts in five copies, the
// class 0.8.3 removed from the id guard. An alias is resolved by the harness,
// so it cannot go stale here; real bindings are the operator's job via
// /cc-operator:tiers, arriving as args.tiers or args.model. Exactly the tiers
// this workflow dispatches (the JUDGMENT fallback below).
const DEFAULT_TIERS = {
  JUDGMENT: "opus",
};
// The ONLY id guard, by design: operator does not decide which models
// exist. That is the user's choice (tiers.env / args.model) and cc-proxy's
// routing decision — see ops-tiers.sh check_routable for the full reasoning
// behind dropping the id-shape catalogue and the provider-lens allowlist in
// 0.8.3. What remains tests the STRING, so it cannot go stale: whitespace or a
// quote means the tiers.env line is malformed, not that the model is unknown.
const BAD_CHARSET = /[^\w./:@[\]-]/;

// Normalize args. The Workflow tool stringifies a passed object into a JSON
// STRING in transit (verified), so `args?.seat` would read undefined and the
// workflow would dispatch nothing. Parse a JSON string back to an object.
const A = (() => {
  if (typeof args === "string") {
    const t = args.trim();
    // `"` too: the tool JSON-encodes a passed scalar, so a bare string arrives
    // with its quotes attached. Kept identical to review.js's normalizer.
    if (t.startsWith("{") || t.startsWith("[") || t.startsWith('"')) {
      try { return JSON.parse(t); } catch { return args; }
    }
    return args;
  }
  return args ?? {};
})();

const overrides = typeof A === "object" ? A.tiers : undefined;
if (overrides != null) {
  if (typeof overrides !== "object" || Array.isArray(overrides)) {
    throw new Error(`args.tiers must be an object, got ${typeof overrides}`);
  }
  // No KNOWN_TIERS catalogue (#76 step 2): a key this workflow does not
  // dispatch is forward-compatible input — the resolver's FULL map is legal
  // (audit F07). A typo'd key would silently leave the default, so unused
  // keys are LOGGED, not thrown.
  for (const name of Object.keys(overrides)) {
    if (!(name in DEFAULT_TIERS)) {
      log(`tiers: '${name}' is not a tier this workflow dispatches (${Object.keys(DEFAULT_TIERS).join(", ")}) — accepted, unused`);
    }
  }
}
const TIERS = { ...DEFAULT_TIERS, ...(overrides ?? {}) };
for (const [name, id] of Object.entries(TIERS)) {
  if (typeof id !== "string" || !id.trim()) {
    throw new Error(`tier ${name}=${JSON.stringify(id)} is not a model id string`);
  }
  if (BAD_CHARSET.test(id)) {
    throw new Error(`tier ${name}=${JSON.stringify(id)} contains characters outside the model-id charset [A-Za-z0-9._:/@[]-]`);
  }
}
const JUDGMENT = TIERS.JUDGMENT;

// --- the seat table ---------------------------------------------------------
// A LITERAL map, not `"cc-operator:op-" + seat`. Two reasons, and the second is
// the load-bearing one:
//
// 1. A computed agentType is invisible to check_workflow_agent_types, which
//    matches a literal `"cc-operator:<name>"` by regex against a shipped
//    agents/<name>.md. Concatenation would let a typo'd or removed seat ship
//    green and fail at dispatch (F22's class: a name that cannot exist).
//    The literal map is necessary but was not, on its own, sufficient: until
//    the review round after 0.8.3 that checker anchored on the `agentType:`
//    KEY, and this file passes the shorthand `agentType,` with the string in
//    the table — so it matched nothing here and every SEATS value retyped to a
//    nonexistent agent shipped green (measured). The checker now matches the
//    VALUE, which covers both spellings. Keep the strings literal: a computed
//    one goes invisible again, and this time the comment would be right.
// 2. It bounds what this workflow can dispatch. `args.seat` is caller input,
//    and without a table it becomes an arbitrary agentType string.
//
// Keys match ops-render.sh's seat_add names, so `--model <seat>` and
// `args.seat` take the same word. op-reviewer is deliberately ABSENT: it is a
// shipped agent but not a default seat (ops-render.sh:54 says so), and the
// review workflow owns that fan-out.
const SEATS = {
  author: "cc-operator:op-author",
  mechanic: "cc-operator:op-mechanic",
  scout: "cc-operator:op-scout",
  verifier: "cc-operator:op-verifier",
  crawler: "cc-operator:op-crawler",
  brainstorm: "cc-operator:op-brainstorm",
};

// The 'op-' prefix is optional everywhere else (tiers.env, --model), so it is
// optional here — a caller copying a seat name out of `--show` gets the bare
// word, one out of an agent filename gets the prefixed one.
const rawSeat = typeof A === "object" && !Array.isArray(A) ? A.seat : undefined;
if (typeof rawSeat !== "string" || !rawSeat.trim()) {
  throw new Error(`args.seat must be a seat name (one of: ${Object.keys(SEATS).join(", ")})`);
}
const seat = rawSeat.trim().replace(/^op-/, "");
// Object.hasOwn, not a bare `SEATS[seat]`: the table is a plain object literal,
// so a bare lookup inherits from Object.prototype and `constructor`,
// `toString`, `valueOf`, `hasOwnProperty` and `__proto__` all return something
// TRUTHY — sailing past the `!agentType` guard below and reaching agent() as a
// native function instead of a string. args.seat is caller input, and bounding
// it is the stated reason SEATS is a literal table at all (see above), so the
// bound has to hold for every string a caller can send. cc-proxy's routes.js
// carries the same guard against the same trap on its own lookup tables.
const agentType = Object.hasOwn(SEATS, seat) ? SEATS[seat] : undefined;
if (!agentType) {
  throw new Error(`unknown seat ${JSON.stringify(rawSeat)} (known: ${Object.keys(SEATS).join(", ")})`);
}

const prompt = typeof A.prompt === "string" ? A.prompt.trim() : "";
if (!prompt) {
  throw new Error("args.prompt must be a non-empty string (the task for the seat)");
}

// --- the model ---------------------------------------------------------------
// THE POINT OF THIS FILE, and the honest shape of it: the caller supplies the
// id. The sandbox has no filesystem (review.js:14, measured), so this workflow
// CANNOT read .operator/tiers.env and resolve the seat itself. `ops-render.sh
// --model <seat>` does that resolution outside, and its output goes in here —
// the same division of labour args.tiers already uses. That script name is
// correct HERE, in a maintainer comment about the implementation, and wrong in
// anything a user reads: ops-render.sh is not installed into .operator/bin/
// (only the five gate CLIs are, ops-init.sh:218) and ${CLAUDE_PLUGIN_ROOT} is
// unset in the Bash tool env (#62), so neither spelling is typeable in a
// project shell. meta.whenToUse and the fallback log say `/cc-operator:tiers`,
// the command that wraps it — found by a Copilot review of this PR.
//
// So this is not "the tier applies automatically". It is: the one route by
// which a resolved id can reach a seat at all, because the plain Agent tool's
// model parameter is enum-locked to sonnet|opus|haiku|fable and rejects a
// cc-proxy id before dispatch (#55).
//
// Falling back to a tier default rather than throwing, because dispatching on
// JUDGMENT is a defensible default for a seat whose binding the caller did not
// name — and the log line below says which happened, so a caller who meant to
// pass a model finds out.
const model = typeof A.model === "string" && A.model.trim() ? A.model.trim() : "";
if (model) {
  // The caller-supplied id gets the SAME guard as a tiers.env binding — no
  // more and no less. Less would make this workflow a bypass around
  // check_routable; more would make it the one place that second-guesses the
  // caller's model choice, which is exactly what 0.8.3 removed everywhere else.
  if (BAD_CHARSET.test(model)) {
    throw new Error(`args.model=${JSON.stringify(model)} contains characters outside the model-id charset [A-Za-z0-9._:/@[]-]`);
  }
}
const resolved = model || JUDGMENT;
log(model
  ? `dispatch: ${seat} on ${resolved} (caller-supplied)`
  : `dispatch: ${seat} on ${resolved} — no args.model given, fell back to the JUDGMENT tier; run \`/cc-operator:tiers\` to resolve ${seat}'s configured binding and pass it as args.model`);

// --- dispatch ----------------------------------------------------------------
phase("Dispatch");
const result = await agent(prompt, {
  agentType,
  model: resolved,
  label: `dispatch:${seat}`,
  phase: "Dispatch",
  ...(typeof A.effort === "string" && A.effort.trim() ? { effort: A.effort.trim() } : {}),
});

// A dead agent returns null, and null is not a result. Returning it as one
// would let a caller read "the seat ran and said nothing" from "the seat never
// ran" — the fail-open shape review.js's dead-lens accounting exists to close.
if (result == null) {
  return {
    seat,
    model: resolved,
    dead: true,
    error: `the ${seat} seat returned nothing — this is NOT an empty result. The agent died: the model id was refused, or a schema mismatch, timeout, or rate limit. The harness logs its own failure line above, which names the cause.`,
  };
}
return { seat, model: resolved, dead: false, result };
