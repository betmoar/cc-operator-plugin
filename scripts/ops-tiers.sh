#!/usr/bin/env bash
# ops-tiers.sh — resolve the tier→model map and emit it as JSON for a workflow.
#
# WHY THIS EXISTS: a dynamic-workflow script is sandboxed — `process`, `require`,
# `fetch` and `fs` are all undefined (measured 2026-07-29), so a workflow cannot
# read a config file, an env var, or the proxy itself. Its ONLY input channel is
# the `args` value passed at invocation. This script is what fills that channel:
# the operator runs it, and hands the JSON to Workflow({args:{tiers:...}}).
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
# Tier values and their SRC_* provenance twins are set and read through `eval`
# (bash 3.2 on macOS has no associative arrays), so shellcheck cannot see either
# side of the use. File-scoped because the pattern recurs throughout.
# shellcheck disable=SC2034,SC2154
set -eu

PORT="${CC_PROXY_PORT:-4000}"
USER_FILE="${CC_OPERATOR_TIERS_USER:-$HOME/.claude/cc-operator/tiers.env}"
PROJ_FILE="${CC_OPERATOR_TIERS_PROJECT:-.operator/tiers.env}"

# Baked defaults. These are the only ids the plugin ships; every one is
# cc-proxy-routable by shape. See the ADVERTISED-vs-ROUTABLE note below for why
# they are not required to appear in /v1/models.
TIER_NAMES="JUDGMENT IMPLEMENT MECHANICAL RECON"
JUDGMENT="claude-opus-5"
IMPLEMENT="claude-sonnet-5"
MECHANICAL="glm-5-turbo"
RECON="claude-haiku-4-5-20251001"

# provenance, parallel to TIER_NAMES
SRC_JUDGMENT="default"; SRC_IMPLEMENT="default"
SRC_MECHANICAL="default"; SRC_RECON="default"

die() { echo "ops-tiers: $*" >&2; exit 2; }

is_tier_name() {
  case " $TIER_NAMES " in *" $1 "*) return 0 ;; *) return 1 ;; esac
}

# cc-proxy's provider-lens namespaces, mirroring PROVIDER_IDS in its
# src/providers.js. An ALLOWLIST, not `*:*`, and the difference is the whole
# point of this guard: cc-proxy strips a lens it KNOWS and leaves one it does
# not. Measured against its own parseModelSelector —
#   qwen:deepseek-v4-pro  -> providerId=qwen  upstream `deepseek-v4-pro`
#   bogus:some-model      -> providerId=null  upstream `bogus:some-model`
# — so an unknown namespace reaches the default backend as a literal model id,
# which is the silent mis-route this function exists to prevent. `*:*` would
# admit exactly that. Adding a provider to cc-proxy means adding it here.
LENS_NAMESPACES="glm openrouter deepseek qwen claude"

# The routability guard. cc-proxy dispatches purely on id SHAPE: `glm-*` → Z.ai,
# `vendor/model` → OpenRouter, `claude-*` → Anthropic OAuth, `<provider>:<model>`
# → that provider explicitly (its local lens, stripped before forwarding).
# Anything else falls through to the default backend, which is a silent
# mis-route rather than an error — so the shape is checked here, before the id
# can reach a dispatch.
check_routable() {
  case "$2" in
    "") die "$1 is empty" ;;
    *[!A-Za-z0-9._:/@[\]-]*)
      die "$1='$2' contains characters outside [A-Za-z0-9._:/@[]-] (whitespace and quotes are never valid in a model id)" ;;
  esac
  # THE LENS IS TESTED FIRST, BEFORE the bare shapes. cc-proxy reads the colon
  # before anything else (parseModelSelector runs at step 0 of resolve), so an
  # id carrying one is a lens no matter what follows it. Ordering `*/*` first
  # let `bogus:vendor/model` through on the slash arm without the allowlist ever
  # being consulted — and cc-proxy answers providerId=null for it, sending the
  # literal string upstream: exactly the silent mis-route the allowlist is for.
  # Measured, and the guard's own comment claimed the opposite. Found by the
  # review panel's feasibility lens, PR #36.
  #
  # Split at the FIRST colon and require both halves — cc-proxy splits the same
  # way (indexOf, not lastIndexOf), so `qwen:a:b` sends tail `a:b` upstream and
  # this agrees rather than second-guessing it.
  case "$2" in
    *:*)
      _lens_head="${2%%:*}"; _lens_tail="${2#*:}"
      [ -n "$_lens_tail" ] || die "$1='$2' has an empty model after the '$_lens_head:' lens"
      # A SLASH BEFORE THE COLON MEANS IT IS NOT A LENS. OpenRouter ids carry
      # variant suffixes — `deepseek/deepseek-r1:free`, `qwen/qwen3-max:nitro`,
      # and cc-proxy's own models.js matches a `:batch` suffix — so the colon
      # there names a variant, not a provider. cc-proxy agrees: its
      # parseModelSelector returns providerId=null for those and resolve() then
      # routes the WHOLE string through rankRoutes, the documented OpenRouter
      # path. Refusing them is not conservatism, it is a regression: they were
      # routable before this guard learned the lens (measured against
      # origin/main — pre-PR rc 0, post-PR rc 2), and the refusal message
      # claimed `deepseek/deepseek-r1:` was a provider namespace. Fall through
      # to the bare shapes, where `*/*` accepts them as it always did.
      case "$_lens_head" in */*) ;; *)
        case " $LENS_NAMESPACES " in
          *" $_lens_head "*) return 0 ;;
          *) die "$1='$2' names the unknown provider lens '$_lens_head:' (known: $LENS_NAMESPACES) — cc-proxy strips only a lens it knows, so this would reach the default backend as a literal model id" ;;
        esac ;;
      esac ;;
  esac
  case "$2" in
    glm-*|claude-*) return 0 ;;
    */*) return 0 ;;
  esac
  die "$1='$2' is not cc-proxy-routable (need glm-*, vendor/model, <provider>:<model>, or claude-*)"
}

set_tier() { # set_tier NAME id source
  is_tier_name "$1" || die "unknown tier '$1' (known: $TIER_NAMES)"
  eval "$1=\$2"; eval "SRC_$1=\$3"
}

# Parse a NAME=value file without sourcing it.
load_file() { # load_file <path> <source-label>
  [ -f "$1" ] || return 0
  # Bounded read: a config file under .operator/ is untrusted input (a merge or
  # checkout can produce it). A newline-less multi-MB file is one "line" to an
  # unbounded read and gets slurped whole — the same class documented for the
  # Stop hook. -n caps each line at 512 chars (a tier line is well under 80);
  # the outer cap bounds a runaway file.
  # A NUL anywhere in the file is fatal BEFORE the parse loop, and it has to be
  # checked here rather than inside it: bash cannot hold a NUL in a variable at
  # all (it silently drops them), so no test on $line can ever see one — a
  # `case "$line" in *$'\0'*)` reads plausible and is vacuously TRUE, because
  # $'\0' expands to the empty string and the pattern degenerates to `**`. That
  # exact mistake was written and caught here: it rejected every valid config
  # while appearing to fix the bug (2026-08-02). `read -d ''` returns 0 only if
  # it actually reached a NUL, which is the one builtin-only way to detect one.
  #
  # Why it matters (F46): ${#line} counts CHARACTERS after bash drops NULs while
  # the -n cap is enforced on BYTES, and bash 3.2's `read -n` stops AT a NUL. So
  # `#` + 100 NULs + 411 x + `MECHANICAL=glm-evil` yields a 1-char first chunk
  # that sails past the length guard, and the tail parses as a live assignment —
  # the F42 smuggle again, through the door the char/byte mismatch leaves open.
  # Measured on bash 3.2.57 (the version this repo targets); invisible on 5.3,
  # which is why the suite was green. A tiers.env is text: a NUL means
  # truncation or a binary blob, never a config someone wrote.
  # The probe LOOPS over the file but is BOUNDED at 200 chunks (100KB). A
  # single 512-byte probe left every NUL past byte 512 undetected (Copilot
  # 2026-08-03: a NUL at byte 829 followed by MECHANICAL=glm-evil resolved with
  # exit 0), so the loop must walk more than one chunk; but a loop with NO cap
  # walks a newline-less multi-MB tiers.env end-to-end before the parse loop's
  # line-cap can reject it — measured 66-70s on a 64MB file, vs 0.11s capped
  # (bash 3.2.57, 2026-08-04; two independent verifier runs read 61s and 62s.
  # The 4.0s originally cited from the F64 report is wrong by ~15x and was
  # propagated into five files before anyone re-measured it — a load-bearing
  # number nobody owned). The probe then stalls tier resolution on untrusted
  # project config, defeating the bounded-reader guarantee that
  # check_reader_bounds exists to enforce. 200 chunks is the parse loop's own
  # legal maximum (200 lines ×
  # 512 bytes incl. newline): the first cap was 40 chunks (20KB), which
  # rejected a comment-heavy config the parse loop itself considers valid
  # (code-review of f4cae1a, 2026-08-04). Exceeding the parse loop's max is
  # malformed by definition → fail closed. `read -d ''` returns 0 only on
  # reaching a NUL or filling the -n cap; EOF returns non-zero, so the final
  # partial chunk never false-positives. The whole probe runs in a LC_ALL=C
  # subshell so BOTH -n and ${#} count bytes — a prefix on `read` alone leaves
  # ${#} counting characters in the parent locale, and a multibyte comment then
  # reads <512 chars from a full 512-byte chunk and false-positives (measured:
  # 'é'×400 comment died as a NUL under en_US.UTF-8).
  if ! (LC_ALL=C _np=0
        while IFS= read -r -d '' -n 512 _nulprobe; do
          _np=$((_np + 1)); [ "$_np" -le 200 ] || exit 1
          [ "${#_nulprobe}" -eq 512 ] || exit 1
        done < "$1") 2>/dev/null; then
    die "$1: contains a NUL byte or exceeds 100KB — refusing (tiers.env is text, not a binary blob)"
  fi
  # LC_ALL=C for the whole parse loop so `read -n` (a BYTE cap on bash 3.2) and
  # `${#line}` (a CHARACTER count in the parent locale) agree on BYTES. Without
  # it a multibyte comment defeats the cap-fill guard below: a 512-BYTE line of
  # 'é'×255 measures 257 CHARS, passes `< 512`, and its truncated tail
  # `MECHANICAL=glm-evil` parses as a live assignment at exit 0 (full-PR panel,
  # bash 3.2 under en_US.UTF-8 — the same F42/F46 class the NUL probe above got
  # LC_ALL=C for in F55, missed here). Tier names and model ids are ASCII
  # (charset-guarded); comments are skipped — C-locale parsing changes nothing
  # legitimate.
  local lc=0 LC_ALL=C
  while IFS= read -r -n 512 line || [ -n "$line" ]; do
    lc=$((lc + 1)); [ "$lc" -le 200 ] || die "$1: more than 200 lines — refusing"
    # A chunk that FILLS the cap was truncated mid-line: the remainder arrives
    # next iteration as a fresh "line" and is classified independently. That
    # made the comment check positional rather than semantic — `#` + 511 chars
    # + `MECHANICAL=glm-evil` parsed the tail as a live assignment and silently
    # repointed a tier at exit 0 (review panel, 2026-08-02). A real tier line
    # is well under 80 chars, so hitting 512 is malformed by definition. Die
    # instead of parsing a fragment; ops-render.sh carries the same guard.
    [ "${#line}" -lt 512 ] || die "$1: line $lc exceeds 512 chars — refusing (a tier line is well under 80)"
    case "$line" in ''|'#'*) continue ;; esac
    name="${line%%=*}"; val="${line#*=}"
    [ "$name" != "$line" ] || die "$1: malformed line (want NAME=model-id): $line"
    # Reject, do not normalize: a tier name with embedded whitespace (`MECH
    # ANICAL`) must not be silently coerced to `MECHANICAL` — that is a silent
    # mis-route, the same class review.js guards against on the JS side. Only
    # leading/trailing whitespace is trimmed, by shell parameter expansion; any
    # whitespace remaining inside the name is caught by is_tier_name.
    name="${name#"${name%%[![:space:]]*}"}"   # strip leading
    name="${name%"${name##*[![:space:]]}"}"   # strip trailing
    val="${val#"${val%%[![:space:]]*}"}"      # a model id never carries
    val="${val%"${val##*[![:space:]]}"}"      # surrounding whitespace
    case "$name" in
      *[[:space:]]*) die "$1: whitespace inside tier name '$name' (known: $TIER_NAMES)" ;;
    esac
    # tiers.env carries TWO line kinds (the renderer's header documents both):
    #   TIER=model-id      → ours (resolve it)
    #   [op-]seat=TIER     → the renderer's seat binding (ops-render.sh) — SKIP,
    # but only after validating its VALUE is a known tier, so a typo'd tier name
    # (JUDGEMENT=...) still dies here instead of silently resolving to defaults.
    # Before this branch existed, the resolver died on the scaffold's own
    # documented seat example (audit F15), so the two features could not share
    # the one config file ops-init.sh scaffolds.
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
    *) die "unknown argument '$1'" ;;
  esac
done

# --- proxy catalogue cross-check --------------------------------------------
#
# /v1/models describes the API-BACKED providers only. Anthropic ids are served
# through the harness's own OAuth path, so a `claude-*` id is out of the
# catalogue's scope by construction — its Claude section is a curated literal
# list (src/models.js: DEFAULT_CLAUDE_MODELS, three entries, claude-haiku-*
# deliberately omitted), not a live query. Measured 2026-07-29: `claude-opus-5`
# and `claude-haiku-4-5-20251001` are both ABSENT from /v1/models and both
# demonstrably served a live review panel.
#
# Hence: check membership for `glm-*` and `vendor/model` ids, where the
# catalogue is authoritative; skip `claude-*` entirely, where it is not. Even
# then membership is advisory, never a gate — an unlisted id is reported and
# still emitted, because the id may route while being unlisted. cc-agents
# 0.3.0's set-model.sh made non-membership a hard abort, which would refuse two
# of the four ids this plugin ships.
#
# Note also that upstream may ALIAS an id: `glm-4.5-air` is accepted and served
# as `glm-4.7` (measured directly against POST /v1/messages). Membership is
# therefore a spelling check, not a guarantee of which weights answer.
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

case "$MODE" in
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
