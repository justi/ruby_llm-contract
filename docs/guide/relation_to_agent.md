# Relation to `RubyLLM::Agent`

> Read this when you already use `RubyLLM::Agent` (or are about to) and want to understand where `ruby_llm-contract` sits in the same project.

`RubyLLM::Agent` shipped in RubyLLM 1.12. `Step::Base` from this gem and `Agent` target the **same niche**: reusable, class-based prompts. They are **siblings**, not foundation-and-roof.

## Feature mapping

| What you write | Where it lives |
|---|---|
| `model`, `temperature`, `schema`, `instructions`, `tools`, `thinking` | covered by both — same idea, different DSL surface |
| `validate :rule do ... end` business invariants on output | only in `ruby_llm-contract` |
| `retry_policy escalate(...)` model escalation on validation failure | only here (different from RubyLLM's network-level retry) |
| `max_cost` / `max_input` / `max_output` pre-flight refusal | only here |
| `define_eval` + baseline regression + `compare_models` + `optimize_retry_policy` | only here (RubyLLM does not ship an evaluation framework) |
| Pipeline composition with `step SomeStep, as: :alias` | only here (RubyLLM intentionally leaves workflows as plain Ruby) |
| `around_call`, named `observe` hooks with pass/fail recorded in trace | only here |

## Runtime relationship

`Step::Base` does **not** use `Agent` internally today. The actual call path is:

```
Step.run(input)
  → Runner
  → Adapters::RubyLLM
  → RubyLLM.chat(model:, ...)
  → ... .ask(prompt)
```

`Agent` is a sibling abstraction calling into `RubyLLM::Chat` through its own `apply_configuration` path. Both end up at `Chat`. They do not share the macro-storage layer.

This may change in a future release if upstream APIs make a layered design natural. The decision is not committed; it depends on adopter signal.

## Coexistence on the same project

The two abstractions can live in the same Rails (or non-Rails) project. Pick one per use case:

- **`RubyLLM::Agent`** when you want a reusable prompt with `model` + `instructions` + `schema` + `tools` and that is enough — no retry-on-validation-failure, no business invariants, no eval framework, no budget gating.
- **`ruby_llm-contract`'s `Step::Base`** when you need any of: invariants (`validate`), retry with model escalation on validation failure, pre-flight cost ceilings, an evaluation framework with baseline regression, or pipeline composition.

A common pattern: simple ad-hoc prompts as `Agent`, contracts on the LLM features that touch production behaviour or money as `Step`.

## On retry strategies

The retry-strategy framing in this gem favours `retry_policy escalate(model_2, ...)` (model escalation, addresses model bias) over same-model `retry_policy attempts: N` (variance retry).

This is grounded in empirical comparison across PDF quiz generation, GSM8K math (n=30 + n=120), and multi-constraint schedule generation: same-model retry produced no useful lift for nano-class models on tasks with clear correctness criteria. Model escalation did move the needle when same-model retry could not.

`attempts: N` stays in the gem API (backward compat + niche cases like subjective-criteria tasks, multi-step pipelines, weaker open-source models) but is not marketed as a default retry strategy.

See [Optimize retry policy](optimizing_retry_policy.md) for the empirical tooling.
