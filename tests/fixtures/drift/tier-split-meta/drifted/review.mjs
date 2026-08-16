// meta.description: "Runs five lenses, most at cheap tiers and two at
// judgment tier: feasibility and quality."
export const meta = {
  description:
    "Runs five lenses, most at cheap tiers and two at judgment tier: " +
    "feasibility and quality.",
};

export const LENSES = [
  { name: "spec", tier: "mechanical" },
  { name: "testability", tier: "mechanical" },
  { name: "feasibility", tier: "judgment" },
  { name: "quality", tier: "judgment" },
  { name: "correctness", tier: "judgment" },
];
