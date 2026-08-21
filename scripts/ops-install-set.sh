# shellcheck shell=bash
# The .operator/bin install set — THE single declaration (#76 step 3).
#
# Sourced by the two writers that copy gate CLIs into a project:
#   - ops-init.sh              (the authoritative install, /cc-operator:start)
#   - ops-sessionstart-hook.sh (the automated upgrade path, every session)
#
# Until 0.9.0 each writer carried its own copy of this list and
# check_install_set_parity pinned them equal (CR4: a fifth CLI added to one
# and not the other shipped green, and every upgraded project silently never
# received it). One declaration removes the drift instead of policing it; the
# validator now pins that both writers SOURCE this file and iterate the
# variable, and that this file stays a plain single assignment it can read.
#
# NOT the same set as the compressor's GATE_CLIS / the validator's
# CHARTER_REQUIRED_CLIS (4 entries, no ops-backlog.sh): those list the CLIs the
# charter references, this lists what gets installed. ops-backlog.sh is
# installed but deliberately not charter-required.
_OPS_TOOLS="ops-verdict.sh ops-task.sh ops-adopt.sh ops-claims.sh ops-backlog.sh"
