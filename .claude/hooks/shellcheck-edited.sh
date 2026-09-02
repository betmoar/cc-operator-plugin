#!/usr/bin/env bash
# hooks/shellcheck-edited.sh — lint a .sh file the moment it is edited, with the
# PINNED shellcheck, not the one on this workstation.
#
# WHY THIS EXISTS. scripts/lib/autobar.sh shipped through THREE CI paths
# unlinted, because every one of them globbed `scripts/*.sh` and that does not
# match `scripts/lib/`. The globs are fixed (#86 review), but the detection
# still lived in CI — four commits after the file was written. This closes the
# distance to the edit itself.
#
# WHY PINNED. 0.11 stopped failing on SC2015 while 0.9/0.10 still do, so five
# commits reported "shellcheck clean" from a 0.11 workstation while every CI run
# went red on the same bytes. A local hook running the LOCAL shellcheck would
# reproduce that split exactly — it would bless what CI rejects, which is worse
# than no hook. 0.10.0 in a container is the version the gate actually uses.
#
# POLARITY: advisory. Exit 0 always, findings on stderr. This repo's own Stop
# hook is the thing that blocks; a second blocking layer on every edit turns a
# lint finding into a wedged session, and a hook that wedges gets deleted.
# The gate that decides what ships is still CI.
set -u

payload=""
IFS= read -r -d '' payload || true
[ -n "$payload" ] || exit 0

# The field is tool_input.file_path for Edit/Write. That is an ASSUMPTION this
# repo has never tested (CLAUDE.md says so explicitly: ops-compress.mjs reads
# command/pattern/path and never file_path, and its matcher excludes Write|Edit
# entirely). So a miss is REPORTED, not swallowed — silence here would be
# indistinguishable from "the file was fine", which is the failure class this
# whole repo is organised against.
if command -v jq >/dev/null 2>&1; then
  f="$(printf '%s' "$payload" | jq -r '.tool_input.file_path // empty' 2>/dev/null)"
elif command -v python3 >/dev/null 2>&1; then
  f="$(printf '%s' "$payload" | python3 -c 'import sys,json
try: d=json.load(sys.stdin)
except Exception: sys.exit(0)
print((d.get("tool_input") or {}).get("file_path") or "")' 2>/dev/null)"
else
  exit 0   # no parser: fail open, exactly as ops-stop-hook.sh does
fi

if [ -z "$f" ]; then
  # Only complain when the payload was parseable but carried no path — a
  # payload we could not read at all is already handled above.
  case "$payload" in
    *file_path*) echo "shellcheck hook: payload has file_path but it did not parse — the hook is now blind, fix the parser" >&2 ;;
  esac
  exit 0
fi

case "$f" in
  *.sh) ;;
  *) exit 0 ;;
esac
[ -f "$f" ] || exit 0

command -v docker >/dev/null 2>&1 || {
  echo "shellcheck hook: docker not available, skipping the PINNED 0.10.0 lint of $f (the local shellcheck is deliberately NOT used — it disagrees with CI)" >&2
  exit 0
}

# Mount the file's directory read-only; shellcheck resolves `source` relative to
# it, so linting scripts/lib/partition.sh in isolation still works.
d="$(cd "$(dirname "$f")" && pwd)"
b="$(basename "$f")"
out="$(docker run --rm -v "$d":/w:ro -w /w koalaman/shellcheck-alpine:v0.10.0 \
        shellcheck -x "$b" 2>&1)" && exit 0

echo "shellcheck 0.10.0 (the CI-pinned version) on $f:" >&2
printf '%s\n' "$out" >&2
exit 0
