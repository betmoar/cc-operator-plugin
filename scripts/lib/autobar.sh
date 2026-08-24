# shellcheck shell=bash
# shellcheck disable=SC2034  # the autobar_* globals are consumed by the SOURCING script
# lib/autobar.sh — the ONE implementation of the auto-arm rule (#85).
#
# WHAT IT CLOSES. Until now the evidence gate was opt-in at the MECHANISM level:
# ops-task.sh opens a sentinel, ops-stop-hook.sh blocks while one is pending —
# but nothing opened one. A session that simply never ran ops-task.sh stopped
# clean, however many files it rewrote. The charter says a BAR block is REQUIRED
# for multi-file work (templates/OPERATOR.md, ENGAGEMENT CONTRACT clause 1), and
# a rule the mechanism declines to enforce is prose.
#
# WHY THE FILESYSTEM AND NOT THE TOOL STREAM. The property is "files changed",
# not "Write/Edit was called". A PostToolUse counter is blind to every
# Bash-mediated write — sed -i, a heredoc, patch, a build script, a subagent —
# and its undercount is SILENT: it reports zero, which is byte-identical to a
# session that changed nothing. That is not a smaller hole than today's, it is
# the SAME hole behind a counter that reports green. A working-tree delta sees
# every one of them regardless of which tool made it. (The tool channel is also
# unmeasured here: ops-compress.mjs reads tool_input.command/pattern/path and
# never file_path, and the PostToolUse matcher excludes Write|Edit entirely, so
# a stable path field is an assumption no line in this repo has ever tested.)
#
# WHAT IT COSTS, STATED RATHER THAN PAPERED OVER. git-only (no VCS → arm
# nothing, exactly as source_stamp already degrades to @no-vcs); it cannot
# attribute a change to a session, which is what the suppression rule below
# pays for; and it is a proxy — a session can satisfy it by opening one
# throwaway task and deferring it. It is an honesty rail against forgetting,
# not a sandbox against a hostile agent. The threat model is drift, which is
# the observed failure — not evasion, which is not.
#
# POLARITY — fail OPEN everywhere, and that is the opposite of the sentinel
# default in partition.sh. Both are right: an unowned sentinel is a REAL open
# task (fail closed), whereas an unreadable baseline or an absent git is a
# SCAFFOLD problem, and arming on it would block an honest session on the
# strength of a measurement that did not happen. A gate that blocks the honest
# gets disabled by the user, and a disabled gate protects nothing.

# The threshold IS the charter's ENGAGEMENT CONTRACT clause (1): "the change
# touches more than one file". A count, never a judgment — deliberately not the
# done-state clause, which would mean classifying the user's prose and is a
# false-positive factory. Clauses (2) multi-session and (3) user-named done
# stay UNCOVERED by design; the charter still asks for them, this arms for one.
AUTOBAR_MIN_PATHS=2
# The task id the armer opens. Fixed, so a second arm in the same session is
# the same sentinel (O_EXCL already treats a pre-existing regular file as a
# legit already-open) and the operator sees one obligation, not one per fire.
AUTOBAR_TASK="autobar"

# Count DISTINCT changed project paths, excluding the gate's own bookkeeping.
# `--porcelain -- ':(exclude).operator'` is the primitive source_stamp already
# uses (ops-verdict.sh) — the exclusion is not decoration: counting .operator/
# would pin every session to armed the moment it wrote a verdict row (#21's
# class, one layer down).
#
# -z is load-bearing. Porcelain's default output quotes and backslash-escapes a
# path with a space or a newline in it; a rename prints "old -> new" on ONE
# line. Counting lines there mis-counts both directions. With -z every entry is
# NUL-terminated verbatim, and a rename emits its two paths as two records —
# which is correct for this question: a rename touched two paths.
#
# Sets: autobar_paths (count), autobar_measured (1 = the delta is trustworthy,
# 0 = do not arm on it).
autobar_count_changed() { # autobar_count_changed <project-root>
  local root="$1" n=0 rec
  autobar_paths=0
  autobar_measured=0
  [ -d "$root" ] || return 0
  # Repo check FIRST, as a SEPARATE call, and it is the load-bearing one: the
  # counting read below goes through process substitution, which carries no
  # exit status, so without this "not a repo" and "a clean repo" both arrive as
  # zero records and unmeasured reads as clean. It also covers a missing git
  # binary — a `command -v git` line beside it was measured to be unreachable
  # (deleting it changed no test; deleting this one failed four), and a guard no
  # test can reach is a guard nobody knows works.
  git -C "$root" rev-parse --git-dir >/dev/null 2>&1 || return 0
  # PROCESS substitution, never `$(…)`. Command substitution DELETES NUL bytes
  # (measured, bash 3.2.57: a three-entry -z porcelain came back with every \0
  # stripped and the read loop counted 0 — silently, which is the exact
  # failure class this file exists to avoid). A pipe would put the loop in a
  # subshell and lose the count on the way out. `< <(…)` keeps both the NULs
  # and the variable.
  while IFS= read -r -d '' rec; do
    [ -n "$rec" ] || continue
    n=$((n + 1))
  done < <(git -C "$root" status --porcelain -z -- ':(exclude).operator' 2>/dev/null)
  autobar_paths="$n"
  autobar_measured=1
}

# Porcelain measures the TREE, not the SESSION. Two sessions in one worktree see
# each other's changes, so the honest one would be armed for work it never did —
# blocked on someone else's diff, with no way to tell. Attribution is exactly
# what a filesystem delta does not have, so this pays for it with COVERAGE
# instead of cleverness: a sign of another session working here and the armer
# stands down. Never block an innocent session; lose the arm instead.
#
# ONE signal, and the first version had two. The second was a foreign
# `verdicts.d/<sid>.md` fragment, on the reasoning that a session which opened,
# verdicted and cleared still left its diff in our porcelain count. True, but
# fragments are APPEND-ONLY and nothing wipes them (ops-verdict.sh appends with
# `>>`; ops-sessionstart-hook.sh clears only .autobar/ and the compressor
# ephemera). So one honest verdict recorded by any other session, EVER, stood
# the armer down for the rest of the project's life — silently, and hardest in
# the mature projects the gate most protects. Measured 2026-08-24: a foreign
# session records one PASS and exits; the next session changes two files and
# gets arm=0. (Found by a debate panel reviewing the commit that introduced it.)
#
# The category error: `pending/` is LIVE state, `verdicts.d/` is an ARCHIVE.
# Reading an archive as a presence signal is what made suppression permanent.
#
# An mtime clock was tried as the fix and REMOVED, because it cannot work here:
# bash 3.2 compares whole SECONDS (measured — a fragment written 47ms after the
# epoch, .218 vs .171, read as "not newer"), so stale and concurrent are
# indistinguishable inside one second. The repo's own primitive for this is
# liveness, not time — `ops-verdict.sh`'s lock asks `kill -0` and its comment
# says why: "waiters ask the KERNEL, not the clock (F03)". Fragments carry no
# pid, so liveness cannot be asked of them either.
#
# So the fragment signal is GONE and the residual is stated rather than papered
# over: a foreign session that opened a task, recorded its verdict and exited
# leaves its diff in our porcelain with nothing to attribute it by, and we may
# arm for it. That is a bounded false positive — one arm, clearable with one
# --defer — against what it replaced, which was the gate silently never firing
# again. An OPEN foreign sentinel is still live state and still suppresses.
# Sets: autobar_foreign (1 = stand down).
autobar_foreign_activity() { # autobar_foreign_activity <opdir> <this-session>
  local opdir="$1" sess="$2" f name owner
  autobar_foreign=0
  shopt -s nullglob
  for f in "$opdir/pending"/*; do
    [ -f "$f" ] || continue
    name="${f##*/}"
    # sentinel_owner_of_name comes from partition.sh — the SAME parser the gate
    # and the bar use. A second copy here would be a fourth site of the rule
    # check_guard_parity exists to pin.
    owner="$(sentinel_owner_of_name "$name")"
    if [ -n "$owner" ] && [ "$owner" != "$sess" ]; then
      autobar_foreign=1
      break
    fi
  done
  shopt -u nullglob
}

# ARM ONCE PER SESSION, and this is the invariant the whole feature turns on.
# The armer runs at Stop, so the obvious shape — "delta >= 2 and no sentinel
# open → arm" — is an INFINITE BLOCK: the operator records the verdict, the
# sentinel clears, Stop fires again, the delta is still >= 2 (recording a
# verdict does not un-change the files), and it arms a second time. Forever.
# A session that cannot stop is worse than one that stops unaudited, and it is
# the failure mode a user resolves by deleting the plugin.
#
# So the marker records "this session has been armed", and it must OUTLIVE the
# sentinel it opened — that is exactly what the sentinel itself cannot do,
# since clearing it is the point. Directory, one file per sid: /clear rotates
# the id, so ops-sessionstart-hook.sh wipes the tree on every fire the way it
# already wipes the compressor ephemera.
autobar_already_armed() { # autobar_already_armed <opdir> <this-session>
  local opdir="$1" sess="$2"
  [ -n "$sess" ] || return 0                       # unattributable → treat as armed (stand down)
  [ -f "$opdir/.autobar/$sess" ]
}

# Best-effort: a marker we fail to write means the next Stop re-arms, which is
# the infinite block above. So a FAILED mark is reported by the caller and the
# arm is abandoned — never armed-but-unmarked.
autobar_mark_armed() { # autobar_mark_armed <opdir> <this-session>
  local opdir="$1" sess="$2"
  [ -n "$sess" ] || return 1
  mkdir -p "$opdir/.autobar" 2>/dev/null || return 1
  # A symlink here would let a planted link redirect the write; refuse it the
  # way every other writer in this repo refuses a non-regular target.
  [ -L "$opdir/.autobar/$sess" ] && return 1
  : > "$opdir/.autobar/$sess" 2>/dev/null || return 1
  return 0
}

# The whole decision, in one call, so the hook has no policy of its own.
# Sets autobar_arm (1 = open the sentinel) plus the inputs behind it, so a
# caller can SAY WHY rather than only what — a gate that arms without naming
# its reason is the thing the operator disables.
autobar_decide() { # autobar_decide <project-root> <opdir> <this-session>
  local root="$1" opdir="$2" sess="$3"
  autobar_arm=0
  autobar_reason=""
  # No session id: every sentinel reads unowned, so we can tell neither our own
  # work from another session's nor stamp an owner onto what we would arm.
  # Stated as its own outcome rather than left to fall out of already_armed's
  # empty-sid branch — an implied stand-down is one no test can distinguish
  # from a clean tree.
  if [ -z "$sess" ]; then
    autobar_reason="no session id in the payload — nothing to attribute or stamp an owner with"
    return 0
  fi
  # Cheapest test first, and the one that prevents the infinite block: if this
  # session was already armed, the obligation is recorded and clearing it is
  # the operator's job, not a reason to arm again.
  if autobar_already_armed "$opdir" "$sess"; then
    autobar_reason="already armed this session"
    return 0
  fi
  autobar_count_changed "$root"
  if [ "$autobar_measured" = 0 ]; then
    autobar_reason="unmeasured (no git, or the working tree could not be read) — arming nothing"
    return 0
  fi
  if [ "$autobar_paths" -lt "$AUTOBAR_MIN_PATHS" ]; then
    autobar_reason="$autobar_paths changed path(s), below the $AUTOBAR_MIN_PATHS-path threshold"
    return 0
  fi
  autobar_foreign_activity "$opdir" "$sess"
  if [ "$autobar_foreign" = 1 ]; then
    autobar_reason="another session is working in this tree — the delta cannot be attributed, standing down"
    return 0
  fi
  autobar_arm=1
  autobar_reason="$autobar_paths changed path(s) with no foreign activity"
}
