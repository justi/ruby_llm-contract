# Testing

How to write deterministic specs and matchers for steps built on `ruby_llm-contract`. Examples use `SummarizeArticle` (the flagship step from the [README](../../README.md)).

## Test adapter

Ships deterministic specs with zero API calls. Accepts a String, Hash, or Array:

```ruby
# String JSON
adapter = RubyLLM::Contract::Adapters::Test.new(
  response: '{"tldr":"...","takeaways":["a","b","c"],"tone":"neutral"}'
)

# Hash — auto-converted to JSON
adapter = RubyLLM::Contract::Adapters::Test.new(
  response: { tldr: "...", takeaways: %w[a b c], tone: "neutral" }
)

# Multiple sequential responses (one per call)
adapter = RubyLLM::Contract::Adapters::Test.new(
  responses: [
    { tldr: "...", takeaways: %w[a b c], tone: "neutral" },
    { tldr: "...", takeaways: %w[x y z], tone: "analytical" }
  ]
)

result = SummarizeArticle.run("article text", context: { adapter: adapter })
result.ok?  # => true
```

Multi-step pipeline testing with per-step named responses (using `ArticleCardPipeline` from [Pipeline](pipeline.md)):

```ruby
result = ArticleCardPipeline.test("article text",
  responses: {
    summarize: { tldr: "...", takeaways: %w[a b c], tone: "analytical" },
    tag:       { tldr: "...", takeaways: %w[a b c], tone: "analytical", hashtags: %w[#ruby #release] },
    card:      { headline: "Ruby 3.4 ships", summary: "...", hashtags: %w[#ruby #release], sentiment_icon: "🧠" }
  }
)
```

## Output keys are always symbols

Parsed output uses **symbol keys**, never strings:

```ruby
result.parsed_output[:tldr]     # => "..." ✓
result.parsed_output["tldr"]    # => nil ✗
```

The gem warns if a `validate` or `verify` block returns `nil` — usually a sign of string-key access on symbol-keyed data.

## RSpec setup

In `spec_helper.rb`:

```ruby
require "ruby_llm/contract/rspec"
```

You get the `satisfy_contract` matcher, `pass_eval` matcher, and the `stub_step` helpers.

## stub_step helpers

`stub_step` canned-responses a single step; other steps run normally.

```ruby
RSpec.describe SummarizeArticle do
  before { stub_step(described_class, response: { tldr: "...", takeaways: %w[a b c], tone: "neutral" }) }

  it "satisfies its contract" do
    result = described_class.run("article text")
    expect(result).to satisfy_contract
  end
end
```

**Sequential responses:**

```ruby
stub_step(described_class, responses: [
  { tldr: "...", takeaways: %w[a b c], tone: "neutral" },
  { tldr: "...", takeaways: %w[x y z], tone: "analytical" }
])
```

**Block form (auto-cleanup):**

```ruby
stub_step(SummarizeArticle, response: { tldr: "...", takeaways: %w[a b c], tone: "neutral" }) do
  result = SummarizeArticle.run("article text")
  # stub is active here
end
# stub gone — original adapter restored
```

**Multiple steps at once:**

```ruby
stub_steps(
  SummarizeArticle => { response: { tldr: "...", takeaways: %w[a b c], tone: "neutral" } },
  GenerateHashtags => { response: { tldr: "...", takeaways: %w[a b c], tone: "neutral", hashtags: %w[#ruby #release] } }
) do
  result = ArticleCardPipeline.run("article text")
end
```

**Global stub for all steps:**

```ruby
stub_all_steps(response: { default: true })
```

In RSpec, non-block stubs auto-clean after each example. In Minitest, `teardown` restores the original adapter (via `MinitestHelpers`).

## Minitest

Require `ruby_llm/contract/minitest` in your `test_helper.rb`. You get the same `satisfy_contract` / `pass_eval` assertions and `stub_step` helper, adapted for Minitest syntax.

## RSpec matchers

```ruby
RSpec.describe SummarizeArticle do
  before { stub_step(described_class, response: { tldr: "...", takeaways: %w[a b c], tone: "neutral" }) }

  it "satisfies its contract" do
    result = described_class.run("article text")
    expect(result).to satisfy_contract
  end

  it "rejects invalid output" do
    stub_step(described_class, response: { tldr: "x" * 300, takeaways: %w[a b c], tone: "neutral" })
    result = described_class.run("article text")
    expect(result).not_to satisfy_contract  # TL;DR > 200 chars fails validate
  end

  it "passes its eval" do
    expect(described_class).to pass_eval("smoke")
  end
end
```

`pass_eval` supports a matcher chain — full reference lives in [Getting Started](getting_started.md) under Evals and CI gates. Quick summary:

- `.with_context(model: "gpt-4.1-mini")` — pick model / pass adapter
- `.with_minimum_score(0.8)` — gate on average score
- `.with_maximum_cost(0.01)` — gate on total cost
- `.without_regressions` — block any previously-passing case that now fails (reads the baseline)
- `.compared_with(SummarizeArticleV1)` — A/B against another step; implies regression check

## Offline vs online eval

Evals run in one of two modes depending on how they're defined and what context is passed:

| Has `sample_response`? | Context has adapter/model? | Mode | API calls |
|---|---|---|---|
| Yes | No | **Offline** — uses `sample_response` as canned answer | Zero |
| Yes | Yes | **Online** — ignores `sample_response`, calls real LLM | Real |
| No | Yes | **Online** — calls real LLM | Real |
| No | No | **Skipped** — returns `:skipped`, excluded from score | Zero |

Default is offline. To force online, pass adapter or model in context:

```ruby
# Online — real LLM call
report = SummarizeArticle.run_eval("regression", context: { model: "gpt-4.1-nano" })

# Offline — uses sample_response
report = SummarizeArticle.run_eval("smoke")
```

`compare_with` intentionally ignores `sample_response` because canned data would make both sides look identical. Always pass `model:` or an adapter to A/B.

## Inspecting failures

`run_eval` returns a `Report`. Drill into per-case failures:

```ruby
report = SummarizeArticle.run_eval("regression")

report.score       # => 0.5
report.pass_rate   # => "1/2"
report.total_cost  # => 0.003

report.failures.each do |result|
  puts result.name        # => "critical review"
  puts result.mismatches  # => { tone: { expected: "negative", got: "analytical" } }
  puts result.output      # full parsed output hash
  puts result.details     # human-readable explanation
end
```

`mismatches` is a hash of keys where expected and actual output diverge — pinpoints which field the model got wrong.

## Soft observations

Log suspicious-but-not-invalid output without failing the contract:

```ruby
class CompareArticles < RubyLLM::Contract::Step::Base
  prompt "Score the article pair for relevance. Return JSON: {score_a: 1-10, score_b: 1-10}.\n\n{input}"

  output_schema do
    integer :score_a, minimum: 1, maximum: 10
    integer :score_b, minimum: 1, maximum: 10
  end

  validate("scores in range") { |o, _| (1..10).cover?(o[:score_a]) && (1..10).cover?(o[:score_b]) }
  observe("scores should differ") { |o, _| o[:score_a] != o[:score_b] }
end

adapter = RubyLLM::Contract::Adapters::Test.new(response: { score_a: 5, score_b: 5 })
result  = CompareArticles.run("two identical-looking articles", context: { adapter: adapter })

result.ok?           # => true (observe never fails the contract)
result.observations  # => [{ description: "scores should differ", passed: false }]
```

`observe` runs only after validation passes. Failed observations are logged via `RubyLLM::Contract.logger` — useful for "I want to know this happened without blocking the response".

## Asserting on `around_call`

`around_call` fires **once per run** with the final result (after retry fallback) and exceptions propagate. That makes it straightforward to test:

```ruby
class LoggedSummarize < RubyLLM::Contract::Step::Base
  prompt "Summarize: {input}"
  output_schema { string :tldr }

  around_call do |_step, input, result|
    CallLog.record(model: result.trace.model, cost: result.trace.cost, input_size: input.length)
  end
end

RSpec.describe LoggedSummarize do
  it "logs once per run, with final model + total cost" do
    adapter = RubyLLM::Contract::Adapters::Test.new(response: { tldr: "ok" })
    expect(CallLog).to receive(:record).once.with(hash_including(:model, :cost, :input_size))

    LoggedSummarize.run("article text", context: { adapter: adapter })
  end
end
```

The callback receives `(step, input, result)` — the same `Result` the caller sees. Not invoked per-attempt inside a `retry_policy` chain; if you need per-attempt visibility, read `result.trace[:attempts]` inside the block.

## Baseline file format

Baselines are JSON files in `.eval_baselines/` — commit them to git:

```
.eval_baselines/
  SummarizeArticle/
    regression_gpt-4_1-nano.json
    regression_gpt-4_1-mini.json
```

Each file contains dataset name, step name, score, and per-case results. No timestamps — re-saving an identical baseline produces no git diff. Baseline semantics (what counts as a regression, how `compare_with_baseline` works) are covered in [Getting Started](getting_started.md#evals-and-ci-gates) and [Eval-First](eval_first.md).

## See also

- [Getting Started](getting_started.md) — `pass_eval` matcher chain, threshold gating, Rake task, baseline regressions.
- [Eval-First](eval_first.md) — `compare_with` prompt A/B workflow.
- [Pipeline](pipeline.md) — pipeline-level testing with named step responses.
