# Pipeline — scope, boundaries, and what belongs where

> **Guiding principle:** Step is the base product. Pipeline is an optional extension.
> A Step is a simple pipeline with one step. Pipeline adds value only when there is more than one step.

## Core architecture rule

Everything that makes sense for a single LLM call belongs in **Step**. Pipeline exists solely to compose multiple Steps and provide value that emerges from composition. If a feature can live in Step, it MUST live in Step.

## What Pipeline SHOULD have

### Tier 1: Core (must have — defines Pipeline's reason to exist)

1. **Data threading** — output of step N becomes input of step N+1. Does not exist in a single step. This is the fundamental value of Pipeline.

2. **Fail-fast across steps** — when a step fails, halt the entire pipeline. Step has its own internal fail-fast (reject bad input before LLM call), but cross-step fail-fast is a composition concern.

3. **Aggregated result** — `Pipeline::Result` with `outputs_by_step`, rolled-up status, `failed_step`. A single step produces one result; a pipeline produces a structured view across all steps.

4. **Pipeline-level trace** — unified trace ID across all steps, total latency (wall clock for the whole pipeline), total token cost summed across all steps. Step trace captures one call; pipeline trace captures the whole flow.

### Tier 2: High business value (next iteration)

5. **Conditional branching** — "if step A returns intent=billing, route to BillingFlow; otherwise route to SalesFlow". Router pattern. Does not make sense in a single step. Essential for real production workflows where the next action depends on LLM output.

6. **Data transformers between steps** — lightweight Ruby transforms (map, select, merge, reshape) between steps without an LLM call. Avoids creating artificial Step subclasses just to reformat data. Example: step 1 returns `{entities: [...]}`, step 2 expects a plain array — a transformer extracts it.

7. **Cross-step data access** — step 3 needs the output of step 1, not just step 2. Linear threading (N → N+1) is too restrictive for many real workflows. Enables patterns like "enrich step 1's output with step 3's analysis".

8. **Pipeline-level eval** — end-to-end quality evaluation of the whole pipeline. Step eval tests one step in isolation; pipeline eval tests whether the composed flow produces correct final output. Different metric, different value.

9. **Cost budgeting** — total token limit across all steps in a pipeline run. "Don't spend more than 10k tokens on this entire flow." A single step doesn't know about its neighbors' budgets. Enables cost-aware orchestration.

### Tier 3: Future (DAG territory)

10. **Parallel execution** — independent steps run concurrently. Only relevant when the pipeline is a DAG, not a linear chain. Example: extract entities and sentiment in parallel, then merge.

11. **Fan-out / fan-in** — one input fans out to multiple steps, results are merged back. Example: "analyze this text from 3 different perspectives, then synthesize". Requires a merge strategy.

12. **Checkpointing / resume** — pipeline failed at step 4 of 7, resume from step 4 without re-running steps 1-3. Valuable when LLM calls are expensive and earlier steps are deterministic or idempotent.

## What Pipeline MUST NOT have (Step territory — forever)

These are per-step concerns. Pipeline must never own or override them:

- **Retry policy** — retrying is a per-step concern. Model escalation, attempt limits, retryable statuses — all Step. Pipeline should not retry the whole flow (too expensive, too unpredictable).
- **Output schema** — declares the structure of one step's output. Per-step contract.
- **Contract / invariants** — validates one step's output against business rules. Per-step.
- **Prompt construction** — builds the prompt AST for one LLM call. Per-step.
- **Model selection** — which model to use for one call. Per-step (escalation lives in retry policy).

## Debatable / needs decision

| Feature | Argument for Pipeline | Argument for Step | Recommendation |
|---------|----------------------|-------------------|----------------|
| **Cross-step invariants** ("output of step 1 and step 3 must be consistent") | True composition concern — validates relationships between steps | Can be implemented as a final validation Step | Lean toward Pipeline, but could be a plain Step that takes multiple inputs |
| **Pipeline-level retry** (retry the whole pipeline from scratch) | Useful for idempotent pipelines | Too expensive for most cases; per-step retry is sufficient | Don't build. Per-step retry handles 95% of cases. |
| **Timeout** (total wall-clock limit for entire pipeline) | "This pipeline must complete in 30s" | Per-step timeout might suffice | Build in Pipeline. Per-step timeout can't enforce a total budget. |
| **Middleware / hooks** (before/after each step in pipeline) | Cross-cutting: logging, metrics, auth token refresh | Can live in adapter layer | Defer. Adapter hooks cover most cases. Revisit if real demand emerges. |

## Implementation priority

### Now (current state)
- [x] Data threading (linear, output N → input N+1)
- [x] Fail-fast across steps
- [x] Aggregated result (`Pipeline::Result`)

### Next
- [ ] Pipeline-level trace (unified trace ID, total latency, total cost)
- [ ] Conditional branching (router step)
- [ ] Data transformers (lightweight Ruby lambdas between steps)
- [ ] Total timeout

### Later
- [ ] Cross-step data access (step 3 reads step 1's output)
- [ ] Pipeline-level eval
- [ ] Cost budgeting

### Much later (DAG)
- [ ] Parallel execution
- [ ] Fan-out / fan-in
- [ ] Checkpointing / resume

## Relationship to real-world case

The Reddit Promo Planner case (`docs/ideas/05_real_case_reddit_promo_planner.md`) has a diamond-shaped workflow that would benefit from:
- Conditional branching (route by subreddit type)
- Cross-step data access (final step needs both research and draft outputs)
- Fan-out / fan-in (research multiple subreddits in parallel)

Linear Pipeline covers the happy path. DAG Pipeline covers the full case.

## Decision needed

This document should inform an ADR that formally establishes:
1. The Step-first principle as architectural law
2. The boundary between Step concerns and Pipeline concerns
3. The implementation roadmap for Pipeline features
