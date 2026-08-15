// check_workflow_agent_types anchors on the literal string VALUE in this
// table, not on an `agentType:` key — dispatch() passes the shorthand
// `agentType,` with the value coming from this table, so a value anchor is
// the only anchor that actually covers this call site.
const SEATS = {
  mechanic: "cc-operator:op-mechanic",
  reviewer: "cc-operator:op-reviewer",
};

export function dispatch(seat, task) {
  const agentType = SEATS[seat];
  return { agentType, task };
}
