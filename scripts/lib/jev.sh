# shellcheck shell=bash
# shellcheck disable=SC2034  # JEV_MODEL/JEV_NOTE are consumed by the SOURCING script
# scripts/lib/jev.sh — the ONE transport to the typed-decision engine (#151, #152).
#
# Sourced by ops-testability.sh and ops-decide.sh, which differ only in the
# questions they ask and the rule their code applies to the answers. Everything
# that must not differ between them lives here: the opt-in, the key handling,
# the pinned model, and the bounded call.
#
# Opt-in is the USER's: CC_OPERATOR_JEV=1 in the environment (settings.json
# `env`). Task text leaves the machine, so a model running a script cannot grant
# it. The key is TYPESAFE_API_KEY from the environment, else the line of that
# name in JEV_KEYFILE (parsed, never sourced). It reaches curl through a 0600
# header file, never argv, and is never printed.
#
# A lens, never a gate: nothing that sources this touches a sentinel, a ledger
# row or Stop. It decides a SPEND (DECISION-ENGINE-PROBES.md, hard constraint 2).

JEV_MODEL="jev-1.13.0"   # pinned: `jev-latest` moves when a release ships
JEV_URL="${CC_OPERATOR_JEV_URL:-https://api.typesafe.ai/v1/systemone}"
JEV_MAX_RESP_BYTES=1048576 # two bounds: curl --max-filesize (only when Content-Length
                           # is sent) and the caller's size check before parse (always).
JEV_KEYFILE="${CC_OPERATOR_JEV_KEYFILE:-$HOME/.env}"

# jev_read_key: env first, then one bounded parse of JEV_KEYFILE. Prints nothing; sets KEY.
jev_read_key() {
  KEY="${TYPESAFE_API_KEY:-}"
  [ -n "$KEY" ] && return 0
  { [ -f "$JEV_KEYFILE" ] && [ ! -L "$JEV_KEYFILE" ]; } || return 1
  local _line _n=0
  while IFS= read -r -n 4096 _line || [ -n "$_line" ]; do
    _n=$((_n + 1)); [ "$_n" -gt 500 ] && break
    case "$_line" in
      TYPESAFE_API_KEY=*|"export TYPESAFE_API_KEY="*)
        KEY="${_line#*TYPESAFE_API_KEY=}"; KEY="${KEY%$'\r'}"; KEY="${KEY%\"}"; KEY="${KEY#\"}"
        KEY="${KEY%\'}"; KEY="${KEY#\'}" ;;
    esac
  done < "$JEV_KEYFILE"
  [ -n "$KEY" ]
}

# jev_why_unavailable: prints the first missing precondition, rc 1; rc 0 when runnable.
jev_why_unavailable() {
  [ "${CC_OPERATOR_JEV:-}" = 1 ] || { echo "not opted in (the user sets CC_OPERATOR_JEV=1)"; return 1; }
  command -v curl >/dev/null 2>&1 || { echo "curl not found"; return 1; }
  command -v python3 >/dev/null 2>&1 || { echo "python3 not found"; return 1; }
  jev_read_key || { echo "no TYPESAFE_API_KEY in the environment or $JEV_KEYFILE"; return 1; }
  return 0
}

# jev_post <workdir> — POSTs <workdir>/req.json, answer in <workdir>/resp.json.
# Sets JEV_NOTE: empty on a 200, else why there is no answer (resp.json is then
# EMPTY, so a caller that parses it anyway reads nothing, never a stale body).
# jev_why_unavailable runs in a subshell under $( ), so KEY does not survive it —
# it is read again here, in this shell, where the header file needs it.
jev_post() {
  local _w="$1" _code
  if JEV_NOTE="$(jev_why_unavailable)" && jev_read_key; then
    ( umask 077; printf 'Authorization: Bearer %s\n' "$KEY" > "$_w/hdr" )
    unset KEY
    _code="$(curl -sS --max-time 20 --max-filesize "$JEV_MAX_RESP_BYTES" -X POST "$JEV_URL" -H @"$_w/hdr" \
      -H 'Content-Type: application/json' --data-binary @"$_w/req.json" -o "$_w/resp.json" \
      -w '%{http_code}' 2>"$_w/curl.err")" || _code="curl-failed"
    rm -f "$_w/hdr"
    if [ "$_code" = 200 ]; then JEV_NOTE=""; else JEV_NOTE="the engine answered '$_code'"; : > "$_w/resp.json"; fi
  else
    : > "$_w/resp.json"
  fi
}
