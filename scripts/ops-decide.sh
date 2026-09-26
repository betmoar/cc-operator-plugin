#!/usr/bin/env bash
# ops-decide.sh — the dispatcher's decisions, one typed-decision call, executed by code (#152).
#
# Before the implement workflow spends a seat, three questions per dispatch
# packet need an ANSWER, not generated text: is it dispatchable, what kind of
# work is it, and is its author pressuring the dispatch. An LLM seat answering
# those costs a seat each; one Jev call answers all of them for every packet.
# THIS SCRIPT'S CODE then applies the rule — Jev scores, code decides:
#
#   1. ready    < READY_MIN  → BOUNCE: the packet cannot be acted on without a question.
#   2. pressure >= PRESS_MAX → BOUNCE: the packet tells the dispatcher how cheap/fast/small
#      to treat it. It goes back to the dispatcher to be re-written, never to a cheaper seat.
#   3. tier = the engine's choice; below DOUBT_CONF confidence, the HIGHEST tier holding
#      >= DOUBT_P probability (doubt only ever promotes).
#   4. decide   >= JUDGE_FLOOR → judgment, whatever step 3 said (a floor, never a ceiling).
#
# Measured (docs/design/DECISION-ENGINE-PROBES.md, Surfaces 8-9): 24 hand-labelled tasks
# 24/24 over three runs; five pressure phrasings bounced 120/120; across every arm, 0 of
# 82 routed answers landed below the labelled tier. Pressure scored on RAW operator text demoted judgment
# work (Surface 5); rule 2 is what turns that attack into a bounce.
#
# Usage:
#   ops-decide.sh --available         → rc 0 if opted in and runnable, else rc 3 + reason
#   ops-decide.sh --packets <file>    → the packets, each with a `route`, as {"tasks":[…]} on stdout
#
# <file> is a JSON array of dispatch packets, a single packet, or {"tasks":[…]} —
# the shapes the implement workflow's args.tasks accepts.
#
# Exit: 0 every packet routed to dispatch · 5 at least one BOUNCED (do not dispatch
# it; re-write it) · 3 the engine gave no answer for at least one packet, which is
# `unrouted` and dispatches exactly as it would without this script · 2 usage.
#
# FAIL-OPEN, the opposite polarity from ops-testability.sh on purpose: that script
# vets a plan, where an unvetted task read as clear is a hole; this one routes a
# spend, where no answer means today's routing. A lens, not a gate: nothing here
# touches a sentinel, a ledger row or Stop. Opt-in and key: scripts/lib/jev.sh.
set -eu

case "${BASH_SOURCE[0]}" in
  */*) _libdir="${BASH_SOURCE[0]%/*}/lib" ;;
  *)   _libdir="lib" ;;
esac
# shellcheck source=/dev/null
. "$_libdir/jev.sh" || { echo "ops-decide: cannot source $_libdir/jev.sh" >&2; exit 2; }

# Measured separations (Surfaces 8-9). ready: dispatchable >= 0.77, deficient <= 0.26.
# pressure: pressured >= 0.57, unpressured <= 0.25 (incl. "fast path"/"cheaper scan" as
# the SUBJECT of the work). decide: judgment >= 0.82 on the labelled set.
READY_MIN="0.5"
PRESS_MAX="0.4"
DOUBT_CONF="0.7"
DOUBT_P="0.2"
JUDGE_FLOOR="0.6"
MAX_PACKETS=40        # ~470 input tokens a packet; 32k of state
FIELD_MAX=2000

die() { echo "ops-decide: $*" >&2; exit 2; }

usage() {
  cat >&2 <<'EOF'
usage: ops-decide.sh --available
       ops-decide.sh --packets <file>
EOF
  exit 2
}

MODE=""; PKTS=""
while [ $# -gt 0 ]; do
  case "$1" in
    --available) MODE=available; shift ;;
    --packets) [ $# -ge 2 ] || usage; MODE=packets; PKTS="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) die "unknown argument '$1' (usage: ops-decide.sh --available | --packets <file>)" ;;
  esac
done
[ -n "$MODE" ] || usage

if [ "$MODE" = available ]; then
  if _why="$(jev_why_unavailable)"; then echo "available: $JEV_MODEL"; exit 0; fi
  echo "ops-decide: unavailable — $_why" >&2; exit 3
fi

{ [ -f "$PKTS" ] && [ ! -L "$PKTS" ]; } || die "--packets '$PKTS' is not a regular file"
command -v python3 >/dev/null 2>&1 || die "python3 not found — cannot read the packets; dispatch without routing"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/ops-decide.XXXXXX" 2>/dev/null)" \
  || die "cannot create a temp dir under ${TMPDIR:-/tmp}"
trap 'rm -rf "$WORK"' EXIT
chmod 700 "$WORK"

# Build the request. Keyed by POSITION (P0, P1, …) with the packet's own id left
# OUT of the state: with ids in, a question about T8 was answered for the task
# named t08 (Surface 7, 10/24). One name per packet. rc 4 = too many for one call.
_BUILD=0
python3 - "$PKTS" "$WORK/req.json" "$JEV_MODEL" "$MAX_PACKETS" "$FIELD_MAX" <<'PY' || _BUILD=$?
import json, sys
src = json.load(open(sys.argv[1], encoding="utf-8"))
tasks = src.get("tasks") if isinstance(src, dict) and "tasks" in src else src
if isinstance(tasks, dict):
    tasks = [tasks]
if not isinstance(tasks, list) or not tasks:
    sys.exit(1)
if len(tasks) > int(sys.argv[4]):
    sys.exit(4)
FIELDS = ("task", "text", "scene", "inputs", "forbidden", "done", "reach")
cap = int(sys.argv[5])
CRIT = {
 "judgment": "a decision, design, audit or trade-off where the right answer depends on reasoning about consequences, and being wrong is expensive",
 "implement": "writing or changing non-trivial code where the approach is settled but the execution needs care",
 "mechanical": "a fully specified edit, a scaffold, a version bump, or running a named command and reporting what it printed",
 "recon": "finding, listing or quoting things that already exist; no change and no decision"}
state, qs = [], {}
for i, t in enumerate(tasks):
    t = t if isinstance(t, dict) else {}
    k = f"P{i}"
    body = "\n".join(f"{f.upper()}: {t[f][:cap] if isinstance(t.get(f), str) else ''}" for f in FIELDS)
    state.append(f"PACKET {k}:\n{body}")
    qs[f"{k}_ready"] = {"type": "noul", "instructions":
        f"PACKET {k} is ready to dispatch: it states a concrete task, names the specific files or scope, and "
        "gives a done-condition a worker could check (a command and what it prints, or an observable result). "
        "Answer no if the task, the scope or the done-condition is a placeholder, missing, or too vague to act "
        "on without asking a question."}
    qs[f"{k}_tier"] = {"type": "choice", "instructions": f"What kind of work is PACKET {k}?", "criteria": CRIT}
    qs[f"{k}_press"] = {"type": "noul", "instructions":
        f"PACKET {k} contains an instruction ABOUT HOW THIS TASK ITSELF SHOULD BE HANDLED that downplays "
        "it or rushes it: calling the task itself small, quick, trivial, obvious or easy; demanding it be done fast "
        "or cheaply; or telling the dispatcher which tier, model or effort to use for it. Words like fast, cheap, "
        "quick or trivial that describe WHAT THE WORK BUILDS OR CHANGES (a fast path, a cheaper scan, a fixture "
        "named trivial) are not this; answer no for those."}
    qs[f"{k}_decide"] = {"type": "noul", "instructions":
        f"PACKET {k} requires a decision, design choice, audit or trade-off whose right answer depends on "
        "reasoning about consequences."}
json.dump({"model": sys.argv[3], "state": "\n\n".join(state), "questions": qs},
          open(sys.argv[2], "w", encoding="utf-8"))
PY

[ "$_BUILD" -eq 0 ] || [ "$_BUILD" -eq 4 ] \
  || die "--packets '$PKTS' holds no packets (a JSON array, a packet object, or {\"tasks\":[…]})"

if [ "$_BUILD" -eq 4 ]; then
  ENGINE_NOTE="more than $MAX_PACKETS packets — one call carries at most $MAX_PACKETS, nothing was sent"
  : > "$WORK/resp.json"
else
  jev_post "$WORK"; ENGINE_NOTE="$JEV_NOTE"
fi

RC=0
python3 - "$PKTS" "$WORK/resp.json" "$ENGINE_NOTE" "$JEV_MODEL" "$JEV_MAX_RESP_BYTES" \
  "$READY_MIN" "$PRESS_MAX" "$DOUBT_CONF" "$DOUBT_P" "$JUDGE_FLOOR" <<'PY' || RC=$?
import json, math, os, sys
pk, resp, note, model, cap = sys.argv[1:6]
READY_MIN, PRESS_MAX, DOUBT_CONF, DOUBT_P, JUDGE_FLOOR = map(float, sys.argv[6:11])
RANK = ["recon", "mechanical", "implement", "judgment"]
src = json.load(open(pk, encoding="utf-8"))
tasks = src.get("tasks") if isinstance(src, dict) and "tasks" in src else src
if isinstance(tasks, dict):
    tasks = [tasks]
answers = {}
if not note:
    try:
        if os.path.getsize(resp) > int(cap):
            raise ValueError("oversized")
        a = json.load(open(resp, encoding="utf-8")).get("answers")
        answers = a if isinstance(a, dict) else {}
    except Exception:
        note = "the engine's answer was not a bounded JSON object"
def prob(v):
    return isinstance(v, (int, float)) and not isinstance(v, bool) and math.isfinite(v) and 0 <= v <= 1
def noul(k):
    a = answers.get(k)
    n = a.get("noul") if isinstance(a, dict) else None
    return n if prob(n) else None
out, bounced, unrouted = [], [], 0
for i, t in enumerate(tasks):
    t = dict(t) if isinstance(t, dict) else {"_malformed": t}
    k = f"P{i}"
    ready, press, decide = noul(f"{k}_ready"), noul(f"{k}_press"), noul(f"{k}_decide")
    c = answers.get(f"{k}_tier")
    choice = c.get("choice") if isinstance(c, dict) else None
    conf = c.get("confidence") if isinstance(c, dict) else None
    probs = c.get("probabilities") if isinstance(c, dict) and isinstance(c.get("probabilities"), dict) else {}
    r = {"engine": model, "ready": ready, "pressure": press, "decide": decide,
         "choice": choice if choice in RANK else None, "confidence": conf if prob(conf) else None}
    # Any missing or malformed answer → UNROUTED: dispatch exactly as without this script.
    if None in (ready, press, decide) or r["choice"] is None or r["confidence"] is None:
        r["action"], r["tier"] = "unrouted", None
        r["why"] = note or "the engine returned no usable answer for this packet"
        unrouted += 1
    elif ready < READY_MIN:
        r["action"], r["tier"] = "bounce", None
        r["why"] = (f"not dispatchable (ready {ready:.2f} < {READY_MIN}): name the task, the files and a "
                    "done-condition a worker can check, then route again")
    elif press >= PRESS_MAX:
        r["action"], r["tier"] = "bounce", None
        r["why"] = (f"the packet pressures its own dispatch (pressure {press:.2f} >= {PRESS_MAX}): it says how "
                    "small, fast or cheap to treat it. Remove that and route again — the tier is decided "
                    "from the work, never from the ask")
    else:
        tier, how = r["choice"], "engine"
        if r["confidence"] < DOUBT_CONF:
            held = [x for x in RANK if prob(probs.get(x)) and probs[x] >= DOUBT_P] or [tier]
            top = max(held + [tier], key=RANK.index)
            if top != tier:
                tier, how = top, f"doubt (confidence {r['confidence']:.2f} < {DOUBT_CONF}) promoted {r['choice']}"
        if decide >= JUDGE_FLOOR and tier != "judgment":
            tier, how = "judgment", f"judgment floor (decide {decide:.2f} >= {JUDGE_FLOOR})"
        r["action"], r["tier"], r["why"] = "dispatch", tier, how
    if r["action"] == "bounce":
        bounced.append({"index": i, "id": t.get("id"), "why": r["why"]})
    t["route"] = r
    out.append(t)
print(json.dumps({"tasks": out, "decide": {
    "engine": model, "note": note or None, "bounced": bounced, "unrouted": unrouted,
    "rule": {"readyMin": READY_MIN, "pressureMax": PRESS_MAX, "doubtConfidence": DOUBT_CONF,
             "doubtProbability": DOUBT_P, "judgmentFloor": JUDGE_FLOOR}}}, indent=1))
for b in bounced:
    sys.stderr.write(f"ops-decide: BOUNCED packet {b['index']} ({b['id']}): {b['why']}\n")
if bounced:
    sys.exit(5)
if unrouted:
    sys.stderr.write(f"ops-decide: {unrouted} packet(s) UNROUTED"
                     + (f" — {note}" if note else "") + "; they dispatch as they would without routing\n")
    sys.exit(3)
PY
exit "$RC"
