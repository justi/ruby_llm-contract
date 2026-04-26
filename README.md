# ruby_llm-contract

**Contracts + Evals for [ruby_llm](https://github.com/crmne/ruby_llm).**

Your eval passed. Prod broke anyway? This gem wraps `RubyLLM::Chat` with input/output contracts, business-rule validation, retry with model escalation on validation failure, pre-flight cost ceilings, and an evaluation framework — so a flaky cheap-model call escalates to a stronger model instead of shipping garbage to your user.

`ruby_llm` handles the HTTP side (rate limits, timeouts, streaming, tool calls, embeddings). This gem handles what the model *returned*: schema validation, business rules, model escalation on failed validation, datasets, regression tests.

## Install

```ruby
gem "ruby_llm-contract"
```

```ruby
RubyLLM.configure { |c| c.openai_api_key = ENV["OPENAI_API_KEY"] }
RubyLLM::Contract.configure { |c| c.default_model = "gpt-4.1-mini" }
```

Works with any `ruby_llm` provider (OpenAI, Anthropic, Gemini, etc).

## Do I need this?

Use this if LLM output affects production behaviour, money, user trust, or downstream code. You probably don't need it if you have one low-risk prompt, manually inspect every result, or only generate best-effort prose.

Already using structured outputs from your provider? This gem adds business-rule validation, retry with model fallback, evals, regression gating, and test stubs on top of them — the layer that stops schema-valid-but-wrong output from reaching users. See [Why contracts?](docs/guide/why.md) for the four production failure modes the gem exists for, or run `ruby examples/01_fallback_showcase.rb` to see the fallback loop in 30 seconds (no API key needed).

## Example

A Rails app takes article text extracted from a user-submitted URL and wants to show a summary card: a short TL;DR, 3–5 key takeaways, and a tone label. The output has to fit the UI (TL;DR under 200 chars) and the schema has to be strict enough to render without conditionals.

```ruby
class SummarizeArticle < RubyLLM::Contract::Step::Base
  prompt <<~PROMPT
    Summarize this article for a UI card. Return a short TL;DR,
    3 to 5 key takeaways, and a tone label.

    {input}
  PROMPT

  output_schema do
    string :tldr
    array  :takeaways, of: :string, min_items: 3, max_items: 5
    string :tone, enum: %w[neutral positive negative analytical]
  end

  validate("TL;DR fits the card")  { |o, _| o[:tldr].length <= 200 }
  validate("takeaways are unique") { |o, _| o[:takeaways].uniq.size == o[:takeaways].size }

  retry_policy models: %w[gpt-4.1-nano gpt-4.1-mini gpt-4.1]
end

result = SummarizeArticle.run(article_text)
result.parsed_output    # => { tldr: "...", takeaways: [...], tone: "analytical" }
result.trace[:model]    # => "gpt-4.1-nano"  (first model that passed)
result.trace[:cost]     # => 0.000032
```

The model returns JSON matching the schema. If the response is malformed, the TL;DR overflows the card, or the takeaway count is off, the gem retries — moving to the next model in `models:` only when the cheaper one can't satisfy the rules. In this setup cheaper models are tried first and the expensive ones are used only when cheaper models fail.

You could write this loop yourself once. The gem gives you the loop, a trace of every attempt (model, status, cost, latency), fallback policy, evals, baselines, and CI checks as one contract object — tracked per-step so adding a new LLM feature to your app is one class, not one-off scaffolding.

## Most useful next

Everything below is optional — the example above is a complete step. Reach for these when one step isn't enough.

- **[CI regression gates](docs/guide/getting_started.md)** — `define_eval` + `save_baseline!` + `pass_eval(...).without_regressions` blocks CI when accuracy drops on a model update or prompt tweak.
- **[Find the cheapest viable fallback list](docs/guide/optimizing_retry_policy.md)** — `Step.recommend("regression", candidates: [...], min_score: 0.95)` returns the cheapest list of models that still passes your evals. `production_mode:` measures retry-aware cost.
- **[A/B test prompts](docs/guide/eval_first.md)** — `SummarizeArticleV2.compare_with(SummarizeArticleV1, eval: "regression")` reports whether the new prompt is safe to ship.
- **[Budget caps](docs/guide/getting_started.md)** — `max_cost`, `max_input`, `max_output` refuse the request before calling the API when a heuristic estimate (~±30% accuracy) exceeds the limit.
- **[Reasoning effort / thinking config](docs/guide/optimizing_retry_policy.md)** — `thinking effort: :low` (or alias `reasoning_effort :low`) on the Step class; mirrors `RubyLLM::Agent.thinking` and forwards through `Chat#with_thinking`.

Also supports [multi-step pipelines](docs/guide/pipeline.md) with fail-fast and `retry_policy attempts: N` for niche cases (we measured this empirically — for `gpt-4.1-nano` / `gpt-5-nano` on tasks with clear correctness criteria, same-model retry rarely helps; `escalate(model_2)` is the strategy that moves the needle, see [optimizing_retry_policy.md](docs/guide/optimizing_retry_policy.md)).

## Relation to `RubyLLM::Agent`

`RubyLLM::Agent` (since RubyLLM 1.12) and `Step::Base` here target the **same niche**: reusable, class-based prompts. They are siblings, not foundation-and-roof.

| What you write | Where it lives |
|---|---|
| `model`, `temperature`, `schema`, `instructions`, `tools`, `thinking` | covered by both — same idea, different DSL surface |
| `validate :rule do ... end` business invariants on output | only here |
| `retry_policy escalate(...)` model escalation on validation failure | only here (different from RubyLLM's network-level retry) |
| `max_cost` / `max_input` / `max_output` pre-flight refusal | only here |
| `define_eval` + baseline regression + `compare_models` + `optimize_retry_policy` | only here (RubyLLM does not ship an eval framework) |
| Pipeline composition with `step SomeStep, as: :alias` | only here (RubyLLM intentionally leaves workflows as plain Ruby) |
| `around_call`, named `observe` hooks with pass/fail in trace | only here |

`Step::Base` does NOT use `Agent` internally today — both call into `RubyLLM::Chat` directly. The two abstractions can coexist on the same project: use `Agent` for prompt-only reuse, use `Step` when you need any of the contract-layer features above. The retry-strategy framing here (favouring `escalate(...)` over same-model `attempts: N`) is grounded in an empirical comparison; `attempts: N` stays in the API for niche cases.

## Docs

**New here?** Read in order: this README → [Why contracts?](docs/guide/why.md) → [Getting Started](docs/guide/getting_started.md).

| Guide | What it does for your app |
|-------|---------------------------|
| [Why contracts?](docs/guide/why.md) | Recognise the four production failures the gem exists for |
| [Getting Started](docs/guide/getting_started.md) | Walk the full feature set on one concrete step |
| [Rails integration](docs/guide/rails_integration.md) | Directory, initializer, jobs, logging, specs, CI gate — 7 FAQs for Rails devs |
| [Adopt in an existing Rails app](docs/guide/migration.md) | Replace raw `LlmClient.call` with a contract, Before/After |
| [Prevent silent prompt regressions](docs/guide/eval_first.md) | Evals, baselines, CI gates that block quality drift |
| [Control retry cost and fallback behaviour](docs/guide/optimizing_retry_policy.md) | Find the cheapest viable fallback list empirically |
| [Write validate rules that catch real bugs](docs/guide/best_practices.md) | Patterns for cross-input checks and content-quality rules |
| [Stub LLM calls in tests](docs/guide/testing.md) | Deterministic specs, RSpec + Minitest matchers |
| [Chain LLM calls into a pipeline](docs/guide/pipeline.md) | Multi-step with fail-fast and per-step models |
| [Schema DSL reference](docs/guide/output_schema.md) | Every constraint, nested objects, pattern table |
| [Prompt DSL reference](docs/guide/prompt_ast.md) | `system` / `rule` / `section` / `example` / `user` nodes |

## Roadmap

Latest: **v0.8.0** — tagline + narrative repositioning around "Contracts + Evals for RubyLLM", `thinking` / `reasoning_effort` class macro, TokenEstimator labelled as heuristic, CostCalculator repositioned. See [CHANGELOG](CHANGELOG.md) for history.

## License

MIT
