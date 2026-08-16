#!/usr/bin/env bash
# resolve_tier — reads tiers.env and prints the concrete model id for a
# tier or seat name. As of 0.8.3 this checks only well-formedness (no
# whitespace, no quotes, non-empty); it does not judge the id shape.
BAD_CHARSET='[[:space:]"'"'"']'

check_routable() {
  local id="$1"
  [ -n "$id" ] || return 1
  [[ "$id" =~ $BAD_CHARSET ]] && return 1
  return 0
}

resolve_tier() {
  local name="$1"
  local id
  id=$(awk -F= -v k="$name" '$1==k{print $2}' tiers.env)
  check_routable "$id" || { echo "refused: $id" >&2; return 1; }
  echo "$id"
}
