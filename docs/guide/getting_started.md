# Getting Started

> Read this to walk through every feature on one concrete step for the first time.

The README shows a minimal `SummarizeArticle` step. This guide walks through the features you reach for as production requirements grow: budget caps so runaway inputs don't drain your LLM provider budget, evals so you catch regressions in CI, and CI gating so a merge that lowers accuracy gets blocked.

## The walkthrough

Start with the README example, then add features one layer at a time. Each is optional — use what you need.

The `prompt` body uses a small template syntax — `{X}` placeholders are replaced with values from the input at call time. With the default `input_type String`, the entire `article_text` you pass to `SummarizeArticle.run(article_text)` lands in `{input}`. For `input_type Hash`, each top-level key becomes its own placeholder (e.g. `{summary}`, `{article}`). See [Prompt AST](prompt_ast.md) for the full DSL surface.

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
  validate("takeaways are unique") { |o, _| o[:takeaways] == o[:takeaways].uniq }

  # 4. Retry with model fallback on validation_failed / parse_error
  retry_policy models: %w[gpt-4.1-nano gpt-4.1-mini gpt-4.1]

  # 5. Refuse before calling the LLM if input is too large or estimated cost exceeds the cap
  max_input  2_000
  max_output 4_000
  max_cost   0.01
end
```

Each `validate` block receives `(parsed_output, context)` — the convention `|o, _|` reads "output, ignore context". Use `o[:key]` to assert on any field your `output_schema` declared. The block returns truthy/falsy: `false` → status `:validation_failed`, retry fires if `retry_policy` was set.

## Validation and retry behavior

When the cheap model returns output that fails a `validate` block (status `:validation_failed`) or can't be parsed as JSON (status `:parse_error`), retry falls back to the next model in `models:` and tries again. Transport errors (timeouts, 5xx) retry independently via Faraday, not via `retry_policy`. See [Optimizing retry_policy](optimizing_retry_policy.md) for tuning the chain.

```ruby
result = SummarizeArticle.run(article_text)

result.status           # => :ok
result.parsed_output    # => { tldr: "...", takeaways: [...], tone: "analytical" }
result.trace[:model]    # => "gpt-4.1-mini"  (first model that passed)
result.trace[:cost]     # => 0.00052  (sum of all attempts)
result.trace[:attempts]
# => [
#   { attempt: 1, model: "gpt-4.1-nano", status: :validation_failed,
#     cost: 0.00010, latency_ms: 45, ... },
#   { attempt: 2, model: "gpt-4.1-mini", status: :ok,
#     cost: 0.00042, latency_ms: 92, ... }
# ]
```

If the whole chain exhausts, `result.status` is the status of the last attempt (`:validation_failed` or `:parse_error`) and `result.parsed_output` is the last attempt's output. The caller decides what to do — ship it anyway, fall back to a template, or raise.

### Retrying provider errors by class

A provider error that RubyLLM's own retries could not get past ends as `:adapter_error`, with the exception class in `trace[:error_class]` (e.g. `"RubyLLM::RateLimitError"`). Adapter errors are not retried by default. List exception classes in `retry_on` to retry only those, typically together with `escalate` so the next attempt goes to another model:

```ruby
retry_policy do
  escalate "gpt-4.1-mini", "claude-haiku-4-5"
  retry_on :validation_failed, :parse_error, RubyLLM::RateLimitError, RubyLLM::OverloadedError
end
```

A class matches its subclasses; `:adapter_error` in the list retries every adapter error. As with statuses, the list replaces the defaults. Switching to a fallback model on transport errors inside one call is RubyLLM's `chat.with_fallbacks`; the contract's adapter does not call it, so fallbacks across models belong in `escalate`.

### Responses cut off by a token limit

When a provider stops at a token limit or a content filter, `trace[:finish_reason]` says so (`:max_tokens`, `:content_filter`), and a failed result gets a last validation error naming it. A cut-off answer that still parses and validates stays `:ok` unless the step refuses it:

```ruby
class SummarizeArticle < RubyLLM::Contract::Step::Base
  max_output 400
  on_incomplete_output :refuse   # default :accept
end
```

With `:refuse`, such a response fails before validation as `:output_truncated` (token limit) or `:content_filtered`, so `validate` blocks and observers never see it. Raw output, usage and cost stay on the result. Neither status is retried by default; `retry_on :output_truncated` opts in (useful when a later attempt has a larger `max_output`). Anthropic reports an exhausted context window as a token-limit stop too, so `:output_truncated` means "stopped on tokens", not necessarily "hit max_output".

### Per-attempt reasoning effort

`models:` accepts config hashes as well as model-name strings, so a fallback can "try harder" (more reasoning) on retry, not just switch model:

```ruby
retry_policy models: [
  "gpt-5-nano",                                      # attempt 1: cheap + fast
  { model: "gpt-5-mini", reasoning_effort: "high" }  # attempt 2: stronger + more reasoning
]
```

`reasoning_effort` is a gpt-5 family feature (gpt-4.1 is not a reasoning model). The per-attempt value is forwarded via `with_thinking` (provider-agnostic — OpenAI `reasoning_effort` and Anthropic extended-thinking budget both supported). Passing it alongside a non-reasoning model is forwarded unchanged to the provider, which will either ignore it or reject the request — the gem does not guard against this.

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

`default_input` sets the input once for every case in this eval — useful for smoke evals where you reuse one synthetic article. For regression evals where each case needs its own input, use `add_case input: "..."` (shown next).

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

`expected:` is treated as a partial match against `parsed_output` — extra output keys are ignored, listed keys must equal. So this case passes whenever the model produces `tone: "analytical"`, regardless of `tldr` content. To assert on multiple keys, list them all in `expected`.

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

`without_regressions` fails the build only if a previously-passing case now fails — a new model version, a prompt tweak, or an upstream change that silently lowered quality. A previously-passing case that was skipped this run (no adapter configured) also fails the gate, listed as `SKIPPED` rather than as a regression.

## Budget caps

`max_input`, `max_output`, and `max_cost` are preflight checks — the LLM is never called if an estimate exceeds the limit. Zero tokens spent, zero cost.

```ruby
result = SummarizeArticle.run(giant_10mb_document)
result.status            # => :limit_exceeded
result.validation_errors
# => ["Input token limit exceeded: estimated 32000 tokens (heuristic ±30%), max 2000"]
```

`max_cost` fails closed when the model's pricing isn't known — register custom or fine-tuned models explicitly:

```ruby
RubyLLM::Contract::CostCalculator.register_model("ft:gpt-4o-custom",
  input_per_1m: 3.0, output_per_1m: 6.0)
```

Or opt into a soft warning instead of a refusal when pricing is missing:

```ruby
max_cost 0.01, on_unknown_pricing: :warn
```

Default is `:refuse`. Use `:warn` only when you accept running without a cost ceiling (fine-tuned models you trust, private endpoints).

The eval-level gates - `with_maximum_cost` on `pass_eval`, `maximum_cost` on the rake task, and `maximum_cost:` on `assert_eval_passes` - follow the same rule since 1.1.0. A report's total counts a case it cannot price as $0, so when any case ran on a model without pricing data the gate fails and names the cases instead of comparing an undercounted total. Opt out with `.on_unknown_pricing(:warn)`, `t.on_unknown_pricing = :warn` or `on_unknown_pricing: :warn`, which checks the budget against the priced cases and prints a warning. Offline runs (`sample_response`, a `Test` adapter without `usage:`) report zero tokens, cost $0 with or without pricing, and are never flagged. Since 1.1.2 a real call whose provider sent no token counts is flagged too, instead of passing as a free zero-token run.

### What a trace's usage and cost count

`trace[:usage][:input_tokens]` is the whole prompt the model took in, including tokens served from or written to the provider's prompt cache. When the provider reports them, the trace adds a breakdown: `cache_read_tokens`, `cache_write_tokens` and `thinking_tokens`. These are parts of `input_tokens` / `output_tokens`, not extra tokens; reasoning tokens are already in `output_tokens` when the provider bills them as output, and a model with a separate reasoning price is charged that price for them.

```ruby
result.trace[:usage]
# => { input_tokens: 10_000, output_tokens: 200, cache_read_tokens: 9_000 }
result.trace[:cost]    # => 0.00162  (gpt-4.1-mini: cache reads at the cache price)
```

With the RubyLLM adapter, `trace[:cost]` is the cost RubyLLM puts on the response (`response.cost.total`): the price of the provider the call went to, cache and long-context prices, and the amount the provider reported when it reports one (OpenRouter, for example). A price set with `CostCalculator.register_model` still overrides it for that model id, unless the provider reported what it billed; there, cache reads are charged at the input price and a call that wrote to the cache has no price, since cache writes can cost more than input.

When a cost does not cover the whole call, `result.trace.cost_unknown?` is true and the eval gates above refuse. That happens when pricing is missing for a token category the call used, or when the provider sent no token counts for the call or for one of RubyLLM's attempts at it (`trace[:usage_complete]` is then `false` and missing counts read as 0) and did not report what it billed either. On a retried step `trace[:cost]` is the sum of the attempts that could be priced, and `cost_unknown?` is true if any attempt could not. `max_cost` itself is a pre-flight check on an estimate; it does not inspect the finished call.

A custom adapter returning `Response.new(content:, usage:)` is priced from `usage` as before. To report its own cost, pass `cost:` - `nil` means unknown - with `cost_complete:` and `usage_complete:`.

### Counting input tokens exactly

`max_input` and `max_cost` measure the input with a chars/4 heuristic (±30%). With `token_count :exact` they ask the provider instead:

```ruby
class SummarizeArticle < RubyLLM::Contract::Step::Base
  token_count :exact   # default :estimate
  max_input 20_000
end
```

The count comes from RubyLLM's `chat.count_tokens` (OpenAI Responses, Anthropic, Gemini, Vertex AI, Bedrock Converse) and covers the prompt and attachments, so `attachment_token_estimate` is not needed. What else a provider counts is its own: OpenAI's and Anthropic's counts include the output schema, Gemini's leaves it out. It costs one extra request per attempt, and RubyLLM leaves `provider_options` out of it. Where no count can be had - a provider without the endpoint (Ollama, for one), a failed request, or an adapter without `count_tokens` - the call is refused as `:limit_exceeded` with the reason, never measured with the heuristic under the name "exact". The `Test` adapter counts with the heuristic, since it has no provider to ask. The output side of `max_cost` is still an estimate (`max_output`, or the input size without one).

### Local and custom models

A local model (Ollama) or a fine-tuned one has no price in RubyLLM's registry, so its cost is unknown and the eval cost gates refuse. Register a price - zero for a model that costs nothing per token:

```ruby
RubyLLM::Contract::CostCalculator.register_model("gemma-fast:latest", input_per_1m: 0, output_per_1m: 0)
RubyLLM::Contract::CostCalculator.register_model("ft:gpt-4o-custom",
  input_per_1m: 3.0, output_per_1m: 6.0, cache_read_per_1m: 1.5, cache_write_per_1m: 3.75)
```

`register_model` sets a price for a model id, not a model RubyLLM can call: the step still needs `provider:` (and `assume_model_exists: true` for an id RubyLLM does not list). Cache prices are optional; without them cache reads are charged at the input price and a call that wrote to the cache has no price. A price does not make up for missing counts: a provider that sends no token counts still leaves the cost unknown.

### Preflight cost estimates

Check what a call is likely to cost before invoking it:

```ruby
SummarizeArticle.estimate_cost(input: article_text)
# => {
#      model: "gpt-4.1-mini",
#      input_tokens: 812, output_tokens_estimate: 4000,
#      estimated_cost: 0.00243
#    }

# Estimate what a full eval would cost across candidate models
SummarizeArticle.estimate_eval_cost("regression",
  models: %w[gpt-4.1-nano gpt-4.1-mini gpt-4.1])
# => { "gpt-4.1-nano" => 0.00041, "gpt-4.1-mini" => 0.0018, "gpt-4.1" => 0.0092 }
```

`estimate_cost` returns `nil` when pricing isn't registered. `estimate_eval_cost` silently treats unknown-pricing cases as `$0.00` and sums the rest — it does **not** fail closed the way `max_cost` does. Treat its output as a floor, not a guarantee; register pricing via `CostCalculator.register_model` before relying on it for budget decisions.

## Provider options

Settings RubyLLM has no method for go to the provider as-is through `provider_options`, on the step or per call:

```ruby
class SummarizeArticle < RubyLLM::Contract::Step::Base
  provider_options service_tier: "flex"
end

SummarizeArticle.run(text, context: { provider_options: { service_tier: "priority", seed: 7 } })
```

The call's keys win over the step's; a subclass replaces its parent's hash, and `provider_options :default` stops inheriting it. Keys the step itself sets (`model`, `temperature`, the max-token keys, the messages, and on a step with `output_schema` the structured-output keys `response_format` and `text`) raise `ArgumentError`, so a call cannot differ from what its limits and schema were checked against. Only top-level keys are checked. `compare_models` and `optimize_retry_policy` candidates do not carry provider options.

## Temperature on reasoning models

RubyLLM 1.x sent temperature 1.0 to OpenAI reasoning models (o-series, gpt-5), which reject other values; RubyLLM 2.x sends what it is given. A step with `temperature` therefore leaves it out for a model RubyLLM's registry marks as taking none, and warns once per model - so `temperature 0` with `escalate "gpt-4.1-mini", "gpt-5-mini"` still works. A model the registry does not know gets the temperature as set.

## `output_schema` vs `with_schema`

`with_schema` in `ruby_llm` tells the provider to force a specific JSON structure. `output_schema` in this gem does the same thing (calls `with_schema` under the hood) **plus** validates the response client-side. Cheaper models sometimes ignore schema constraints — `with_schema` is a request; `output_schema` is a request plus verification.

## See also

- [Prompt AST](prompt_ast.md) — prompt DSL variants: `system`, `rule`, `section`, `example`, `user`, and dynamic prompts with `|input|`.
- [Eval-First](eval_first.md) — datasets, baselines, A/B gates, the workflow that makes the above evals useful.
- [Optimizing retry_policy](optimizing_retry_policy.md) — find the cheapest viable fallback list with `compare_models` and `optimize_retry_policy`.
- [Testing](testing.md) — test adapter, `stub_step`, full RSpec + Minitest matcher reference.
- [Output Schema](output_schema.md) — nested objects in arrays, constraints, pattern reference.
- [Rails integration](rails_integration.md) — where step classes live, initializer, jobs, logging, specs, CI gate.
