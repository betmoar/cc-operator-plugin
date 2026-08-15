- fixed: lock-ceiling warnings are now written to stderr instead of a
  closed stdout, so a leaked lock-holder process no longer loses its
  warning silently.
