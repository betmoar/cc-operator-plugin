#!/usr/bin/env bash
# ops-tiers.sh — resolve the tier→model map and emit it as JSON for a workflow.
#
# A workflow script is sandboxed (no fs/env/net); its only input is `args`.
# The operator runs this and hands the JSON to Workflow({args:{tiers:...}}).
#
# Layering, later wins:
#   1. baked defaults below
#   2. ~/.claude/cc-operator/tiers.env      (user)
#   3. ./.operator/tiers.env                (project)
#   4. --set NAME=id                        (one-off, this invocation)
#
# A tiers.env line is `NAME=model-id`; `#` comments and blank lines ignored.
# Parsed, never sourced — a config file is data, not code.
#
# Usage:
#   ops-tiers.sh                      → JSON to stdout
#   ops-tiers.sh --set MECHANICAL=glm-4.7
#   ops-tiers.sh --check              → also verify against the proxy catalogue
#   ops-tiers.sh --show               → human-readable table + provenance
#   ops-tiers.sh --suggest            → report bindings a graded model dominates
# Tier values and their SRC_* provenance twins are set and read through `eval`
# (bash 3.2 on macOS has no associative arrays), so shellcheck cannot see either
# side of the use. File-scoped because the pattern recurs throughout.
# shellcheck disable=SC2034,SC2154
set -eu

PORT="${CC_PROXY_PORT:-4000}"
USER_FILE="${CC_OPERATOR_TIERS_USER:-$HOME/.claude/cc-operator/tiers.env}"
PROJ_FILE="${CC_OPERATOR_TIERS_PROJECT:-.operator/tiers.env}"

# Baked defaults — a starting point, not a catalogue claim (see check_routable).
# Nothing re-reads them, so each is only as current as its last check: `--suggest`
# is that check (#153). MECHANICAL last checked 2026-09-23 against cc-proxy's
# grades.json (fetched 2026-09-17): glm-5.3-flash 66.04 at $0.09/$0.30 dominated
# the previous glm-5-turbo 61.69 at $1.20/$4.00 on both axes.
TIER_NAMES="JUDGMENT IMPLEMENT MECHANICAL RECON"
JUDGMENT="claude-opus-5"
IMPLEMENT="claude-sonnet-5"
MECHANICAL="glm-5.3-flash"
RECON="claude-haiku-4-5-20251001"

# provenance, parallel to TIER_NAMES
SRC_JUDGMENT="default"; SRC_IMPLEMENT="default"
SRC_MECHANICAL="default"; SRC_RECON="default"

die() { echo "ops-tiers: $*" >&2; exit 2; }

is_tier_name() {
  case " $TIER_NAMES " in *" $1 "*) return 0 ;; *) return 1 ;; esac
}

# The model-id guard: well-formedness ONLY, by design (0.8.3). The user picks
# the model, cc-proxy routes it, operator decides neither — an id-shape
# catalogue here rots and refuses ids the proxy routes fine. What survives
# cannot rot: whitespace or a quote means the LINE is malformed (F01).
check_routable() {
  case "$2" in
    "") die "$1 is empty" ;;
    *[!A-Za-z0-9._:/@[\]-]*)
      die "$1='$2' contains characters outside [A-Za-z0-9._:/@[]-] (whitespace and quotes are never valid in a model id)" ;;
  esac
  return 0
}

set_tier() { # set_tier NAME id source
  is_tier_name "$1" || die "unknown tier '$1' (known: $TIER_NAMES)"
  eval "$1=\$2"; eval "SRC_$1=\$3"
}

# Parse a NAME=value file without sourcing it — a config file is untrusted
# input, so the read is bounded (512-byte lines, 200-line cap).
load_file() { # load_file <path> <source-label>
  [ -f "$1" ] || return 0
  # NUL probe, BEFORE the parse loop: bash drops NULs from variables, so no
  # test on $line can see one — `read -d ''` returning 0 is the one builtin
  # way (F46: a NUL-split chunk otherwise smuggles a live assignment past the
  # length guard on bash 3.2). Bounded at 200 chunks = the parse loop's own
  # legal max; unbounded, a newline-less 64MB file stalls ~66s (F64). The
  # whole probe runs LC_ALL=C so -n and ${#} both count BYTES — in a multibyte
  # locale a full chunk measures <512 chars and false-positives.
  if ! (LC_ALL=C _np=0
        while IFS= read -r -d '' -n 512 _nulprobe; do
          _np=$((_np + 1)); [ "$_np" -le 200 ] || exit 1
          [ "${#_nulprobe}" -eq 512 ] || exit 1
        done < "$1") 2>/dev/null; then
    die "$1: contains a NUL byte or exceeds 100KB — refusing (tiers.env is text, not a binary blob)"
  fi
  # LC_ALL=C on the loop too: `read -n` caps BYTES, `${#line}` counts CHARS in
  # the parent locale — a multibyte comment otherwise defeats the cap-fill
  # guard below (same F42/F46 class). All legitimate content is ASCII.
  local lc=0 LC_ALL=C
  while IFS= read -r -n 512 line || [ -n "$line" ]; do
    lc=$((lc + 1)); [ "$lc" -le 200 ] || die "$1: more than 200 lines — refusing"
    # A cap-FILLING chunk was truncated mid-line and its remainder would parse
    # as a fresh line next iteration — die, don't parse a fragment. A real
    # tier line is well under 80 chars; ops-render.sh carries the same guard.
    [ "${#line}" -lt 512 ] || die "$1: line $lc exceeds 512 chars — refusing (a tier line is well under 80)"
    case "$line" in ''|'#'*) continue ;; esac
    name="${line%%=*}"; val="${line#*=}"
    [ "$name" != "$line" ] || die "$1: malformed line (want NAME=model-id): $line"
    # Trim only leading/trailing whitespace; embedded whitespace is rejected
    # below, never coerced — silent coercion is a silent mis-route.
    name="${name#"${name%%[![:space:]]*}"}"   # strip leading
    name="${name%"${name##*[![:space:]]}"}"   # strip trailing
    val="${val#"${val%%[![:space:]]*}"}"      # a model id never carries
    val="${val%"${val##*[![:space:]]}"}"      # surrounding whitespace
    case "$name" in
      *[[:space:]]*) die "$1: whitespace inside tier name '$name' (known: $TIER_NAMES)" ;;
    esac
    # tiers.env carries TWO line kinds: TIER=model-id (ours) and
    # [op-]seat=TIER (the renderer's — skip, but validate the VALUE so a
    # typo'd tier name dies here instead of resolving to defaults; F15).
    if ! is_tier_name "$name"; then
      is_tier_name "$val" || die "$1: unknown tier '$name' (known: $TIER_NAMES; a seat line needs a tier VALUE, e.g. op-scout=MECHANICAL)"
      continue   # a valid seat binding — the renderer's business, not ours
    fi
    check_routable "$name" "$val"
    set_tier "$name" "$val" "$2"
  done < "$1"
}

MODE=json
load_file "$USER_FILE" "user"
load_file "$PROJ_FILE" "project"

while [ $# -gt 0 ]; do
  case "$1" in
    --set)
      [ $# -ge 2 ] || die "--set requires NAME=model-id"
      n="${2%%=*}"; v="${2#*=}"
      [ "$n" != "$2" ] || die "--set wants NAME=model-id, got '$2'"
      check_routable "$n" "$v"; set_tier "$n" "$v" "--set"; shift 2 ;;
    --check) MODE=check; shift ;;
    --show)  MODE=show;  shift ;;
    --json)  MODE=json;  shift ;;
    --suggest) MODE=suggest; shift ;;
    *) die "unknown argument '$1'" ;;
  esac
done

# Proxy catalogue cross-check — ADVISORY, never a gate: /v1/models covers only
# API-backed providers (claude-* is harness-served and absent by construction),
# an unlisted id may still route, and upstream may alias ids. Report and emit.
catalogue_note() {
  body="$(curl -sS -m 5 "http://127.0.0.1:${PORT}/v1/models" 2>/dev/null || true)"
  if [ -z "$body" ]; then
    echo "note: proxy at :$PORT did not answer /v1/models — membership unchecked" >&2
    return 0
  fi
  case "$body" in
    *'"data"'*'['*) : ;;
    *) echo "note: unexpected /v1/models body (no data[]) — membership unchecked" >&2; return 0 ;;
  esac
  listed="$(printf '%s' "$body" \
    | grep -oE '"id"[[:space:]]*:[[:space:]]*"[^"]+"' \
    | sed -E 's/.*"([^"]+)"$/\1/')"
  for n in $TIER_NAMES; do
    eval "id=\$$n"
    # claude-* is harness-served, not API-served: out of this catalogue's scope.
    case "$id" in claude-*) continue ;; esac
    base="${id%%[[]*}"   # strip a [1m]-style context-variant marker
    if ! printf '%s\n' "$listed" | grep -qxF -- "$base"; then
      echo "note: $n='$id' is not advertised by /v1/models — routable by shape, unverified by catalogue" >&2
    fi
  done
}

[ "$MODE" = check ] && catalogue_note

# Dominance report (#153) — REPORT-ONLY, never a gate, never an edit. It reads
# cc-proxy's grades table, which cc-proxy maintains and timestamps, rather than
# copying its facts here (the class 0.8.3 removed). "Dominated" is Pareto: some
# graded model scores at least as high AND costs no more on either axis, strictly
# better on one. Deliberately NOT "cheapest model above a floor": that min()
# collapses three tiers onto one model and destroys the judgment seat being
# stronger than the seat it reviews. Fail-OPEN: cc-proxy is optional, so an
# absent, oversized or unparseable table is a note and exit 0.
GRADES="${CC_OPERATOR_GRADES:-$HOME/.claude/cc-proxy/grades.json}"
suggest_report() {
  if [ ! -f "$GRADES" ]; then
    echo "note: no grades table at $GRADES — nothing to compare against (cc-proxy is optional)"
    return 0
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    echo "note: python3 not found — cannot read $GRADES; bindings unchecked"
    return 0
  fi
  _pairs=""
  for n in $TIER_NAMES; do
    eval "id=\$$n"; eval "src=\$SRC_$n"
    _pairs="$_pairs $n=$id=$src"
  done
  # shellcheck disable=SC2086  # _pairs is space-separated NAME=id=src words; ids are charset-guarded
  python3 - "$GRADES" $_pairs <<'PY' || echo "note: could not read $GRADES — bindings unchecked"
import json, re, sys
path, pairs = sys.argv[1], sys.argv[2:]
# Every string below comes from ANOTHER system's file on its way to a terminal and
# a model: C0/C1 controls (ESC, BEL, CSI) are replaced, so a model key cannot
# repaint the screen; errors="replace" keeps a lone surrogate from killing print().
sys.stdout.reconfigure(errors="replace")
def clean(v, cap=120):
    return re.sub(r"[\x00-\x1f\x7f-\x9f]", "?", str(v))[:cap]
with open(path, "rb") as f:
    raw = f.read(1048577)
if len(raw) > 1048576:
    print(f"note: {path} exceeds 1MB — not read; bindings unchecked"); sys.exit(0)
try:
    doc = json.loads(raw.decode("utf-8"))
    models = doc["models"]
    assert isinstance(models, dict)
except Exception:
    print(f"note: {path} is not a grades table (no models{{}}) — bindings unchecked"); sys.exit(0)
def num(v):
    return v if isinstance(v, (int, float)) and not isinstance(v, bool) else None
def graded(e):
    if not isinstance(e, dict): return None
    s, i, o = num(e.get("score")), num(e.get("input_price")), num(e.get("output_price"))
    return None if None in (s, i, o) else (s, i, o, clean(e.get("evidence", "?"), 20))
table = {k: g for k, g in ((k, graded(v)) for k, v in models.items()) if g}
print(f"grades: {clean(path, 400)} (fetched_at {clean(doc.get('fetched_at', 'unknown'))}; "
      f"attribution: {clean(doc.get('attribution', 'unstated'))})")
found = 0
for p in pairs:
    name, mid, src = p.split("=", 2)
    cur = table.get(mid.split("[", 1)[0])
    if cur is None:
        print(f"{name:<11} {mid} ({src}): not graded — nothing to compare"); continue
    s, i, o, ev = cur
    better = sorted(
        (k, g) for k, g in table.items()
        if g[0] >= s and g[1] <= i and g[2] <= o and (g[0] > s or g[1] < i or g[2] < o))
    better.sort(key=lambda kg: (-kg[1][0], kg[1][1] + 3 * kg[1][2]))
    if not better:
        print(f"{name:<11} {mid} ({src}): not dominated (score {s:g}, ${i:g}/${o:g}, {ev})"); continue
    found += 1
    print(f"{name:<11} {mid} ({src}): DOMINATED (score {s:g}, ${i:g}/${o:g}, {ev}) by:")
    for k, (bs, bi, bo, bev) in better[:3]:
        print(f"              {clean(k)}  score {bs:g}, ${bi:g}/${bo:g} per Mtok in/out, {bev}")
print(f"{found} dominated binding(s). Report only — nothing was changed; repoint a tier in tiers.env.")
PY
}

case "$MODE" in
  suggest)
    suggest_report
    ;;
  show)
    printf '%-11s %-30s %s\n' TIER MODEL SOURCE
    for n in $TIER_NAMES; do
      eval "id=\$$n"; eval "src=\$SRC_$n"
      printf '%-11s %-30s %s\n' "$n" "$id" "$src"
    done
    echo
    echo "user:    $USER_FILE"
    echo "project: $PROJ_FILE"
    catalogue_note
    ;;
  *)
    # JSON for Workflow({args:{tiers:...}}). Ids are charset-guarded above, so
    # no value here can contain a quote or backslash needing escape.
    out='{'
    sep=''
    for n in $TIER_NAMES; do
      eval "id=\$$n"
      out="$out$sep\"$n\":\"$id\""
      sep=','
    done
    printf '%s}\n' "$out"
    ;;
esac
