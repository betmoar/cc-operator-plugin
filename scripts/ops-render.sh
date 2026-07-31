#!/usr/bin/env bash
# ops-render.sh — render project-layer agent files (.claude/agents/op-*.md) from
# templates + the tier config, so a PLAIN Agent dispatch can run on a non-Claude
# model (GLM via cc-proxy) without a workflow wrapping it.
#
# WHY (audit 2026-07-31 / spec 2026-07-28 §3.4): the workflow layer routes
# cross-provider via opts.model, but plain `Agent` dispatch reads the agent
# file's `model:` frontmatter at session start. The 5 shipped plugin-root
# agents carry a Claude tier alias (opus/sonnet/haiku) that check_agents
# REQUIRES. To bind a plain-dispatch seat to GLM, this writes a PROJECT-layer
# copy (.claude/agents/op-<seat>.md) that SHADOWS the plugin-root file by
# precedence, carrying the resolved model id. Plugin-root agents stay
# alias-only and validator-clean.
#
# PROBE-VERIFIED 2026-07-31: a plain Agent dispatch honors a non-Claude id in
# the file frontmatter (probe model: glm-5-turbo → replied glm-5-turbo).
#
# RESTART TO APPLY: agent files are read at session start, not reloaded
# mid-session (spec 2026-07-29:105). A render takes effect at the next session
# start; the command says so. M7: if CLAUDE_CODE_SUBAGENT_MODEL is set it
# overrides BOTH frontmatter and opts.model — detected and warned, not silently
# lost (spec 2026-07-29:71).
#
# FORMAT: the established tiers.env KEY=VAL convention (what ops-tiers.sh
# parses — pure shell/sed, parsed never sourced). One config file, two line
# kinds, both flat NAME=VALUE:
#   TIER:   JUDGMENT=claude-opus-5        (tier → model id)
#   SEAT:   op-mechanic=MECHANICAL        (seat → tier; 'op-' prefix optional)
# Layering matches ops-tiers.sh: baked → user → project. Seats merge by name.
#
# Guard chain inherits ops-tiers.sh's charset/routable (verified) + adds the
# writer half (spec §3.4 steps 4-8): seat-name guard, pre-validate, liveness
# probe, last-known-good, two-pass atomic write.
#
# Usage (from the project root):
#   ops-render.sh            render .claude/agents/op-*.md
#   ops-render.sh --show     print the resolved seat→model table
#   ops-render.sh --revert   remove the project layer (fall back to plugin-root)
#   ops-render.sh --check    render to a temp dir + probe, write nothing
set -eu

OPDIR=".operator"
OUTDIR=".claude/agents"
USER_FILE="${CC_OPERATOR_TIERS_USER:-$HOME/.claude/cc-operator/tiers.env}"
PROJ_FILE="${CC_OPERATOR_TIERS_PROJECT:-$OPDIR/tiers.env}"
LASTGOOD="$OPDIR/.render-lastgood"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TPL_DIR="$SCRIPT_DIR/../agents/_templates"
PORT="${CC_PROXY_PORT:-4000}"
NL="$(printf '\nx')"; NL="${NL%x}"

die() { echo "ops-render: $*" >&2; exit 2; }

# ── guards (mirror ops-tiers.sh:57-68 check_routable + ledger check_bare_name)
check_routable() { # check_routable <label> <id>
  case "$2" in
    "") die "$1 is empty" ;;
    *[!A-Za-z0-9._:/@[\]-]*)
      die "$1='$2' contains characters outside [A-Za-z0-9._:/@[]-] (whitespace and quotes are never valid in a model id)" ;;
  esac
  case "$2" in glm-*|claude-*) return 0 ;; */*) return 0 ;;
    *) die "$1='$2' is not cc-proxy-routable (need glm-*, vendor/model, or claude-*)" ;; esac
}
check_seat_name() { # check_seat_name <name>
  case "$1" in
    */*) die "seat name '$1' must be a bare name (no '/')" ;;
    .*) die "seat name '$1' must not start with '.'" ;;
    *"|"* | *"$NL"*) die "seat name '$1' must not contain '|' or newlines" ;; esac
}
is_tier_name() { case " $TIER_NAMES " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

TIER_NAMES="JUDGMENT IMPLEMENT MECHANICAL RECON"
# tier → model (resolved; defaults from ops-tiers.sh baked set)
TRES_JUDGMENT="claude-opus-5"; TRES_IMPLEMENT="claude-sonnet-5"
TRES_MECHANICAL="glm-5-turbo"; TRES_RECON="claude-haiku-4-5-20251001"
TSRC_JUDGMENT=default; TSRC_IMPLEMENT=default; TSRC_MECHANICAL=default; TSRC_RECON=default

# Default seat → tier (spec §3.3, plain-dispatch seats; review fan-out is the
# workflow's job, not here). Maps to the shipped aliases: opus→JUDGMENT,
# sonnet→IMPLEMENT, haiku→RECON.
# Stored as newline-separated "name|tier|src" records in SEATS.
SEATS=""

# seat_add <name> <tier> <src>: append (or override-by-name) a record. Builds
# the record list without a trailing-newline ambiguity: one record per line, no
# embedded blanks. grep -v filters any prior record for this name (override).
seat_add() {
  local rest=""
  [ -n "$SEATS" ] && rest="$(printf '%s\n' "$SEATS" | grep -v "^$1|")"
  if [ -z "$rest" ]; then SEATS="$1|$2|$3"; else SEATS="$rest"$'\n'"$1|$2|$3"; fi
}
seat_add author IMPLEMENT default
seat_add mechanic MECHANICAL default
seat_add scout RECON default
seat_add verifier JUDGMENT default

# ── parse a tiers.env file (NAME=VALUE), parsed never sourced. Two line kinds:
#   NAME=<model-id>      → tier override  (if NAME is a known tier)
#   op-<seat>=<TIER>     → seat→tier       (the seat binding; 'op-' prefix optional)
# ops-tiers.sh already parses the tier kind the same way; this reuses that shape.
load_file() { # load_file <path> <source-label>
  [ -f "$1" ] || return 0
  local lc=0 name val
  while IFS= read -r -n 512 line || [ -n "$line" ]; do
    lc=$((lc + 1)); [ "$lc" -le 200 ] || die "$1: more than 200 lines — refusing"
    case "$line" in ''|'#'*) continue ;; esac
    [ "$line" != "${line%%=*}" ] || die "$1: malformed line (want NAME=VALUE): $line"
    name="${line%%=*}"; val="${line#*=}"
    name="${name#"${name%%[![:space:]]*}"}"; name="${name%"${name##*[![:space:]]}"}"
    val="${val#"${val%%[![:space:]]*}"}";  val="${val%"${val##*[![:space:]]}"}"
    case "$name" in
      *[[:space:]]*) die "$1: whitespace inside name '$name'" ;;
    esac
    # tier override?
    if is_tier_name "$name"; then
      check_routable "$name" "$val"
      eval "TRES_$name=\$val"; eval "TSRC_$name=\$2"
      continue
    fi
    # seat binding: strip an optional 'op-' prefix, must be a bare name, value a tier
    sname="${name#op-}"
    check_seat_name "$sname"
    is_tier_name "$val" || die "$1: seat '$sname' bound to unknown tier '$val' (known: $TIER_NAMES)"
    seat_add "$sname" "$val" "$2"
  done < "$1"
}
load_file "$USER_FILE" user
load_file "$PROJ_FILE" project

MODE=render
while [ $# -gt 0 ]; do
  case "$1" in
    --show) MODE=show; shift ;; --revert) MODE=revert; shift ;;
    --check) MODE=check; shift ;;
    *) die "unknown argument '$1' (want --show|--revert|--check)" ;; esac
done

# M7 guard: CLAUDE_CODE_SUBAGENT_MODEL overrides frontmatter AND opts.model. If
# it is set, every rendered binding silently loses to it — warn, do not fail
# (we cannot unset another process's env), but make the loss visible.
warn_subagent_env() {
  if [ -n "${CLAUDE_CODE_SUBAGENT_MODEL:-}" ]; then
    echo "ops-render: WARNING — \$CLAUDE_CODE_SUBAGENT_MODEL is set to '$CLAUDE_CODE_SUBAGENT_MODEL'; it OVERRIDES the rendered model: frontmatter at dispatch (spec M7). Unset it for the bindings below to take effect." >&2
  fi
}

[ "$MODE" = show ] && {
  printf '%-12s %-12s %-32s %s\n' SEAT TIER MODEL SOURCE
  printf '%s\n' "$SEATS" | while IFS='|' read -r -n 256 sn st ss; do
    [ -n "$sn" ] || continue
    eval "mid=\$TRES_$st"
    printf '%-12s %-12s %-32s %s\n' "$sn" "$st" "$mid" "$ss"
  done
  echo; echo "render target: $OUTDIR/ (shadows plugin-root agents; restart to apply)"
  warn_subagent_env; exit 0
}

[ "$MODE" = revert ] && {
  rm -f "$OUTDIR"/op-*.md 2>/dev/null || true
  rmdir "$OUTDIR" 2>/dev/null || true
  rm -f "$LASTGOOD"
  echo "ops-render: reverted — removed $OUTDIR/op-*.md; plugin-root (alias) agents now active (restart to apply)"
  exit 0
}

# ── render: last-known-good + two-pass atomic (spec §3.4 steps 7-8) ─────────
# render_to <dest>: emits op-<seat>.md with model: frontmatter set from the
# resolved tier id. The body comes from the tier's template (or default.tmpl).
# Pure sed/awk frontmatter splice — no python.
render_to() { # render_to <dest>
  local dest="$1" sn st mid tpl
  mkdir -p "$dest"
  printf '%s\n' "$SEATS" | while IFS='|' read -r -n 256 sn st ss; do
    [ -n "$sn" ] || continue
    eval "mid=\$TRES_$st"
    tpl="$TPL_DIR/${st}.tmpl"
    [ -f "$tpl" ] || tpl="$TPL_DIR/default.tmpl"
    [ -f "$tpl" ] || die "no template for seat '$sn' (tier $st) and no $TPL_DIR/default.tmpl"
    # Splice model: into frontmatter. If the template has a model: line, replace
    # its value; if it has a NAME placeholder, swap it; else prepend a block.
    awk -v seat="op-$sn" -v model="$mid" '
      BEGIN { infm=0; done_fm=0 }
      /^---$/ && !infm { infm=1; print; next }
      /^---$/ && infm && !done_fm { done_fm=1; print; next }
      infm && !done_fm {
        if ($0 ~ /^name:/) { sub(/:.*/, ": " seat, $0); print; next }
        if ($0 ~ /^model:/) { sub(/:.*/, ": " model, $0); print; next }
        print; next
      }
      { print }
    ' "$tpl" > "$dest/op-$sn.md"
    # The template MUST have carried a model: line for the splice to land. A
    # template with no model: frontmatter is malformed for render (the splice
    # would silently produce an agent bound to the default backend).
    grep -q '^model:' "$dest/op-$sn.md" || die "$tpl: no model: line in frontmatter — cannot splice"
  done
}

case "$MODE" in
  check)
    echo "ops-render: --check renders to a temp dir + probes; writes nothing."
    TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
    render_to "$TMP/agents"
    echo "--- distinct non-claude model ids ---"
    printf '%s\n' "$SEATS" | while IFS='|' read -r -n 256 sn st ss; do
      [ -n "$sn" ] || continue; eval "echo \$TRES_$st"; done \
      | sort -u | while IFS= read -r -n 256 id; do
        case "$id" in claude-*) echo "  $id: skipped (harness-served)"; continue ;; esac
        code="$(curl -sS -m 8 -o /dev/null -w '%{http_code}' -X POST \
          "http://127.0.0.1:${PORT}/v1/messages" -H 'content-type: application/json' \
          -d '{"model":"'"$id"'","max_tokens":1,"messages":[{"role":"user","content":"PONG"}]}' 2>/dev/null)" || code=000
        case "$code" in 2*) echo "  $id: probe OK ($code)" ;; *) echo "  $id: probe FAILED ($code)"; echo "FAIL" >&3 ;; esac
      done 3>&1 1>&2 | grep -q FAIL && die "a model id failed the liveness probe — refusing to render"
    echo "ops-render: --check passed."
    ;;
  render)
    [ -d "$TPL_DIR" ] || die "no templates dir at $TPL_DIR"
    warn_subagent_env
    [ -d "$OUTDIR" ] && ls "$OUTDIR" > "$LASTGOOD" 2>/dev/null || true
    TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
    render_to "$TMP/agents"
    mkdir -p "$OUTDIR"
    find "$OUTDIR" -maxdepth 1 -name 'op-*.md' -delete 2>/dev/null || true
    mv "$TMP/agents"/op-*.md "$OUTDIR"/
    ls "$OUTDIR" > "$LASTGOOD" 2>/dev/null || true
    n="$(printf '%s\n' "$SEATS" | grep -c .)"
    echo "ops-render: rendered $n seat(s) to $OUTDIR/"
    echo "  RESTART THE SESSION for the new model bindings to take effect (agent files are read at session start)."
    ;;
esac
