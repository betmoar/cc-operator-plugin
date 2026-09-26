# Spec: sentinel ownership in the body, not the filename

Status: APPROVED

## Goal
Today a pending sentinel's owner is encoded in its filename (`pending/<sid>__<task>`). Six readers
hand-copy the parser that splits on the first `__`; two of them (ops-stop-hook.sh, statusline.sh)
must stay bash-builtin-only. Decide whether ownership should move into a body field
(`owner=<sid>`), and if yes, carry the change through.

## Requirements
1. Decide filename-vs-body ownership. The decision must weigh: the six hand-copied readers, the
   builtin-only constraint, the O_EXCL open in ops-task.sh, the legacy migration in
   ops-sessionstart-hook.sh, and that an unowned sentinel must keep failing CLOSED. Record the
   decision and the rejected option in DECISIONS.md.
2. If body ownership wins: change ops-task.sh, ops-adopt.sh and ops-verdict.sh to write the field,
   and the three readers' sentinel_owner_of_name() to read it, keeping the bounded read and the
   `-L` before `-f` type test.
3. Add red-first cases to tests/test-scripts.sh for: owned, unowned (blocks), foreign (reports).
4. Bump plugin.json to 0.13.0 and add the matching CHANGELOG heading.
5. Raise FLOOR_SHELL in tests/floors.env by the number of cases added.
