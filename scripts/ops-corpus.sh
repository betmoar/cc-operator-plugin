#!/usr/bin/env bash
# ops-corpus.sh — build and verify a neutralized derived tree from a fixture
# corpus, for a maintainer dispatching a review panel over it by hand.
#
# WHY THIS EXISTS (#69): a measurement's derived tree is an artifact with a
# version, same as any build output. During #24 step 3 a scratch tree built
# in step 2 was reused after the source fixtures had been fixed — the panel
# correctly reported defects in code that no longer shipped, and the number
# read as a plausible mass false-positive rather than an error. Nothing in
# the repo noticed, because every assertion in tests/fixtures/security/ is
# about the SOURCE fixtures; none is about the derived copy that is the
# panel's actual input. This script makes staleness an error instead of a
# silent read: `build` stamps the source content hash into the tree it
# produces, `verify` recomputes it and refuses to let a caller trust a tree
# that does not match — or has no stamp at all (unknown provenance, refused
# just as loudly as a stale one).
#
# NOT part of the evidence gate: not installed into .operator/bin/, not
# referenced by any hook, standalone (no sourcing of other ops scripts) so a
# maintainer can run it from anywhere, before dispatch. POSIX-ish bash,
# macOS-compatible: no GNU-only flags, detects shasum vs sha256sum.
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

# The neutralization is ALLOWLIST-shaped, not blocklist-shaped, and that is the
# whole design (MEASUREMENT.md, "Method"): only the defective variant of each
# fixture is copied, renamed to a plausible production filename, and everything
# else is left behind. A blocklist — copy it all, then delete what looks like a
# tell — was the first shape and it leaks in three ways measured on this very
# corpus: the README's own 2x2 table names `vuln.sh` as "the defective version",
# MEASUREMENT.md reprints the detection scores per fixture, and the surviving
# FILENAMES (`vuln.sh` beside `fixed.sh`) answer the question before the lens
# reads a line. A lens shown any of that is not being measured on detection; it
# is being asked to agree, which is the exact failure the hand-neutralization
# step existed to prevent.
#
# The map lives IN THE CORPUS, at <corpus>/.ops-corpus-map — one line per output
# file: "<dir> <source-file> <production-name>". Two reasons it is not a table in
# this script:
#
#   1. The tool would otherwise only ever serve ONE corpus. This repo already has
#      two (tests/fixtures/security for #24, tests/fixtures/drift for #70) and
#      they neutralize differently: a security fixture contributes its defective
#      variant as one file, a drift fixture contributes a SET (the claim and the
#      code it describes live in different files). A per-corpus map handles both
#      without the script knowing either corpus exists.
#   2. Adding a fixture then requires editing a file in the same directory as
#      the fixture, which is where the author already is. A table in scripts/ is
#      a coupling across the tree — exactly the kind this repo's CLAUDE.md
#      maintains a whole table to survive.
#
# Auto-discovery (`*/vuln.sh`) was the alternative and it is the #69 shape: the
# day a fixture is renamed it silently produces a four-of-five tree and prints
# "built". An unmapped directory is refused below, loudly.
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

# hash_field <field> — hash one NUL-terminated field, no trailing newline.
# Used so the manifest hash is a hash of exactly the bytes we choose, never of
# a filesystem's incidental formatting (mtimes, permission bits).
hash_stream() { HASH_CMD | awk '{print $1}'; }

# corpus_hash <corpus-dir> — a hash over the SORTED list of corpus-relative
# paths and their contents. Sorted so filesystem iteration order (which a
# checkout, a tar, or a different OS can vary) never perturbs the hash;
# content-based, never mtime-based, since a plain checkout changes every
# mtime without changing a single byte. Each record is
# "<relpath>\n<byte-length>\n<content>\n" — the length prefix stops one
# file's trailing bytes from being ambiguous with the next path line.
corpus_hash() {
  corpus="$1"
  # LC_ALL=C: a byte-order sort, not a locale-dependent one — the same
  # hash must come out on any machine that runs this script.
  find "$corpus" -type f -print | LC_ALL=C sort | while IFS= read -r f; do
    rel="${f#"$corpus"/}"
    sz=$(wc -c < "$f" | tr -d '[:space:]')
    printf '%s\n%s\n' "$rel" "$sz"
    cat "$f"
    printf '\n'
  done | hash_stream
}

# realpath_of <path> — portable realpath (macOS ships no `realpath` by
# default on older systems; `cd + pwd -P` is the POSIX-safe equivalent).
realpath_of() {
  if [ -d "$1" ]; then
    (cd "$1" && pwd -P)
  else
    ( cd "$(dirname "$1")" && printf '%s/%s\n' "$(pwd -P)" "$(basename "$1")" )
  fi
}

# repo_toplevel — the git worktree ops-corpus.sh itself lives in, if any.
# Resolved from the script's OWN location, not the caller's cwd, so `--out`
# is checked against the source repo regardless of where the maintainer runs
# this from.
repo_toplevel() {
  script_dir="$(cd "$(dirname "$0")" && pwd -P)"
  (cd "$script_dir" && git rev-parse --show-toplevel 2>/dev/null) || true
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

  # --out must not live inside this script's own repo worktree: the derived
  # tree is the panel's input, and a copy living in the repo means the panel
  # reviews the repo — the neutralization would be a lie.
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

  # Content hash of the SOURCE, computed before any copy — the stamp records
  # what the corpus WAS at build time.
  src_hash="$(corpus_hash "$corpus")"

  MAP="$(read_map "$corpus")"
  [ -n "$MAP" ] || die "$corpus/$MAP_NAME is empty — a map with no entries would build an empty tree and call it success"

  # Refuse a corpus carrying a fixture directory the map does not name, BEFORE
  # writing anything. Silently building a 5-of-6 tree and printing "built" is
  # the #69 shape itself: a plausible tree, a plausible number, and a coverage
  # claim nobody can see is short.
  #
  # Matched on the map's first PATH SEGMENT, not its whole first field: a drift
  # fixture addresses `errno-claim/drifted`, a security fixture addresses
  # `frag-traversal`, and both must satisfy the same "is this fixture covered"
  # question. Comparing whole fields answered it correctly for one corpus shape
  # and refused every fixture of the other.
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

  # Empty <out> before copying. A --force rebuild that merely overwrites leaves
  # every file the previous build wrote and this one does not — a fixture
  # renamed or dropped upstream keeps haunting the tree, which is #69's own
  # failure with extra steps. `find -delete` on the contents, not `rm -rf` on
  # the directory, so a caller's existing (possibly bind-mounted) out dir keeps
  # its identity and permissions.
  mkdir -p "$out"
  find "$out" -mindepth 1 -depth -exec rm -rf {} +

  # --- neutralize (allowlist; see the corpus map) -------------------------
  # sed -i differs between GNU and BSD (macOS) sed: BSD requires an explicit
  # (possibly empty) backup-suffix argument to -i. Detect once.
  if sed --version >/dev/null 2>&1; then
    SED_INPLACE() { sed -i -E "$1" "$2"; }
  else
    SED_INPLACE() { sed -i '' -E "$1" "$2"; }
  fi
  # A here-string, NOT `printf … | while`. A pipeline runs its right-hand side in
  # a SUBSHELL, where `die`'s exit kills only that subshell: the loop's failure
  # would not stop the build, `copied` would keep the parent's value, and the
  # script would go on to stamp and announce a tree missing the file it just
  # refused. Measured on the first shape of this loop. `<<<` keeps the body in
  # the current shell, so `die` aborts the build the way every other guard here
  # does, and `copied` is the count that was actually copied.
  copied=0
  while IFS=' ' read -r dir src dest; do
    [ -n "$dir" ] || continue
    [ -n "$src" ] && [ -n "$dest" ] || die "$MAP_NAME line '$dir $src $dest' is malformed — want: <dir> <source-file> <production-name>"
    # ALL THREE fields are parsed input and all three become path components, so
    # all three are guarded. The first shape guarded only `dest` — the write side
    # — while `dir` and `src` flowed unchecked into the read. Measured: a map line
    # `f1/../.. OUTSIDE.txt leaked.txt` copies a file from outside the corpus into
    # the derived tree, and the comment here claimed parity with "every other
    # parsed-field-becomes-a-path-component guard in this repo" while implementing
    # half of it. Exactly the frag-traversal fixture's own shape, in the script
    # that builds that fixture.
    #
    # The sharpest consequence is not the read itself but what it does to #69's
    # promise: `corpus_hash` walks the CORPUS, so content pulled in from outside
    # it is in no stamp, and `verify` reports ok on a tree carrying files the
    # corpus never held. The staleness guarantee is only as good as the guarantee
    # that every byte in the tree came from the corpus.
    #
    # `dir` may contain `/` (a drift fixture addresses `errno-claim/drifted`), so
    # it is checked for TRAVERSAL rather than for being a bare name; `src` and
    # `dest` are bare filenames.
    case "/$dir/" in
      *"/../"*|*"//"*) die "$MAP_NAME: fixture path '$dir' must not contain '..' or an empty segment" ;;
    esac
    case "$dir" in
      /*) die "$MAP_NAME: fixture path '$dir' must be relative to the corpus, not absolute" ;;
    esac
    case "$src" in
      */*|..|.|"") die "$MAP_NAME: source name '$src' must be a bare filename, not a path" ;;
    esac
    case "$dest" in
      */*|..|.|"") die "$MAP_NAME: production name '$dest' must be a bare filename, not a path" ;;
    esac
    [ -f "$corpus/$dir/$src" ] || die "$MAP_NAME names '$dir/$src', which does not exist in '$corpus'"
    # Regular, non-symlink — the same contract `read_map` applies to the map and
    # `verify` to the stamp, and the repo-wide rule for any file a CLI trusts.
    # `-f` FOLLOWS a symlink and `cp` (no -P) copies the target's CONTENT, so a
    # link planted in the corpus reaches the derived tree with contents from
    # anywhere on disk — the traversal above wearing a different hat, and equally
    # invisible to the stamp.
    [ ! -L "$corpus/$dir/$src" ] || die "$MAP_NAME names '$dir/$src', which is a symlink — refusing (its target is outside the corpus's content hash, so a tree built from it would verify green)"
    [ ! -e "$out/$dest" ] || die "$MAP_NAME maps two fixtures to the same production name '$dest' — the second would overwrite the first and the tree would be short one fixture"
    cp "$corpus/$dir/$src" "$out/$dest"
    # Strip marker lines from the copy. Header prose like "This is the
    # DEFECTIVE variant" is a whole-line tell; the line goes, the code stays.
    if grep -qE "$MARKER_RE" "$out/$dest" 2>/dev/null; then
      SED_INPLACE "/$MARKER_RE/d" "$out/$dest"
    fi
    copied=$((copied+1))
  done <<EOF
$MAP
EOF

  # --- verify neutralization, as its own step, before leaving anything
  # behind (the caller must be able to see it ran).
  hits="$(grep -RlE "$MARKER_RE" "$out" 2>/dev/null || true)"
  if [ -n "$hits" ]; then
    die "neutralization check FAILED — marker(s) still present in: $(printf '%s' "$hits" | tr '\n' ' ')"
  fi
  # The second half of the check, and the one the blocklist shape could never
  # do: nothing from the corpus's OWN vocabulary survives. A file named
  # `vuln.sh`, a README quoting the 2x2 table, a NOTES.md naming the sink — any
  # of them answers the question for the lens.
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
  # A missing stamp and a mismatched stamp are DIFFERENT failures with
  # distinct messages: an unstamped tree is not "fresh", it is of unknown
  # provenance and must be refused just as loudly, but for a different
  # reason a caller needs to be able to tell apart.
  # Exit 3, not 2, and the difference is load-bearing rather than cosmetic: a
  # caller scripting this (a CI step, a measurement runner) must be able to tell
  # "your tree is out of date, rebuild" from "this directory was never built by
  # me, and I have no idea what it is" WITHOUT parsing English. An aborted build
  # leaves exactly the second shape — a partial tree with no stamp — so the two
  # are reachable in one session, which is why one code for both would collapse
  # a real distinction.
  if [ ! -e "$stamp_file" ]; then
    echo "ops-corpus: no stamp found at '$stamp_file' — tree is of UNKNOWN PROVENANCE, refusing (run 'build' to produce a stamped tree)" >&2
    exit 3
  fi
  # Regular, non-symlink only — same discipline this repo applies to every
  # pending/sentinel-shaped file it trusts.
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
