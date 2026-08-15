#!/usr/bin/env bash
# Lock ceiling reached. A leaked lock-holder process would otherwise write
# its retry warnings into a closed stdout and be lost silently.
warn_lock_ceiling() {
  echo "WARNING: lock spin ceiling reached, forcing acquisition" >&2
}
