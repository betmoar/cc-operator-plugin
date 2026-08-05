# Decisions — append-only, one line per entry
# <ISO-date> | <engagement.task> | <kind> | <what> | <why>
# kind:
#   gated  (block Stop until presented at handoff): DEVIATION | ESCALATION | GATE-EXCEPTION
#   record (logged, never block Stop):             DECISION | DEFERRED-VERDICT
#   marker (clears the gated set):                 HANDOFF-MARK
