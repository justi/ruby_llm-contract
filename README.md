# ruby_llm-contract

**Validate and retry LLM outputs for [ruby_llm](https://github.com/crmne/ruby_llm).** Describe the answer you expect (JSON schema + business rules). If the model returns something that doesn't match, retry — optionally falling back to a stronger model — until it passes or you hit the budget.

`ruby_llm` handles the HTTP side (rate limits, timeouts, streaming, tool calls, embeddings). This gem handles what the model *returned*: schema validation, business rules, retry with model fallback, datasets, regression tests.

## Install

```ruby
gem "ruby_llm-contract"
```

```ruby
RubyLLM.configure { |c| c.openai_api_key = ENV["OPENAI_API_KEY"] }
RubyLLM::Contract.configure { |c| c.default_model = "gpt-4.1-mini" }
```

Works with any `ruby_llm` provider (OpenAI, Anthropic, Gemini, etc).

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
- **[Find the cheapest viable fallback list](docs/guide/optimizing_retry_policy.md)** — `Step.recommend(candidates:, min_score:)` returns the cheapest list of models that still passes your evals. `production_mode:` measures retry-aware cost.
- **[A/B test prompts](docs/guide/eval_first.md)** — `SummarizeArticleV2.compare_with(SummarizeArticleV1, eval: "regression")` reports whether the new prompt is safe to ship.
- **[Budget caps](docs/guide/output_schema.md)** — `max_cost`, `max_input`, `max_output` refuse the request before calling the API when an estimate exceeds the limit.

Also supports [multi-step pipelines](docs/guide/pipeline.md) with fail-fast and [best-effort retries without fallback](docs/guide/best_practices.md) (`retry_policy attempts: 3` for sampling variance).

## Docs

| Guide | |
|-------|-|
| [Getting Started](docs/guide/getting_started.md) | Features walkthrough |
| [Eval-First](docs/guide/eval_first.md) | Datasets, baselines, A/B gates |
| [Optimizing retry_policy](docs/guide/optimizing_retry_policy.md) | Fallback lists + production-mode cost |
| [Best Practices](docs/guide/best_practices.md) | Validate patterns, retry-without-fallback |
| [Output Schema](docs/guide/output_schema.md) | Full schema DSL reference + constraints |
| [Pipeline](docs/guide/pipeline.md) | Multi-step with fail-fast |
| [Testing](docs/guide/testing.md) | Test adapter, RSpec + Minitest matchers |
| [Migration](docs/guide/migration.md) | Adopting in existing Rails apps |

## Roadmap

Latest: **v0.7.1** — `run_once` no longer masks adapter bugs as `:input_error`. See [CHANGELOG](CHANGELOG.md) for history.

## License

MIT
