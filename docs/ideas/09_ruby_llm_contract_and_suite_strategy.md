# RubyLLM Contract + Suite Strategy

## Goal

Define the best product strategy for two related products:

1. `ruby_llm-contract`
2. `ruby_llm-suite`

The key question is not just naming. It is product shape:

- what should live in `ruby_llm-contract`
- what should be included in `ruby_llm-suite` on day 1
- which RubyLLM ecosystem gems are mature enough to depend on
- which capabilities still need to stay custom

## Executive Summary

Best path:

1. Build `ruby_llm-contract` as the primary product.
2. Position it as the contract-first execution layer for RubyLLM applications.
3. Build `ruby_llm-suite` as a curated umbrella/meta-gem, not as a monolithic framework.
4. Include only the most stable, best-fitting ecosystem pieces in `ruby_llm-suite` at launch.
5. Keep evals custom for now.

Short version:

- `ruby_llm-contract` = sharp product
- `ruby_llm-suite` = curated bundle

## What The RubyLLM Ecosystem Already Has

### Strong ecosystem pieces

These are the best current fits in the RubyLLM ecosystem:

- `ruby_llm`
  - core provider/runtime layer
  - model access
  - pricing/model registry
  - multi-provider transport

- `ruby_llm-schema`
  - strongest fit for structured output and schema definition
  - already aligned with RubyLLM mental model
  - widely reused in the ecosystem

- `ruby_llm-instrumentation`
  - official event layer via ActiveSupport notifications

- `ruby_llm-monitoring`
  - official monitoring/dashboard layer above instrumentation
  - useful operationally, but heavier and more opinionated than schema/instrumentation

### Useful but not core-at-launch pieces

- `ruby_llm-template`
  - useful for prompt file/template organization
  - but not required for contract-first runtime
  - can overlap with a native prompt DSL

### Weak or immature fit for current strategy

- `ruby_llm-evals`
  - strategically interesting
  - but too early to treat as a core dependency
  - unclear whether its model aligns with a contract-first `Step` abstraction

- `rubyllm-observ`
  - useful and relevant
  - but it is a community Rails engine with broader UI/product ambitions
  - less ideal as a foundational dependency than official instrumentation/monitoring

## What Existing Community Gems Do Not Provide

This is the main strategic opening.

There is no ecosystem gem that cleanly provides:

- a single-step execution abstraction
- post-call contract validation
- preflight execution limits
- retry based on contract quality
- testable step semantics
- eval semantics tied to the same step abstraction
- one coherent "prompt becomes an application unit" mental model

The ecosystem has the pieces, but not the middle layer.

That missing middle is the opportunity for `ruby_llm-contract`.

## Recommended Product Boundary

## `ruby_llm-contract`

This should be the main product.

Its promise should be simple:

> Turn a RubyLLM call into a contracted, validated, testable step.

### In scope

- step abstraction
- prompt DSL
- `validate`
- output contract semantics
- integration with `ruby_llm-schema`
- retry based on contract quality
- preflight limits like `max_input`, `max_cost`, `max_output`
- basic trace/result objects
- testing helpers and RSpec matchers
- lightweight pipeline only if it remains step-first

### Why this product matters

It creates the layer that does not yet exist in the RubyLLM ecosystem:

- not just schema
- not just observability
- not just templates
- not just eval datasets

It gives developers a runtime unit with guarantees.

## `ruby_llm-suite`

This should not be a new giant framework.

It should be:

- a meta-gem
- or a thin integration bundle
- with a strong install story and documentation

Its promise:

> The curated batteries-included stack for RubyLLM apps.

## What must be included in `ruby_llm-suite` at launch

These are the best day-1 components:

- `ruby_llm-contract`
- `ruby_llm-schema`
- `ruby_llm-instrumentation`

### Why these four

Together they form a coherent stack:

- execute
- contract
- schema
- observe

That is enough for a real product story without overreaching.

`ruby_llm-monitoring` is a strong optional addon, but it should not be treated as equally foundational on day 1.

## What should not be mandatory in `ruby_llm-suite` at launch

### `ruby_llm-template`

Do not make it mandatory initially.

Why:

- it is useful, but not universal
- it can conflict with a built-in prompt DSL mental model
- it is an authoring style choice, not a required runtime foundation

Best status:

- optional addon
- later integration

### `ruby_llm-evals`

Do not make it a foundation of the suite on day 1.

Why:

- too early in maturity
- not yet clearly the canonical evaluation layer
- unclear fit with a contract-first step abstraction
- likely to force your eval model into someone else's shape too early

Best status:

- evaluate later
- do not depend on it strategically yet

### `ruby_llm-monitoring`

Do not make it mandatory in the first version of `ruby_llm-suite`.

Why:

- it is more operationally opinionated than schema/instrumentation
- it appears more Rails/product heavy than the lower-level building blocks
- it is better suited as a deployment/profile addon than as a universal foundation

Best status:

- recommended addon
- Rails-focused profile
- possible later inclusion after the contract layer is stable

## What Must Stay Custom For Now

### Evals

Evals should remain custom inside `ruby_llm-contract` for now.

This is the most important product decision in this strategy.

Why:

- your eval model is not generic benchmarking
- it is tightly tied to the `Step` abstraction
- `define_eval`, `run_eval`, zero-verify eval, sample pre-validation, richer contract-aware reports, and `pass_eval` are part of the same mental model as contracts
- this makes eval a continuation of contract semantics, not a separate analytics subsystem

In other words:

- schema validates shape
- validate checks meaning
- eval extends that same step into repeatable quality checks

That is a strong internal product model.

Today, the ecosystem does not appear to offer a more mature version of that exact shape.

### Result

For now:

- keep evals in `ruby_llm-contract`
- optionally split later into `ruby_llm-contract-evals` if needed
- only consider replacing them with an external ecosystem gem once that gem is clearly more mature and conceptually aligned

## What Can Be Reused Safely

### Safe reuse candidates

- `ruby_llm`
  - provider access
  - model registry
  - pricing data
  - transport

- `ruby_llm-schema`
  - output schema
  - structured output DSL

- `ruby_llm-instrumentation`
  - event stream
  - hooks for observability

## What Should Not Be Replaced

These should remain the core value of `ruby_llm-contract`:

- step abstraction
- contract-first runtime
- validate semantics
- retry based on contract quality
- preflight limit semantics
- test/runtime DX
- contract-aware eval semantics

If those are delegated away, the product loses its center of gravity.

## Practical Rollout Plan

### Phase 1

Stabilize and position the current gem as `ruby_llm-contract`.

Target message:

> RubyLLM companion gem for contract-first execution.

### Phase 2

Keep custom evals in `ruby_llm-contract`.

Do not split too early.

### Phase 3

Create `ruby_llm-suite` as a meta-gem that depends on:

- `ruby_llm-contract`
- `ruby_llm-schema`
- `ruby_llm-instrumentation`

### Phase 4

Evaluate optional addons:

- `ruby_llm-template`
- `ruby_llm-monitoring`
- additional eval packaging
- optional Rails integrations

## Final Recommendation

### Product 1

`ruby_llm-contract`

This is the strongest product and should be the flagship.

### Product 2

`ruby_llm-suite`

This should be a bundle, not a monolith.

### Day-1 suite contents

- `ruby_llm-contract`
- `ruby_llm-schema`
- `ruby_llm-instrumentation`

### Keep custom for now

- evals

### Optional later

- `ruby_llm-template`
- `ruby_llm-monitoring`

## Why this strategy is the healthiest

It balances:

- ecosystem alignment
- product clarity
- realistic execution
- future modularity

It avoids both extremes:

- too independent from RubyLLM
- too dependent on immature ecosystem pieces

This is the most credible path to building something that feels native to the RubyLLM community while still preserving a clear, ownable product.

## Draft Message To Carmine

Below is a concise draft message to Carmine Paolino, author of RubyLLM.

---

Hi Carmine,

I wanted to share a direction I am seriously considering and get your read on whether it feels like a natural fit for the RubyLLM ecosystem.

I have been building a gem around contract-first execution for LLM calls: turning a prompt into a step with validation, retry based on contract quality, preflight limits, lightweight trace, and evals tied to the same runtime abstraction.

After looking more closely at the RubyLLM ecosystem, the shape that now seems most honest is:

- `ruby_llm-contract` as the core product
- `ruby_llm-suite` as a curated umbrella bundle

The idea is:

- `ruby_llm-contract` would focus on the missing middle layer: a contract-first runtime around RubyLLM calls
- `ruby_llm-suite` would bundle the strongest ecosystem pieces together, likely including:
  - `ruby_llm-contract`
  - `ruby_llm-schema`
  - `ruby_llm-instrumentation`
  - and possibly a monitoring layer later, rather than as a hard requirement from day one

What I do not think exists yet in the ecosystem is a strong, simple runtime unit for "prompt as validated application step". There are great pieces for schema and instrumentation, useful operational tooling around monitoring, and some template work, but not yet one sharp layer that gives developers a contracted call abstraction with execution semantics.

One important nuance: I would likely keep evals custom for now rather than build `ruby_llm-contract` on top of the current community eval gem. My current eval model is tightly tied to the step abstraction and contract semantics, and I am not sure the ecosystem eval story is mature enough yet to be the foundation.

Before moving further, I would love your take on two questions:

1. Does `ruby_llm-contract` sound like a natural companion gem within the RubyLLM ecosystem?
2. Does the idea of a curated `ruby_llm-suite` meta-gem feel helpful, or does it risk being too much too early?

I am asking because I would rather align with the ecosystem honestly than create something that looks adjacent to RubyLLM while actually depending on it everywhere under the hood.

If useful, I can also send a one-page breakdown of proposed boundaries:

- what belongs in `ruby_llm-contract`
- what belongs in `ruby_llm-suite`
- what should stay custom vs what should reuse ecosystem gems

Thanks,
[Your Name]

---

## Shorter Carmine Version

Hi Carmine,

I have been building a contract-first runtime layer around RubyLLM calls: validated steps, retry on contract failure, preflight limits, lightweight trace, and evals tied to the same step abstraction.

The direction I am considering now is:

- `ruby_llm-contract` as the core product
- `ruby_llm-suite` as a curated umbrella bundle

The thesis is that RubyLLM already has great ecosystem pieces for schema and instrumentation, plus useful operational tooling around monitoring, but there is still a missing middle layer for "validated application step" execution semantics.

I would likely keep evals custom for now, since they are tightly coupled to the contract/step abstraction and I do not think the current ecosystem eval layer is mature enough yet to anchor the product.

Would love your read on whether `ruby_llm-contract` feels like a natural companion gem in the ecosystem, and whether a bundled `ruby_llm-suite` sounds useful or premature.
