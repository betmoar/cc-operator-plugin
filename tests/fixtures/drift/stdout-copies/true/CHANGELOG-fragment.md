- fixed: lock-ceiling warnings are now written to `&2` unconditionally, so
  a leaked lock-holder process still gets its retry warning delivered.
