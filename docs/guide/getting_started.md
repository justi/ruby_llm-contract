# Getting Started

The README shows a minimal `SummarizeArticle` step. This guide walks through the features you reach for as production requirements grow: budget caps so runaway inputs don't drain your OpenAI account, evals so you catch regressions in CI, and CI gating so a merge that lowers accuracy gets blocked.

## The walkthrough

Start with the README example, then add features one layer at a time. Each is optional — use what you need.

```ruby
class SummarizeArticle < RubyLLM::Contract::Step::Base
  # 1. Prompt (required)
  prompt <<~PROMPT
    Summarize this article for a UI card. Return a short TL;DR,
    3 to 5 key takeaways, and a tone label.

    {input}
  PROMPT

  # 2. Schema — sent to the provider via with_schema, validated client-side
  output_schema do
    string :tldr
    array  :takeaways, of: :string, min_items: 3, max_items: 5
    string :tone, enum: %w[neutral positive negative analytical]
  end

  # 3. Business rules — things JSON Schema cannot express
  validate("TL;DR fits the card")  { |o, _| o[:tldr].length <= 200 }
  validate("takeaways are unique") { |o, _| o[:takeaways].uniq.size == o[:takeaways].size }

  # 4. Retry with model fallback on validation_failed / parse_error
  retry_policy models: %w[gpt-4.1-nano gpt-4.1-mini gpt-4.1]

  # 5. Refuse before calling the LLM if input is too large or estimated cost exceeds the cap
  max_input  2_000
  max_output 4_000
  max_cost   0.01
end
```

## Validation and retry behavior

When the cheap model returns output that fails a `validate` block or can't be parsed, retry falls back to the next model in `models:` and tries again.

```ruby
result = SummarizeArticle.run(article_text)

result.status           # => :ok
result.parsed_output    # => { tldr: "...", takeaways: [...], tone: "analytical" }
result.trace[:model]    # => "gpt-4.1-mini"  (first model that passed)
result.trace[:cost]     # => 0.000042
result.trace[:attempts]
# => [
#   { attempt: 1, model: "gpt-4.1-nano", status: :validation_failed, cost: 0.00010, latency_ms: 45, ... },
#   { attempt: 2, model: "gpt-4.1-mini", status: :ok,                cost: 0.00042, latency_ms: 92, ... }
# ]
```

If the whole chain exhausts, `result.status` is the status of the last attempt (`:validation_failed` or `:parse_error`) and `result.parsed_output` is the last attempt's output. The caller decides what to do — ship it anyway, fall back to a template, or raise.

## Evals and CI gates

An eval is a named scenario you can run to verify the step still works. `sample_response` makes it offline — zero API calls — so CI can run it on every merge without burning budget.

```ruby
SummarizeArticle.define_eval("smoke") do
  default_input <<~ARTICLE
    Ruby 3.4 ships with frozen string literals on by default, measurable YJIT
    speedups on Rails workloads, and tightened Warning.warn category filtering.
    The release notes also mention several parser fixes and faster keyword
    argument handling.
  ARTICLE

  sample_response({
    tldr: "Ruby 3.4 brings frozen string literals by default, YJIT speedups, and parser fixes.",
    takeaways: [
      "Frozen string literals are the default",
      "YJIT adds measurable speedups on Rails workloads",
      "Warning.warn category filtering is tighter"
    ],
    tone: "analytical"
  })
end

report = SummarizeArticle.run_eval("smoke")
report.passed?  # => true — schema + validates pass on the canned response
report.score    # => 1.0
report.print_summary
```

For real regression testing, define cases with expected output (online — calls the LLM):

```ruby
SummarizeArticle.define_eval("regression") do
  add_case "ruby release",
           input: "Ruby 3.4 was released...",
           expected: { tone: "analytical" }  # partial match

  add_case "critical review",
           input: "The new mesh networking hardware failed under load...",
           expected: { tone: "negative" }
end
```

Gate CI on score and cost thresholds:

```ruby
# RSpec — blocks merge if accuracy drops or cost spikes
expect(SummarizeArticle).to pass_eval("regression")
  .with_minimum_score(0.8)
  .with_maximum_cost(0.01)
```

Save a baseline once, then block regressions automatically:

```ruby
report = SummarizeArticle.run_eval("regression")
report.save_baseline!

# In CI:
expect(SummarizeArticle).to pass_eval("regression").without_regressions
```

`without_regressions` fails the build only if a previously-passing case now fails — a new model version, a prompt tweak, or an upstream change that silently lowered quality.

## Budget caps

`max_input`, `max_output`, and `max_cost` are preflight checks — the LLM is never called if an estimate exceeds the limit. Zero tokens spent, zero cost.

```ruby
result = SummarizeArticle.run(giant_10mb_document)
result.status            # => :limit_exceeded
result.validation_errors # => ["Input token limit exceeded: estimated 32000 tokens, max 2000"]
```

`max_cost` fails closed when the model's pricing isn't known — register custom or fine-tuned models explicitly:

```ruby
RubyLLM::Contract::CostCalculator.register_model("ft:gpt-4o-custom",
  input_per_1m: 3.0, output_per_1m: 6.0)
```

## `output_schema` vs `with_schema`

`with_schema` in `ruby_llm` tells the provider to force a specific JSON structure. `output_schema` in this gem does the same thing (calls `with_schema` under the hood) **plus** validates the response client-side. Cheaper models sometimes ignore schema constraints — `with_schema` is a request; `output_schema` is a request plus verification.

## See also

- [Prompt AST](prompt_ast.md) — prompt DSL variants: `system`, `rule`, `section`, `example`, `user`, and dynamic prompts with `|input|`.
- [Eval-First](eval_first.md) — datasets, baselines, A/B gates, the workflow that makes the above evals useful.
- [Optimizing retry_policy](optimizing_retry_policy.md) — find the cheapest viable fallback list with `compare_models` and `optimize_retry_policy`.
- [Testing](testing.md) — test adapter, `stub_step`, full RSpec + Minitest matcher reference.
- [Output Schema](output_schema.md) — nested objects in arrays, constraints, pattern reference.
