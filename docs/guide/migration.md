# Migration Guide

How to adopt `ruby_llm-contract` in an existing Rails app. Examples use `SummarizeArticle` — the flagship step from the [README](../../README.md) — but the pattern applies to any single-input / structured-output service.

## Step 1: Start with the simplest service

Pick the LLM service with: single input → JSON output → DB save. Don't start with parallel batches or complex pipelines.

## Step 2: Define the contract

**Before — raw HTTP:**

```ruby
class ArticleSummaryService
  def call(article_text)
    response = LlmClient.new(model: "gpt-4o-mini").call(prompt(article_text))
    JSON.parse(response[:content], symbolize_names: true)
  end
end
```

**After — contract:**

```ruby
class SummarizeArticle < RubyLLM::Contract::Step::Base
  model "gpt-4.1-mini"

  prompt do
    system "You summarize articles for a UI card."
    rule "Return valid JSON only."
    user "{input}"
  end

  output_schema do
    string :tldr
    array  :takeaways, of: :string, min_items: 3, max_items: 5
    string :tone, enum: %w[neutral positive negative analytical]
  end

  validate("TL;DR fits the card") { |o, _| o[:tldr].length <= 200 }
  retry_policy models: %w[gpt-4.1-mini gpt-4.1]
end
```

## Step 3: Replace the caller

```ruby
# Before
parsed = ArticleSummaryService.new.call(article_text)
Article.update!(summary: parsed["tldr"])

# After
result = SummarizeArticle.run(article_text)
if result.ok?
  Article.update!(summary: result.parsed_output[:tldr])
else
  Rails.logger.warn "Summary failed: #{result.status}"
end
```

## Step 4: Add logging via around_call

```ruby
class SummarizeArticle < RubyLLM::Contract::Step::Base
  # ... prompt, schema, validates ...

  around_call do |step, input, result|
    AiCallLog.create!(
      ai_model: result.trace.model,
      duration_ms: result.trace.latency_ms,
      input_tokens: result.trace.usage&.dig(:input_tokens),
      output_tokens: result.trace.usage&.dig(:output_tokens),
      cost: result.trace.cost,
      status: result.status.to_s
    )
  end
end
```

## Step 5: Add eval cases

Use real inputs from production logs:

```ruby
SummarizeArticle.define_eval("regression") do
  add_case "short news",
           input: "Ruby 3.4 ships with frozen string literals by default...",
           expected: { tone: "analytical" }

  add_case "critical review",
           input: "The new mesh networking hardware failed under load...",
           expected: { tone: "negative" }
end
```

## Step 6: Find the cheapest model

```ruby
comparison = SummarizeArticle.compare_models("regression",
  candidates: [{ model: "gpt-4.1-nano" }, { model: "gpt-4.1-mini" }])

comparison.print_summary
comparison.best_for(min_score: 0.95)  # => cheapest model at >= 95%
```

Full optimization workflow — multi-eval, fallback list, production-mode cost — in [Optimizing retry_policy](optimizing_retry_policy.md).

## Step 7: Add CI gate

```ruby
# Rakefile
require "ruby_llm/contract/rake_task"
RubyLLM::Contract::RakeTask.new do |t|
  t.minimum_score = 0.8
  t.maximum_cost = 0.05
  t.fail_on_regression = true
  t.save_baseline = true
end
```

**Rails apps:** if your adapter is configured in an initializer, use a Proc so context is resolved after Rails boots:

```ruby
RubyLLM::Contract::RakeTask.new do |t|
  t.context = -> { { adapter: RubyLLM::Contract.configuration.default_adapter } }
  t.minimum_score = 0.8
end
```

## Common patterns

| Old pattern | New pattern |
|---|---|
| `LlmClient.new(model:).call(prompt)` | `MyStep.run(input)` |
| `JSON.parse(response[:content])` | `result.parsed_output` |
| `begin; rescue; retry; end` | `retry_policy models: [...]` |
| `body[:temperature] = 0.7` | `temperature 0.7` |
| `AiCallLog.create(...)` | `around_call { \|s, i, r\| ... }` |
| `response_format: JsonSchema.build(...)` | `output_schema do...end` |
| `stub_request(:post, ...)` | `stub_step(MyStep, response: {...})` |

## Anti-patterns

- **Don't migrate markdown/text output services.** The gem is for structured JSON. Prose output gets no benefit from schema validation.
- **Don't put parallelism in the gem.** Thread management is your app's concern. The gem provides the contract; you call it however you want.
- **Don't migrate all services at once.** Start with one. Validate the pattern. Then migrate the next.

## Parallel batch generation

The gem handles single calls. You handle parallelism:

```ruby
class SummarizeBatch < RubyLLM::Contract::Step::Base
  output_schema do
    array :summaries do
      object do
        string :article_id
        string :tldr
      end
    end
  end
  retry_policy models: %w[gpt-4.1-mini gpt-4.1]
end

# Your orchestrator
threads = 10.times.map do |i|
  Thread.new { Rails.application.executor.wrap { SummarizeBatch.run(input(i)) } }
end
results = threads.map(&:value)
```

**Note:** in tests, `stub_step` overrides are thread-local. If your orchestrator spawns threads, propagate overrides manually:

```ruby
overrides = RubyLLM::Contract.step_adapter_overrides.dup
Thread.new { RubyLLM::Contract.step_adapter_overrides = overrides; SummarizeBatch.run(input) }
```

## See also

- [Getting Started](getting_started.md) — the full walkthrough of every feature `SummarizeArticle` uses.
- [Testing](testing.md) — `stub_step` reference for migrating your test adapter mocks.
- [Eval-First](eval_first.md) — how to build the "regression" eval from production logs.
