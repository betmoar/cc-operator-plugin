---
description: Resolve a model id for a tier or seat.
---

# /cc-operator:tiers

| step | what happens |
| --- | --- |
| 1 | read `tiers.env` for a `tier=model` or `seat=tier` line |
| 2 | resolve the alias to a concrete model id |
| 3 | check the id is well-formed (no whitespace, no quotes, non-empty) —
that is the only validation; the id shape is not judged |
| 4 | print the resolved id |
