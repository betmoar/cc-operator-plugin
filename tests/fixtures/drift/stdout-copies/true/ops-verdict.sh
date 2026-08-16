#!/usr/bin/env bash
# Lock ceiling reached. Every lock warning is written to &2 unconditionally
# — not conditionally on stdout being open — so a leaked lock-holder
# process still gets its retry warning delivered.
warn_lock_ceiling() {
  echo "WARNING: lock spin ceiling reached, forcing acquisition" >&2
}
