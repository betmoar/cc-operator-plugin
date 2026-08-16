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
#
# A HASH THAT CANNOT FAIL LOUDLY IS NOT A STAMP. `set -e` does not see a failure
# inside a non-final pipeline stage, and the final stage here (`shasum | awk`)
# exits 0 whatever bytes reached it — so an unreadable file, or a `find` that
# died halfway, produced a hash over a SHORT corpus and returned success.
# Measured. That is a third state the design never accounted for: not the clean
# hash, not the empty-corpus hash, but a plausible one — and because it is
# deterministic, `verify` recomputes the same wrong value and prints "ok". #69's
# entire promise is that staleness becomes an error rather than a plausible
# number, and this was a plausible number inside the mechanism that makes it.
#
# So: every file is read into the stream by an EXPLICIT loop whose failures the
# caller sees, and the file list is materialized first so `find`'s own exit
# status is checkable. Not `set -o pipefail`: this file targets bash 3.2 where it
# exists, but the shape below states the intent locally instead of relying on a
# shell option a future edit could drop from the top of the file.
corpus_hash() {
  corpus="$1"
  _ch_list="$(mktemp "${TMPDIR:-/tmp}/opscorp.XXXXXX")" || die "cannot create a temp file for the corpus listing"
  # NUL-separated, and both reasons are measured failures of the line-based
  # shape this replaces (REPLAY-CHARTER R7, 2026-08-16, adversarial seat):
  #
  #   1. `if ! find … | sort > list` tests the LAST stage. `sort` succeeds on a
  #      partial stream, so `find`'s own failure — an undescendable subdirectory,
  #      a corpus that vanished mid-walk — was invisible, and the build printed
  #      "built" and a stamp over a SHORT corpus. Measured: `find <missing> |
  #      sort` reports NOT CAUGHT, and a `chmod 000` subdir produced a green
  #      build AND a green verify with `find: Permission denied` on stderr. That
  #      is exactly the plausible-hash state the comment above claims was closed.
  #   2. The newline guard was VACUOUS. It compared `grep -c ''` of the list
  #      against `grep -c ''` of the same `find -print` output — a filename with
  #      a newline splits into two lines on BOTH sides, so the counts always
  #      matched. Measured on a 2-file corpus containing `a<LF>b.txt`: lines=3,
  #      files=3, equal, no refusal. A real file count needs `-print0`.
  #
  # `find … -print0` into a temp file, with the redirection OUTSIDE any pipe, so
  # `find`'s exit status is the one `set -e`/the `if` actually sees. The sort
  # then reads that file, so its status is separately checkable too.
  if ! find "$corpus" -type f -print0 > "$_ch_list.raw"; then
    rm -f "$_ch_list" "$_ch_list.raw"
    die "cannot list '$corpus' — refusing to stamp a hash over a partial corpus"
  fi
  # LC_ALL=C: a byte-order sort, not a locale-dependent one — the same hash must
  # come out on any machine that runs this script. `-z` keeps the NUL framing.
  if ! LC_ALL=C sort -z < "$_ch_list.raw" > "$_ch_list"; then
    rm -f "$_ch_list" "$_ch_list.raw"
    die "cannot sort the listing of '$corpus' — refusing to stamp a hash from an unordered walk"
  fi
  # A newline in a filename would split one hash record into two and silently
  # change the hash of an unchanged corpus. Now genuinely detectable: NUL-counted
  # entries vs newline-counted ones differ exactly when a name contains a newline.
  _ch_files="$(tr -dc '\0' < "$_ch_list" | wc -c | tr -d '[:space:]')"
  _ch_lines="$(tr '\0' '\n' < "$_ch_list" | grep -c '' || true)"
  # tr appends a trailing newline per record, so a clean corpus gives
  # lines == files; a newline in a name pushes lines above files.
  if [ "$_ch_lines" != "$_ch_files" ]; then
    rm -f "$_ch_list" "$_ch_list.raw"
    die "'$corpus' contains a filename with a newline — refusing (it would split one hash record into two)"
  fi
  {
    while IFS= read -r -d '' f; do
      # No `[ -r ]` here, deliberately: a permission test is INERT for uid 0
      # (root bypasses mode bits), so it would report "readable" for the one uid
      # that then reads everything anyway — a guard that is either redundant or
      # absent depending on who runs it, which is #21's class and which
      # validate_plugin.check_permission_tests refuses. The reads themselves are
      # the test, and they hold on every uid: `wc -c` and `cat` fail on a file
      # this process cannot read, whoever this process is, and `|| die` turns
      # that into an abort instead of a short hash.
      sz=$(wc -c < "$f" | tr -d '[:space:]') || die "cannot read '$f' — refusing to stamp a hash that skips it"
      [ -n "$sz" ] || die "cannot size '$f' — refusing to stamp a hash with an empty length field"
      printf '%s\n%s\n' "${f#"$corpus"/}" "$sz"
      cat "$f" || die "cannot read '$f' — refusing to stamp a hash that skips it"
      printf '\n'
    done < "$_ch_list"
  } > "$_ch_list.stream" || { rm -f "$_ch_list" "$_ch_list.raw" "$_ch_list.stream"; exit 2; }
  hash_stream < "$_ch_list.stream"
  rm -f "$_ch_list" "$_ch_list.raw" "$_ch_list.stream"
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
    # `A && B || C`, which this was, is NOT if-then-else: C also runs when A is
    # true and B is false — here that is the correct outcome by luck, not by
    # construction, and the next edit to the condition would not be. Spelled as
    # a real `if` so the guard means what it reads as (shellcheck SC2015, seen
    # by CI's pinned 0.10.0 and NOT by a newer local shellcheck — run the
    # container command from .github/workflows/validate.yml, not `shellcheck`).
    if [ -z "$src" ] || [ -z "$dest" ]; then
      die "$MAP_NAME line '$dir $src $dest' is malformed — want: <dir> <source-file> <production-name>"
    fi
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
    #
    # THE STRING CHECKS BELOW ARE NECESSARY AND NOT SUFFICIENT, and the gap cost
    # a second round: the first fix rejected `..` in `dir` and a symlinked LEAF
    # file, and left a symlinked DIRECTORY wide open. `ln -s /outside corpus/d`
    # with a map line `d secret.txt leaked.txt` copies from outside the corpus,
    # and — the part that matters — `corpus_hash`'s `find` (no `-L`) does not
    # descend the link, so the content is in no stamp and `verify` prints ok.
    # Measured, exactly the same escape and the same green verify the previous
    # round's fix was written to close, through the one field-as-path-component
    # case it did not cover.
    #
    # So the string checks stay (they give a precise message for the common typo)
    # and the RESOLVED path is what decides. `cd + pwd -P` resolves every symlink
    # in every component, and the resolved fixture dir must sit under the
    # resolved corpus — the same discipline `repo_toplevel`/`realpath_of` already
    # apply to `--out`, now applied to the read side too.
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
      # The trailing-slash form is what stops `/corpus-2` from passing a check
      # meant for `/corpus`; the bare form allows `dir` resolving to the corpus
      # root itself, which a map may legitimately do.
      "$_real_corpus"|"$_real_corpus"/*) ;;
      *) die "$MAP_NAME: fixture path '$dir' resolves to '$_real_dir', outside the corpus '$_real_corpus' — refusing (a symlinked component would pull in content the stamp never covers, and verify would report ok)" ;;
    esac
    case "$src" in
      */*|..|.|"") die "$MAP_NAME: source name '$src' must be a bare filename, not a path" ;;
    esac
    case "$dest" in
      */*|..|.|"") die "$MAP_NAME: production name '$dest' must be a bare filename, not a path" ;;
      # The stamp filename is RESERVED, and the collision is #69's own shape:
      # the copy succeeds, then the stamp write at the end of build overwrites
      # that mapped artifact with the hash — so the build announces the full
      # count while shipping a tree one file short, and `verify` reports ok
      # because the stamp it reads is exactly the one it expects. Measured: a
      # map with `f1 b.sh .ops-corpus-stamp` printed "built ... 2 file(s)",
      # left one file, and verified green. A plausible number again, this time
      # inside the mechanism built to replace plausible numbers with errors.
      "$STAMP_NAME") die "$MAP_NAME: production name '$dest' is reserved — build writes the corpus hash there, so a mapped file of that name would be silently overwritten and the tree would be one file short while verify still passed" ;;
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
