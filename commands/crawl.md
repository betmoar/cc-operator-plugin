---
description: Run the crawl workflow — one cheap crawler seat per shard in parallel, then a judgment-tier merge — to digest a large corpus without paying judgment tier for the reading.
argument-hint: "<what to digest, and where>"
allowed-tools: Bash(bash "${CLAUDE_PLUGIN_ROOT}"/scripts/ops-tiers.sh:*), Bash(git:*), Bash(wc:*), Bash(ls:*), Workflow
---

Digest `$ARGUMENTS` with the crawl workflow.

1. **Pack the shards yourself.** The workflow fans one crawler per shard and
   merges; deciding what goes in each shard is the operator's job, because only
   you know which files belong together. Aim for ~150K characters per shard and
   keep WHOLE files in one shard — a file split across two shards is read twice
   and understood by neither.

2. **Resolve the tier bindings** — one line of JSON, passed through verbatim:

   ```
   bash "${CLAUDE_PLUGIN_ROOT}"/scripts/ops-tiers.sh --json
   ```

3. **Dispatch:**

   ```
   Workflow({ name: "cc-operator:crawl", args: {
     shards: [ { paths: ["a.js", "b.js"], focus: "<what to look for>" }, … ],
     question: "<the question the merge must answer>",
     tiers: <the JSON from step 2> } })
   ```

**A dead crawler is lost coverage, not an empty shard.** The return reports
which shards failed; a merge over a partial fan-out answers the question about
the corpus it actually read. Say which shards are missing when you relay it.
