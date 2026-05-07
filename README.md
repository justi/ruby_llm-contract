# ruby_llm-contract

**Contracts + Evals for [ruby_llm](https://github.com/crmne/ruby_llm).**

Your eval passed. Prod broke anyway? This gem wraps `RubyLLM::Chat` with input/output contracts, business-rule validation, retry with model escalation on validation failure, pre-flight cost ceilings, and a regression-eval framework — so a flaky cheap-model call escalates to a stronger model instead of shipping garbage to your user.

`ruby_llm` handles the HTTP side (rate limits, timeouts, streaming, tool calls, embeddings). This gem handles what the model *returned* at **runtime**: schema validation, business rules, model escalation on failed validation, regression datasets that gate prompt/model changes in CI.

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

Already using structured outputs from your provider? This gem adds business-rule validation, retry with model fallback, evals, regression gating, and test stubs on top of them — the layer that stops schema-valid-but-wrong output from reaching users. See [Why contracts?](docs/guide/why.md) for the four production failure modes the gem exists for.

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
result.status           # => :ok  (or :validation_error if every model in the chain failed)
result.parsed_output    # => { tldr: "...", takeaways: [...], tone: "analytical" }
result.trace[:model]    # => "gpt-4.1-nano"  (first model that passed)
result.trace[:cost]     # => 0.000032
```

The model returns JSON matching the schema. If the response is malformed, the TL;DR overflows the card, or the takeaway count is off, the gem retries — moving to the next model in `models:` only when the cheaper one can't satisfy the rules. Cheaper models are tried first; expensive ones are used only when cheaper ones fail.

## Most useful next

Everything below is optional — the example above is a complete step. Reach for these when one step isn't enough.

- **[CI regression gates](docs/guide/getting_started.md)** — block CI when accuracy drops on a model update or prompt tweak.
- **[Find the cheapest viable fallback list](docs/guide/optimizing_retry_policy.md)** — empirically pick the cheapest model chain that still passes your evals.
- **[A/B test prompts](docs/guide/eval_first.md)** — measure whether a new prompt is safe to ship before merging.
- **[Budget caps](docs/guide/getting_started.md)** — refuse the request pre-flight when an estimate exceeds the limit.
- **[Reasoning effort / thinking config](docs/guide/optimizing_retry_policy.md)** — Anthropic / OpenAI thinking configuration on the Step class.

Also supports [multi-step pipelines](docs/guide/pipeline.md) with fail-fast and per-step models.

## Relation to `RubyLLM::Agent`

`Step::Base` and `RubyLLM::Agent` (since RubyLLM 1.12) are **siblings** targeting the same niche: reusable, class-based prompts. Both call into `RubyLLM::Chat` directly — Step does not wrap Agent. Step adds the contract layer: `validate` (business invariants), `retry_policy escalate(...)` (model escalation on validation failure), `max_cost` pre-flight refusal, regression-eval framework, pipeline composition. **[Full feature mapping →](docs/guide/relation_to_agent.md)**

## Relation to `ruby_llm-tribunal`

Different layers, complementary. [`ruby_llm-tribunal`](https://github.com/Alqemist-labs/ruby_llm-tribunal) is a **test framework** that grades outputs **after they've reached your code**, typically in a spec. `ruby_llm-contract` is **runtime** — schema + `validate` rules gate the call **before the output reaches your code**, retry/escalate attempts to recover from failed outputs, `max_cost` refuses pre-flight. Our `define_eval` is *regression* (does this prompt/model still pass on a frozen dataset?), not *grading*.

**One-liner:** Tribunal answers *"is this output good?"* (fail → red test in CI). Contract answers *"what do we do when it isn't?"* (fail → retry/escalate, or fail closed). **[Visual flows + coexistence patterns →](docs/guide/relation_to_tribunal.md)**

## Docs

**New here?** Read in order: this README → [Why contracts?](docs/guide/why.md) → [Getting Started](docs/guide/getting_started.md).

| Guide | What it does for your app |
|-------|---------------------------|
| [Why contracts?](docs/guide/why.md) | Recognise the four production failures the gem exists for |
| [Relation to RubyLLM::Agent](docs/guide/relation_to_agent.md) | Sibling abstractions; what each adds; runtime call path; coexistence patterns |
| [Relation to ruby_llm-tribunal](docs/guide/relation_to_tribunal.md) | Different layers (test framework vs runtime contract); visual flows; integration recipes |
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

## Status & versioning

Pre-1.0 (currently **0.8.0**). Semver tracked; breaking changes flagged in [CHANGELOG](CHANGELOG.md). Pin `~> 0.8.0` until 1.0 ships.

## License

MIT
