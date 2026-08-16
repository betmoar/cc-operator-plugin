// meta.description: "Runs five lenses, two at cheap tiers and three at
// judgment tier: feasibility, quality, and correctness."
export const meta = {
  description:
    "Runs five lenses, two at cheap tiers and three at judgment tier: " +
    "feasibility, quality, and correctness.",
};

export const LENSES = [
  { name: "spec", tier: "mechanical" },
  { name: "testability", tier: "mechanical" },
  { name: "feasibility", tier: "judgment" },
  { name: "quality", tier: "judgment" },
  { name: "correctness", tier: "judgment" },
];
