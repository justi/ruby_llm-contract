# ruby_llm-contract

**Contracts + Evals for [ruby_llm](https://github.com/crmne/ruby_llm).**

Your eval passed. Prod broke anyway? This gem wraps `RubyLLM::Chat` with input/output contracts, business-rule validation, retry with model escalation on validation failure, pre-flight cost ceilings, and a regression-eval framework — so a flaky cheap-model call escalates to a stronger model instead of shipping garbage to your user.

`ruby_llm` handles the HTTP side (rate limits, timeouts, streaming, tool calls, embeddings). This gem handles what the model *returned* at **runtime**: schema validation, business rules, model escalation on failed validation, regression datasets that gate prompt/model changes in CI.

## Install

```ruby
gem "ruby_llm-contract"
```

```ruby
RubyLLM.configure do |c|
  c.openai_api_key = ENV["OPENAI_API_KEY"]
  c.default_model  = "gpt-4.1-mini"   # used when a Step has no explicit model
end

# Required: boots the gem so `Step.run` knows how to talk to your LLM.
# Empty block is fine. Pass options here if you need them (e.g. `c.logger`).
RubyLLM::Contract.configure { }
```

Works with any `ruby_llm` provider (OpenAI, Anthropic, Gemini, etc). Requires `ruby_llm ~> 1.12` and Ruby ≥ 3.2.

## Example

A Rails app takes article text extracted from a user-submitted URL and wants to show a summary card: a short TL;DR, 3–5 key takeaways, and a tone label. The output has to fit the UI (TL;DR under 200 chars) and the schema has to be strict enough to render without conditionals.

```ruby
# app/contracts/summarize_article.rb
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
  validate("takeaways are unique") { |o, _| o[:takeaways] == o[:takeaways].uniq }

  # Cheapest first; last step adds a reasoning model with more thinking.
  retry_policy do
    escalate "gpt-4.1-nano",
             "gpt-4.1-mini",
             { model: "gpt-5", reasoning_effort: "high" }
  end
end

result = SummarizeArticle.run(article_text)
result.status           # => :ok  (or :validation_failed if all steps fail)
result.parsed_output    # => { tldr: "...", takeaways: [...], tone: "..." }
result.trace[:model]    # => "gpt-4.1-mini"  (winning step)
result.trace[:cost]     # => 0.000520        (total across all attempts)

result.trace[:attempts]
# => [
#      {
#        attempt: 1,
#        model: "gpt-4.1-nano",
#        status: :validation_failed,
#        usage: { input_tokens: 256, output_tokens: 84 },
#        latency_ms: 45,
#        cost: 0.000100
#      },
#      {
#        attempt: 2,
#        model: "gpt-4.1-mini",
#        status: :ok,
#        usage: { input_tokens: 256, output_tokens: 92 },
#        latency_ms: 92,
#        cost: 0.000420
#      }
#    ]
```

If the response is malformed, the TL;DR overflows the card, or the takeaway count is off, the gem moves to the next step. This is model **escalation**, not a fallback list — each step is an independent config (`model`, `reasoning_effort`), so the retry policy spends more compute only when the cheaper one couldn't satisfy the contract.

### Add a CI gate in 6 lines

The contract above already runs in production. The same `Step` doubles as the unit your regression eval runs against:

```ruby
SummarizeArticle.define_eval("regression") do
  # `expected:` is a partial hash match — only listed keys check parsed_output.
  add_case "neutral release",
           input: "Ruby 3.4 shipped frozen string literals...",
           expected: { tone: "analytical" }
  add_case "outage post",
           input: "Service was down for 4 hours...",
           expected: { tone: "negative" }
end

# in CI (RSpec):
expect(SummarizeArticle).to pass_eval("regression").without_regressions
```

A bad prompt edit or model swap that drops accuracy on the frozen dataset → red CI, blocked merge. The first CI run records a baseline; subsequent runs compare against it. Every production miss should become the next `add_case`. See [Prevent silent prompt regressions](docs/guide/eval_first.md) for the full flywheel.

## Do I need this?

Use this if LLM output affects production behaviour, money, user trust, or downstream code. You probably don't need it if you have one low-risk prompt, manually inspect every result, or only generate best-effort prose.

Already using structured outputs from your provider? This gem adds business-rule validation, retry with model escalation, evals, regression gating, and test stubs on top of them — the layer that stops schema-valid-but-wrong output from reaching users. See [Why contracts?](docs/guide/why.md) for the four production failure modes the gem exists for.

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

## FAQ

**Thread-safe / Sidekiq?** Yes. Each `Step.run` builds an isolated `RubyLLM::Chat`; class-level state (`output_schema`, `validate`, `retry_policy`) is set up once at class load and read-only afterwards. Safe to run from concurrent jobs/threads.

**How do I stub `Step.run` in specs?** Include `RubyLLM::Contract::RSpec::Helpers` and use `stub_step(MyStep, response: { ... })`. The block form scopes the stub to one `it`. See [testing guide](docs/guide/testing.md).

**Where in a Rails app?** Default `app/contracts/`. The Railtie reloads `app/contracts/eval/` and `app/steps/eval/` in development; any autoloaded directory also works. See [Rails integration](docs/guide/rails_integration.md).

## License

MIT
