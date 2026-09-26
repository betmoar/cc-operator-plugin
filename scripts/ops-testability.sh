#!/usr/bin/env bash
# ops-testability.sh — vet a plan's testCycles with ONE typed-decision call (#151).
#
# The plan workflow's testability lens asks one yes/no per task: does its
# testCycle name a real command AND its expected output? Measured on 24 hashed
# labels (docs/design/DECISION-ENGINE-PROBES.md, Surface 7): the MECHANICAL seat
# scored 23/24 for $0.46 and 102 s; one Jev call scored 24/24 for ~$0.00015 in
# under 0.5 s. The workflow sandbox has no network, so the call lives here, run
# by commands/plan.md around a Workflow started with args.testability="external".
#
# Usage:
#   ops-testability.sh --available        → rc 0 if opted in and runnable, else rc 3 + reason
#   ops-testability.sh --plan <file>      → the plan result JSON, testability merged, on stdout
#
# Opt-in is the USER's: CC_OPERATOR_JEV=1 in the environment (settings.json
# `env`). Task text leaves the machine, so a model running this cannot grant it.
# The key is TYPESAFE_API_KEY from the environment, else the line of that name in
# ~/.env (parsed, never sourced). It reaches curl through a 0600 header file,
# never argv, and is never printed.
#
# FAIL TOWARD UNVETTED. plan.js under "external" puts EVERY task in
# `vettingIncomplete`; this script lifts a task out only when Jev scored it at or
# above THRESHOLD and its feasibility seat returned. No key, no network, a
# non-200, an oversized or malformed answer, more than MAX_TASKS tasks — every
# unscored task stays in `vettingIncomplete`, the plan still prints, exit 3. A
# score below THRESHOLD blocks the task as the seat's `testable: "no"` did. A
# lens, not a gate: nothing here touches a sentinel, a ledger row or Stop.
set -eu

MODEL="jev-1.13.0"   # pinned: `jev-latest` moves when a release ships
URL="${CC_OPERATOR_JEV_URL:-https://api.typesafe.ai/v1/systemone}"
# Measured separation on the Surface 7 fixture: every "no" <= 0.41 (probe
# request) / <= 0.42 (this script's id-less request), every "yes" >= 0.87.
THRESHOLD="0.6"
MAX_TASKS=60          # one call: 64k tokens/request, 32k of them state
MAX_RESP_BYTES=1048576 # an answer for 60 Nouls is ~5 KB. Two bounds: curl --max-filesize (only
                       # when Content-Length is sent) and the merge step's size check (always).
KEYFILE="${CC_OPERATOR_JEV_KEYFILE:-$HOME/.env}"

die() { echo "ops-testability: $*" >&2; exit 2; }
unavailable() { echo "ops-testability: unavailable — $*" >&2; }

usage() {
  cat >&2 <<'EOF'
usage: ops-testability.sh --available
       ops-testability.sh --plan <file>
EOF
  exit 2
}

# read_key: env first, then one bounded parse of KEYFILE. Prints nothing; sets KEY.
read_key() {
  KEY="${TYPESAFE_API_KEY:-}"
  [ -n "$KEY" ] && return 0
  { [ -f "$KEYFILE" ] && [ ! -L "$KEYFILE" ]; } || return 1
  local _line _n=0
  while IFS= read -r -n 4096 _line || [ -n "$_line" ]; do
    _n=$((_n + 1)); [ "$_n" -gt 500 ] && break
    case "$_line" in
      TYPESAFE_API_KEY=*|"export TYPESAFE_API_KEY="*)
        KEY="${_line#*TYPESAFE_API_KEY=}"; KEY="${KEY%$'\r'}"; KEY="${KEY%\"}"; KEY="${KEY#\"}"
        KEY="${KEY%\'}"; KEY="${KEY#\'}" ;;
    esac
  done < "$KEYFILE"
  [ -n "$KEY" ]
}

# why_unavailable: prints the first missing precondition, rc 1; rc 0 when runnable.
why_unavailable() {
  [ "${CC_OPERATOR_JEV:-}" = 1 ] || { echo "not opted in (the user sets CC_OPERATOR_JEV=1)"; return 1; }
  command -v curl >/dev/null 2>&1 || { echo "curl not found"; return 1; }
  command -v python3 >/dev/null 2>&1 || { echo "python3 not found"; return 1; }
  read_key || { echo "no TYPESAFE_API_KEY in the environment or $KEYFILE"; return 1; }
  return 0
}

MODE=""; PLAN=""
while [ $# -gt 0 ]; do
  case "$1" in
    --available) MODE=available; shift ;;
    --plan) [ $# -ge 2 ] || usage; MODE=plan; PLAN="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) die "unknown argument '$1' (usage: ops-testability.sh --available | --plan <file>)" ;;
  esac
done
[ -n "$MODE" ] || usage

if [ "$MODE" = available ]; then
  if _why="$(why_unavailable)"; then echo "available: $MODEL at threshold $THRESHOLD"; exit 0; fi
  unavailable "$_why"; exit 3
fi

{ [ -f "$PLAN" ] && [ ! -L "$PLAN" ]; } || die "--plan '$PLAN' is not a regular file"
command -v python3 >/dev/null 2>&1 || die "python3 not found — cannot read the plan; re-run the workflow without testability=\"external\""

WORK="$(mktemp -d "${TMPDIR:-/tmp}/ops-testability.XXXXXX" 2>/dev/null)" \
  || die "cannot create a temp dir under ${TMPDIR:-/tmp}"
trap 'rm -rf "$WORK"' EXIT
chmod 700 "$WORK"

# Build the request from the plan. Only title/files/testCycle leave the machine;
# specExcerpt stays home. Keyed by POSITION (T0, T1, …): ids are schema-legal to
# repeat (F110). The task's OWN id is left out of the state on purpose — with it
# in, a question about `T8` was answered for the task whose id was `t08`
# (measured: 10/24 on the Surface 7 fixture, 24/24 without). One name per task.
# rc 4 = more tasks than one call carries: no call, every task stays unvetted.
_BUILD=0
python3 - "$PLAN" "$WORK/req.json" "$MODEL" "$MAX_TASKS" <<'PY' || _BUILD=$?
import json, sys
plan = json.load(open(sys.argv[1], encoding="utf-8"))
tasks = plan.get("tasks") if isinstance(plan, dict) else None
if not isinstance(tasks, list) or not tasks:
    sys.exit(1)
if len(tasks) > int(sys.argv[4]):
    sys.exit(4)
def cut(v, n):
    return v[:n] if isinstance(v, str) else v
state, questions = [], {}
for i, t in enumerate(tasks):
    t = t if isinstance(t, dict) else {}
    slim = {"title": cut(t.get("title"), 400),
            "files": t.get("files") if isinstance(t.get("files"), list) else [],
            "testCycle": cut(t.get("testCycle"), 2000)}
    state.append(f"TASK T{i}:\n{json.dumps(slim)}")
    questions[f"T{i}"] = {"type": "noul", "instructions":
        f"TASK T{i}'s testCycle names an OBSERVABLE acceptance criterion: a real command to run "
        "AND the concrete expected output or exit status. Answer no if it asserts behavior vaguely "
        "(\"works correctly\", \"handles errors\", \"should be faster\") or names a command with no "
        "expected output."}
json.dump({"model": sys.argv[3], "state": "\n\n".join(state), "questions": questions},
          open(sys.argv[2], "w", encoding="utf-8"))
PY

[ "$_BUILD" -eq 0 ] || [ "$_BUILD" -eq 4 ] \
  || die "--plan '$PLAN' is not a plan result (needs a non-empty tasks array)"

RC=0; ENGINE_NOTE=""
# why_unavailable runs in a subshell under $( ), so KEY does not survive it —
# read it again here, in this shell, where the header file needs it.
if [ "$_BUILD" -eq 4 ]; then
  ENGINE_NOTE="more than $MAX_TASKS tasks — one call carries at most $MAX_TASKS, nothing was sent"
  : > "$WORK/resp.json"
elif ENGINE_NOTE="$(why_unavailable)" && read_key; then
  ( umask 077; printf 'Authorization: Bearer %s\n' "$KEY" > "$WORK/hdr" )
  unset KEY
  _code="$(curl -sS --max-time 20 --max-filesize "$MAX_RESP_BYTES" -X POST "$URL" -H @"$WORK/hdr" -H 'Content-Type: application/json' \
    --data-binary @"$WORK/req.json" -o "$WORK/resp.json" -w '%{http_code}' 2>"$WORK/curl.err")" || _code="curl-failed"
  rm -f "$WORK/hdr"
  if [ "$_code" = 200 ]; then ENGINE_NOTE=""; else ENGINE_NOTE="the engine answered '$_code'"; : > "$WORK/resp.json"; fi
else
  : > "$WORK/resp.json"
fi

# Merge. Every task gets testable yes|no|unvetted in `vetting`; no → `blocked`
# (issue kind "untestable", as the seat reported it); unvetted → `vettingIncomplete`.
python3 - "$PLAN" "$WORK/resp.json" "$THRESHOLD" "$MODEL" "$ENGINE_NOTE" "$MAX_RESP_BYTES" <<'PY' || RC=$?
import json, math, os, sys
plan_path, resp_path, thr, model, note, cap = sys.argv[1:7]
thr = float(thr)
plan = json.load(open(plan_path, encoding="utf-8"))
tasks = plan["tasks"]
answers = {}
if not note:
    try:
        # curl's --max-filesize cannot stop a body sent without Content-Length;
        # this bound is the one that holds (PR #190 review).
        if os.path.getsize(resp_path) > int(cap):
            raise ValueError("oversized")
        a = json.load(open(resp_path, encoding="utf-8")).get("answers")
        answers = a if isinstance(a, dict) else {}
    except Exception:
        note = "the engine's answer was not a bounded JSON object"
vetting = plan.get("vetting") if isinstance(plan.get("vetting"), list) else []
by_index = {v.get("taskIndex"): v for v in vetting if isinstance(v, dict)}
blocked = plan.get("blocked") if isinstance(plan.get("blocked"), list) else []
incomplete = plan.get("vettingIncomplete") if isinstance(plan.get("vettingIncomplete"), list) else []
blocked_idx = {b.get("taskIndex") for b in blocked if isinstance(b, dict)}
incomplete_idx = {b.get("taskIndex") for b in incomplete if isinstance(b, dict)}
# plan.js keeps blocked / needsInfo / vettingIncomplete exclusive; so does this.
needs_idx = {b.get("taskIndex") for b in plan.get("needsInfo") or [] if isinstance(b, dict)}
unvetted = 0
for i, t in enumerate(tasks):
    tid = str((t or {}).get("id", "?")) if isinstance(t, dict) else "?"
    a = answers.get(f"T{i}")
    n = a.get("noul") if isinstance(a, dict) else None
    ok = isinstance(n, (int, float)) and not isinstance(n, bool) and math.isfinite(n) and 0 <= n <= 1
    verdict = ("yes" if n >= thr else "no") if ok else "unvetted"
    row = by_index.get(i)
    if row is None:
        row = {"taskId": tid, "taskIndex": i, "issues": []}
        vetting.append(row); by_index[i] = row
    row["testable"] = verdict
    row["testabilityNoul"] = n if ok else None
    if verdict == "no":
        issue = {"kind": "untestable", "detail":
                 f"{model} scored the testCycle {n:.2f} < {thr}: it names no command with an observable expected output"}
        row.setdefault("issues", []).append(issue)
        if i in blocked_idx:
            for b in blocked:
                if isinstance(b, dict) and b.get("taskIndex") == i:
                    b.setdefault("issues", []).append(issue)
        else:
            blocked.append({"taskId": tid, "taskIndex": i, "issues": [issue]}); blocked_idx.add(i)
        if i in incomplete_idx:
            incomplete[:] = [b for b in incomplete if not (isinstance(b, dict) and b.get("taskIndex") == i)]
            incomplete_idx.discard(i)
    elif verdict == "yes" and isinstance(row.get("feasible"), str):
        # Scored testable AND the feasibility seat answered: the one path out of
        # the fail-closed vettingIncomplete plan.js put every task in.
        if i in incomplete_idx:
            incomplete[:] = [b for b in incomplete if not (isinstance(b, dict) and b.get("taskIndex") == i)]
            incomplete_idx.discard(i)
    if verdict == "unvetted":
        unvetted += 1
        if i not in blocked_idx and i not in incomplete_idx and i not in needs_idx:
            incomplete.append({"taskId": tid, "taskIndex": i}); incomplete_idx.add(i)
for i, row in by_index.items():
    if isinstance(row, dict) and isinstance(i, int) and 0 <= i < len(tasks):
        row["vettingIncomplete"] = i in incomplete_idx
plan["vetting"], plan["blocked"], plan["vettingIncomplete"] = vetting, blocked, incomplete
plan["testability"] = {"engine": model, "threshold": thr, "unvetted": unvetted,
                       "note": note or None}
print(json.dumps(plan, indent=1))
if unvetted:
    sys.stderr.write(f"ops-testability: {unvetted} task(s) UNVETTED for testability"
                     + (f" — {note}" if note else "") + "; they are in vettingIncomplete, never clear\n")
    sys.exit(3)
PY
exit "$RC"
