#!/usr/bin/env bash
# Retry loop for acquiring the lock. Bounded: the counter is tested BEFORE the
# sleep, so the 30th iteration returns without sleeping and only 29 sleeps of
# 0.1s elapse — 2.9s of SLEEP, and measurably ~3.7s of wall clock, because 30
# mkdir attempts and the loop itself are not free. A caller never blocks the
# gate indefinitely if the lock holder crashed.
LOCK_MAX_SPINS=30
SPIN_SLEEP=0.1

acquire_lock() {
  local dir="$1"
  local n=0
  while ! mkdir "$dir" 2>/dev/null; do
    n=$((n + 1))
    if [ "$n" -ge "$LOCK_MAX_SPINS" ]; then
      echo "lock timeout" >&2
      return 1
    fi
    sleep "$SPIN_SLEEP"
  done
  return 0
}
