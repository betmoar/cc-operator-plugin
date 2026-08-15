export const meta = {
  name: "dispatch",
  description:
    "Run ONE agent seat on a caller-supplied model id. The plain Agent tool's model parameter is enum-locked to Anthropic aliases, so a seat cannot be dispatched on a configured cc-proxy model without a workflow; this is that workflow, and nothing more.",
  whenToUse:
    "When you need a single seat (author, mechanic, scout, verifier, crawler, brainstorm) to run on the model its tier is bound to, and you have not rendered project-layer agent files. Resolve the id first with `ops-render.sh --model <seat>` and pass it as args.model; args.seat picks the seat and args.prompt is the task.",
  phases: [{ title: "Dispatch", detail: "one seat, one model, one call" }],
};

// --- tier resolution (shared block; see workflows/review.js) ----------------
// The workflow sandbox forbids import() (measured 2026-07-30), so this block is
// copy-pasted across every workflow. check_workflow_parity + check_workflow_
// tier_namespace hold it together — keep ROUTABLE/BAD_CHARSET byte-identical
// and KNOWN_TIERS == ops-tiers.sh TIER_NAMES.
const DEFAULT_TIERS = {
  JUDGMENT: "claude-opus-5",
  MECHANICAL: "glm-5-turbo",
};
// Lens-first mirror of ops-tiers.sh check_routable (F8, issue #35): a colon
// names a LENS only when the head before it is a known provider and has no
// slash (`vendor/model:free` is a variant suffix, not a lens — the slash means
// fall through to the bare shapes). The bare `*/*` arm must not pre-empt the
// allowlist or `bogus:vendor/model` routes through the slash. Bare shapes
// (^glm-, ^claude-, slash-containing) never carry a colon, so they are
// anchored colon-free here.
const ROUTABLE = /^(?:glm-|claude-)[^:]*$|^(?:glm|openrouter|deepseek|qwen|claude):.+|^(?=[^:]*\/[^:]*:).+$|^[^:]*\/[^:]*$/;
const BAD_CHARSET = /[^\w./:@[\]-]/;
const KNOWN_TIERS = ["JUDGMENT", "IMPLEMENT", "MECHANICAL", "RECON"];

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
  for (const name of Object.keys(overrides)) {
    if (!KNOWN_TIERS.includes(name)) {
      throw new Error(`unknown tier '${name}' in args.tiers (known: ${KNOWN_TIERS.join(", ")})`);
    }
  }
}
const TIERS = { ...DEFAULT_TIERS, ...(overrides ?? {}) };
for (const [name, id] of Object.entries(TIERS)) {
  if (typeof id !== "string" || !ROUTABLE.test(id)) {
    throw new Error(`tier ${name}=${JSON.stringify(id)} is not cc-proxy-routable (need glm-*, vendor/model, or claude-*)`);
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
//    matches `agentType: "cc-operator:<name>"` by regex against a shipped
//    agents/<name>.md. Concatenation would let a typo'd or removed seat ship
//    green and fail at dispatch (F22's class: a name that cannot exist).
// 2. It bounds what this workflow can dispatch. `args.seat` is caller input,
//    and without a table it becomes an arbitrary agentType string.
//
// Keys match ops-render.sh's seat_add names, so `--model <seat>` and
// `args.seat` take the same word. op-reviewer is deliberately ABSENT: it is a
// shipped agent but not a default seat (ops-render.sh:53 says so), and the
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
const agentType = SEATS[seat];
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
// the same division of labour args.tiers already uses.
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
  // The caller-supplied id gets the SAME two guards as a tiers.env binding.
  // Without them this workflow is a bypass around check_routable: an id that
  // ops-tiers.sh would refuse reaches cc-proxy as a literal string and lands on
  // the default backend — the silent mis-route the allowlist exists to prevent.
  if (!ROUTABLE.test(model)) {
    throw new Error(`args.model=${JSON.stringify(model)} is not cc-proxy-routable (need glm-*, vendor/model, <provider>:<model>, or claude-*)`);
  }
  if (BAD_CHARSET.test(model)) {
    throw new Error(`args.model=${JSON.stringify(model)} contains characters outside the model-id charset [A-Za-z0-9._:/@[]-]`);
  }
}
const resolved = model || JUDGMENT;
log(model
  ? `dispatch: ${seat} on ${resolved} (caller-supplied)`
  : `dispatch: ${seat} on ${resolved} — no args.model given, fell back to the JUDGMENT tier; pass \`ops-render.sh --model ${seat}\` to run its configured binding`);

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
    error: `the ${seat} seat returned nothing (agent died: schema mismatch, timeout, or rate limit) — this is NOT an empty result`,
  };
}
return { seat, model: resolved, dead: false, result };
