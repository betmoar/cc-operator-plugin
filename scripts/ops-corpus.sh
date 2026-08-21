#!/usr/bin/env bash
# ops-corpus.sh — build and verify a neutralized derived tree from a fixture
# corpus, for a maintainer dispatching a review panel over it by hand.
# Why (#69): a stale derived tree once fed a panel defects that no longer
# shipped, and the number read as a plausible mass false-positive. `build`
# stamps the source content hash into the tree; `verify` recomputes and
# refuses a mismatch (stale) or a missing stamp (unknown provenance).
# NOT part of the evidence gate: standalone, macOS-compatible bash.
set -eu

die() { echo "ops-corpus: $*" >&2; exit 2; }

usage() {
  cat >&2 <<'EOF'
Usage:
  ops-corpus.sh build  --corpus <dir> --out <dir> [--force]
  ops-corpus.sh verify --corpus <dir> --tree <dir>

build   copies the DEFECTIVE variant of each fixture into <out> under a
        plausible production name, strips marker lines, verifies the
        neutralization by grep, and stamps the source content hash.
        <out> is emptied first: a rebuild leaves nothing of a prior one.

verify  recomputes the source content hash from <corpus> and compares it to
        the stamp recorded in <tree>. Exits non-zero, naming both hashes, if
        they differ; a different non-zero if <tree> carries no stamp at all.
EOF
  exit 2
}

STAMP_NAME=".ops-corpus-stamp"
MARKER_RE='FIXTURE|DEFECTIVE|CORRECTED'

# ALLOWLIST-shaped neutralization: only the mapped defective variant is
# copied out (a blocklist leaked via README/MEASUREMENT/filenames). The map
# lives IN THE CORPUS ("<dir> <source-file> <production-name>") — the two
# corpora (tests/fixtures/security #24, tests/fixtures/drift #70) neutralize
# differently, so a table here would serve one. Unmapped dirs die loudly (#69).
MAP_NAME=".ops-corpus-map"

# read_map <corpus> — the map with comments and blank lines stripped.
read_map() {
  _m="$1/$MAP_NAME"
  [ -e "$_m" ] || die "corpus '$1' has no $MAP_NAME — it declares which file of each fixture is copied out and under what production name (see scripts/ops-corpus.sh)"
  [ -L "$_m" ] || [ -f "$_m" ] || die "$_m is not a regular file — refusing"
  [ ! -L "$_m" ] || die "$_m is a symlink — refusing"
  sed -e 's/#.*//' -e '/^[[:space:]]*$/d' "$_m"
}

# --- hash tool detection (macOS has no sha256sum by default) ----------------
if command -v sha256sum >/dev/null 2>&1; then
  HASH_CMD() { sha256sum; }
elif command -v shasum >/dev/null 2>&1; then
  HASH_CMD() { shasum -a 256; }
else
  die "neither sha256sum nor shasum found — cannot hash"
fi

hash_stream() { HASH_CMD | awk '{print $1}'; }

# corpus_hash <corpus-dir> — hash over the SORTED path list + contents
# (content-based, length-prefixed records). Every failure must be LOUD: the
# final `shasum | awk` exits 0 whatever reached it, so an unreadable file once
# produced a plausible hash over a SHORT corpus that verify then confirmed.
# The file list is materialized (find's exit checkable); every read || die.
corpus_hash() {
  corpus="$1"
  _ch_list="$(mktemp "${TMPDIR:-/tmp}/opscorp.XXXXXX")" || die "cannot create a temp file for the corpus listing"
  # One trap in THIS subshell (corpus_hash runs in a command substitution, so
  # a caller's trap cannot cover these). RETURN deliberately not in the list.
  trap 'rm -f "$_ch_list" "$_ch_list.raw" "$_ch_list.stream"' EXIT HUP INT TERM
  # NUL-separated, redirect OUTSIDE any pipe: `if ! find | sort` tests SORT,
  # which succeeds on a partial stream (a chmod-000 subdir once verified
  # green). A real file count needs -print0 (R7).
  if ! find "$corpus" -type f -print0 > "$_ch_list.raw"; then
    die "cannot list '$corpus' — refusing to stamp a hash over a partial corpus"
  fi
  # LC_ALL=C: byte-order sort — the same hash on any machine.
  if ! LC_ALL=C sort -z < "$_ch_list.raw" > "$_ch_list"; then
    die "cannot sort the listing of '$corpus' — refusing to stamp a hash from an unordered walk"
  fi
  # A newline in a filename would split one hash record into two: NUL-counted
  # entries vs newline-counted ones differ exactly then.
  _ch_files="$(tr -dc '\0' < "$_ch_list" | wc -c | tr -d '[:space:]')"
  _ch_lines="$(tr '\0' '\n' < "$_ch_list" | grep -c '' || true)"
  if [ "$_ch_lines" != "$_ch_files" ]; then
    die "'$corpus' contains a filename with a newline — refusing (it would split one hash record into two)"
  fi
  {
    while IFS= read -r -d '' f; do
      # No [ -r ]: inert for uid 0 (#21). The reads ARE the test; || die.
      sz=$(wc -c < "$f" | tr -d '[:space:]') || die "cannot read '$f' — refusing to stamp a hash that skips it"
      [ -n "$sz" ] || die "cannot size '$f' — refusing to stamp a hash with an empty length field"
      printf '%s\n%s\n' "${f#"$corpus"/}" "$sz"
      cat "$f" || die "cannot read '$f' — refusing to stamp a hash that skips it"
      printf '\n'
    done < "$_ch_list"
  } > "$_ch_list.stream" || exit 2
  hash_stream < "$_ch_list.stream"
}

# realpath_of <path> — portable realpath (cd + pwd -P; macOS may lack realpath).
realpath_of() {
  if [ -d "$1" ]; then
    (cd "$1" && pwd -P)
  else
    ( cd "$(dirname "$1")" && printf '%s/%s\n' "$(pwd -P)" "$(basename "$1")" )
  fi
}

# repo_toplevel — resolved from the script's OWN location, NEVER EMPTY: a
# no-git container once made the containment guard fail OPEN, building into
# the repo worktree. No git degrades to the parent of scripts/.
repo_toplevel() {
  script_dir="$(cd "$(dirname "$0")" && pwd -P)"
  _top="$( (cd "$script_dir" && git rev-parse --show-toplevel 2>/dev/null) || true )"
  [ -n "$_top" ] || _top="$(cd "$script_dir/.." && pwd -P)"
  printf '%s\n' "$_top"
}

# --- build --------------------------------------------------------------
cmd_build() {
  corpus="" out="" force=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --corpus) [ $# -ge 2 ] || die "--corpus requires a path"; corpus="$2"; shift 2 ;;
      --out)    [ $# -ge 2 ] || die "--out requires a path"; out="$2"; shift 2 ;;
      --force)  force=1; shift ;;
      *) die "build: unknown argument '$1'" ;;
    esac
  done
  [ -n "$corpus" ] || die "build requires --corpus <dir>"
  [ -n "$out" ] || die "build requires --out <dir>"
  [ -d "$corpus" ] || die "--corpus '$corpus' is not a directory"

  # --out must not overwrite a non-empty dir without --force.
  if [ -e "$out" ]; then
    [ -d "$out" ] || die "--out '$out' exists and is not a directory"
    if [ -n "$(find "$out" -mindepth 1 -print -quit 2>/dev/null)" ] && [ "$force" -ne 1 ]; then
      die "--out '$out' is a non-empty directory — pass --force to overwrite"
    fi
  fi

  # --out must not live inside this repo's worktree: a copy living in the repo
  # means the panel reviews the repo — the neutralization would be a lie.
  toplevel="$(repo_toplevel)"
  if [ -n "$toplevel" ]; then
    out_parent="$out"
    [ -d "$out_parent" ] || out_parent="$(dirname "$out")"
    [ -d "$out_parent" ] || die "--out '$out' has no existing parent directory to resolve"
    real_out_parent="$(realpath_of "$out_parent")"
    real_top="$(realpath_of "$toplevel")"
    case "$real_out_parent" in
      "$real_top"|"$real_top"/*)
        die "--out '$out' resolves inside this repo's worktree ($real_top) — the derived tree must live outside it" ;;
    esac
  fi

  # Content hash of the SOURCE, before any copy — the stamp records what the
  # corpus WAS at build time.
  src_hash="$(corpus_hash "$corpus")"

  MAP="$(read_map "$corpus")"
  [ -n "$MAP" ] || die "$corpus/$MAP_NAME is empty — a map with no entries would build an empty tree and call it success"

  # Refuse an unmapped fixture dir BEFORE writing (#69: a silent short tree).
  # Matched on the first PATH SEGMENT so both corpus shapes are covered.
  mapped_dirs="$(printf '%s\n' "$MAP" | awk '{print $1}' | sed 's|/.*||' | LC_ALL=C sort -u)"
  for d in "$corpus"/*/; do
    [ -d "$d" ] || continue
    name="$(basename "$d")"
    case "
$mapped_dirs
" in
      *"
$name
"*) ;;
      *) die "corpus directory '$name' is not in $corpus/$MAP_NAME — add it (with its source file and a production name) or this build would silently omit it" ;;
    esac
  done

  # Empty <out> first (an overwrite-only rebuild keeps dropped fixtures);
  # contents-only delete so a bind-mounted out dir keeps its identity.
  mkdir -p "$out"
  find "$out" -mindepth 1 -depth -exec rm -rf {} +

  # --- neutralize (allowlist; see the corpus map) -------------------------
  # BSD sed requires an explicit backup-suffix argument to -i.
  if sed --version >/dev/null 2>&1; then
    SED_INPLACE() { sed -i -E "$1" "$2"; }
  else
    SED_INPLACE() { sed -i '' -E "$1" "$2"; }
  fi
  # A here-string, NOT `printf | while`: a pipeline body's die kills only
  # the subshell, and the build went on to stamp a short tree.
  copied=0
  while IFS=' ' read -r dir src dest; do
    [ -n "$dir" ] || continue
    # Real `if`, not `A && B || C` (SC2015 — seen by CI's pinned 0.10.0 only).
    if [ -z "$src" ] || [ -z "$dest" ]; then
      die "$MAP_NAME line '$dir $src $dest' is malformed — want: <dir> <source-file> <production-name>"
    fi
    # ALL THREE fields become path components and all three are guarded —
    # content pulled from outside the corpus is in no stamp, so verify says
    # ok. String checks give the message; the RESOLVED path decides (a
    # symlinked dir walked through the string check). `dir` may contain `/`;
    # `src`/`dest` are bare filenames.
    case "/$dir/" in
      *"/../"*|*"//"*) die "$MAP_NAME: fixture path '$dir' must not contain '..' or an empty segment" ;;
    esac
    case "$dir" in
      /*) die "$MAP_NAME: fixture path '$dir' must be relative to the corpus, not absolute" ;;
    esac
    [ -d "$corpus/$dir" ] || die "$MAP_NAME names fixture path '$dir', which is not a directory in '$corpus'"
    _real_corpus="$(realpath_of "$corpus")"
    _real_dir="$(realpath_of "$corpus/$dir")"
    case "$_real_dir" in
      # Trailing-slash form stops /corpus-2 passing a check meant for /corpus;
      # the bare form allows dir resolving to the corpus root itself.
      "$_real_corpus"|"$_real_corpus"/*) ;;
      *) die "$MAP_NAME: fixture path '$dir' resolves to '$_real_dir', outside the corpus '$_real_corpus' — refusing (a symlinked component would pull in content the stamp never covers, and verify would report ok)" ;;
    esac
    case "$src" in
      */*|..|.|"") die "$MAP_NAME: source name '$src' must be a bare filename, not a path" ;;
    esac
    case "$dest" in
      */*|..|.|"") die "$MAP_NAME: production name '$dest' must be a bare filename, not a path" ;;
      # RESERVED: a mapped file of this name is silently overwritten by the
      # stamp write, and verify reads exactly the stamp it expects.
      "$STAMP_NAME") die "$MAP_NAME: production name '$dest' is reserved — build writes the corpus hash there, so a mapped file of that name would be silently overwritten and the tree would be one file short while verify still passed" ;;
    esac
    # Case-insensitively too: case compares bytes, stock APFS does not
    # (PR #72). tr, not bash 4's ${var,,}.
    _dest_lc="$(printf '%s' "$dest" | tr '[:upper:]' '[:lower:]')"
    _stamp_lc="$(printf '%s' "$STAMP_NAME" | tr '[:upper:]' '[:lower:]')"
    [ "$_dest_lc" != "$_stamp_lc" ] || die "$MAP_NAME: production name '$dest' collides with the reserved stamp filename '$STAMP_NAME' (case-insensitively — this filesystem may treat them as one file, and the stamp write would silently overwrite the mapped artifact)"
    [ -f "$corpus/$dir/$src" ] || die "$MAP_NAME names '$dir/$src', which does not exist in '$corpus'"
    # Non-symlink: cp would copy the target's content, invisible to the stamp.
    [ ! -L "$corpus/$dir/$src" ] || die "$MAP_NAME names '$dir/$src', which is a symlink — refusing (its target is outside the corpus's content hash, so a tree built from it would verify green)"
    [ ! -e "$out/$dest" ] || die "$MAP_NAME maps two fixtures to the same production name '$dest' — the second would overwrite the first and the tree would be short one fixture"
    cp "$corpus/$dir/$src" "$out/$dest"
    # Strip marker lines: header prose is a whole-line tell; the code stays.
    if grep -qE "$MARKER_RE" "$out/$dest" 2>/dev/null; then
      SED_INPLACE "/$MARKER_RE/d" "$out/$dest"
    fi
    copied=$((copied+1))
  done <<EOF
$MAP
EOF

  # Verify neutralization as its own visible step, before leaving anything.
  hits="$(grep -RlE "$MARKER_RE" "$out" 2>/dev/null || true)"
  if [ -n "$hits" ]; then
    die "neutralization check FAILED — marker(s) still present in: $(printf '%s' "$hits" | tr '\n' ' ')"
  fi
  # The half a blocklist could never do: nothing from the corpus's OWN
  # vocabulary survives — a filename alone answers the question for the lens.
  leaks="$(find "$out" -type f \( -name 'NOTES.md' -o -name 'README.md' -o -name 'MEASUREMENT.md' -o -name 'vuln*' -o -name 'fixed*' \) 2>/dev/null || true)"
  if [ -n "$leaks" ]; then
    die "neutralization check FAILED — corpus-vocabulary file(s) reached the derived tree: $(printf '%s' "$leaks" | tr '\n' ' ')"
  fi
  echo "ops-corpus: neutralization check ok — no $MARKER_RE marker and no corpus-vocabulary file in $out"

  printf '%s\n' "$src_hash" > "$out/$STAMP_NAME"
  echo "ops-corpus: built $out — $copied file(s) from $corpus (stamp $src_hash)"
}

# --- verify --------------------------------------------------------------
cmd_verify() {
  corpus="" tree=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --corpus) [ $# -ge 2 ] || die "--corpus requires a path"; corpus="$2"; shift 2 ;;
      --tree)   [ $# -ge 2 ] || die "--tree requires a path"; tree="$2"; shift 2 ;;
      *) die "verify: unknown argument '$1'" ;;
    esac
  done
  [ -n "$corpus" ] || die "verify requires --corpus <dir>"
  [ -n "$tree" ] || die "verify requires --tree <dir>"
  [ -d "$corpus" ] || die "--corpus '$corpus' is not a directory"
  [ -d "$tree" ] || die "--tree '$tree' is not a directory"

  stamp_file="$tree/$STAMP_NAME"
  # Missing stamp (exit 3) vs mismatched (exit 2): a scripting caller must
  # tell "stale, rebuild" from "never built this" without parsing English;
  # an aborted build leaves the unstamped shape, so both are reachable.
  if [ ! -e "$stamp_file" ]; then
    echo "ops-corpus: no stamp found at '$stamp_file' — tree is of UNKNOWN PROVENANCE, refusing (run 'build' to produce a stamped tree)" >&2
    exit 3
  fi
  # Regular, non-symlink only — the repo-wide rule for any trusted file.
  if [ -L "$stamp_file" ] || [ ! -f "$stamp_file" ]; then
    die "stamp at '$stamp_file' is not a regular file — refusing"
  fi

  stamped_hash="$(cat "$stamp_file")"
  current_hash="$(corpus_hash "$corpus")"

  if [ "$stamped_hash" != "$current_hash" ]; then
    die "STALE tree — stamped=$stamped_hash current=$current_hash (the corpus at '$corpus' has changed since '$tree' was built; rebuild it)"
  fi
  echo "ops-corpus: verify ok — $tree matches $corpus (hash $current_hash)"
}

[ $# -ge 1 ] || usage
sub="$1"; shift
case "$sub" in
  build)  cmd_build "$@" ;;
  verify) cmd_verify "$@" ;;
  -h|--help) usage ;;
  *) die "unknown subcommand '$sub' (want: build | verify)" ;;
esac
