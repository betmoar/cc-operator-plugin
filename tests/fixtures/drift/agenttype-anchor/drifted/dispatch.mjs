// A computed agentType is invisible to check_workflow_agent_types, because
// that check anchors on the `agentType:` key — concatenation would let a
// typo'd seat ship green undetected.
const SEATS = {
  mechanic: "cc-operator:op-mechanic",
  reviewer: "cc-operator:op-reviewer",
};

export function dispatch(seat, task) {
  const agentType = SEATS[seat];
  return { agentType, task };
}
