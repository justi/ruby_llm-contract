# ruby_llm-contract

**Handle LLM output variance for [ruby_llm](https://github.com/crmne/ruby_llm).** Transport is a solved problem — ruby_llm already retries rate limits, timeouts, and server errors at the Faraday layer. What it can't do: retry when the model returns malformed JSON or a wrong answer, escalate to a smarter model when the cheap one fails the rules, measure variance on your dataset, and gate CI on regressions. That's what this gem adds.

## Where the boundary sits

| Concern | Handled by |
|---|---|
| Rate limits, timeouts, 5xx, connection errors | `ruby_llm` (Faraday retry middleware) |
| Streaming, tool calls, embeddings, images, transcription | `ruby_llm` |
| Chat history persistence (`acts_as_chat`) | `ruby_llm` |
| **Malformed JSON / parse errors** | **`ruby_llm-contract`** |
| **Business rule violations (invariants, schema)** | **`ruby_llm-contract`** |
| **Retry with model escalation on bad output** | **`ruby_llm-contract`** |
| **Measuring output variance on datasets** | **`ruby_llm-contract`** |
| **Regression detection + CI gates** | **`ruby_llm-contract`** |

Put together: `ruby_llm` owns the wire, this gem owns what the model *said*.

```
  YOU WRITE                       THE GEM HANDLES                 YOU GET
  ─────────                       ───────────────                 ───────

  validate { |o| ... }            catch bad answers — combined     Zero garbage
                                  with retry_policy, auto-retry   in production

  retry_policy                    start cheap, escalate only      Pay for the cheapest
  models: %w[nano mini full]      when validation fails           model that works

  max_cost 0.01                   estimate tokens, check price,   No surprise bills
                                  refuse before calling LLM

  output_schema { ... }           send JSON schema to provider,   Zero parsing code
                                  validate response client-side

  define_eval { ... }             test cases + baselines,          Regressions caught
                                  run in CI with real LLM          before deploy

  recommend(candidates: [...])    evaluate all configs, pick      Optimal model +
                                  cheapest that passes            retry chain
```

## Before and after

```
  ┌─────────────────────────────────────────────────────────────────┐
  │ BEFORE: pick one model, hope for the best                      │
  │                                                                 │
  │   expensive model → accurate, but you overpay on every call     │
  │   cheap model     → fast, but wrong answers slip to production  │
  │   prompt change   → "looks good to me" → deploy → users suffer │
  └─────────────────────────────────────────────────────────────────┘

                         ⬇  add ruby_llm-contract

  ┌─────────────────────────────────────────────────────────────────┐
  │ YOU DEFINE A CONTRACT                                            │
  │                                                                 │
  │   output_schema { string :priority }       ← valid structure   │
  │   validate("valid priority") { |o| ... }   ← business rules    │
  │   retry_policy models: %w[nano mini full]  ← escalation chain  │
  │   max_cost 0.01                            ← budget cap         │
  └───────────────────────────┬─────────────────────────────────────┘
                              │
                              ▼
  ┌─────────────────────────────────────────────────────────────────┐
  │ THE GEM HANDLES THE REST                                        │
  │                                                                 │
  │   request ──→ ┌──────┐   ┌──────────┐                           │
  │               │ nano │─→ │ contract │──→ ✓ pass → done         │
  │               └──────┘   └────┬─────┘                           │
  │                               │ ✗ fail                          │
  │                               ▼                                 │
  │               ┌──────┐   ┌──────────┐                           │
  │               │ mini │─→ │ contract │──→ ✓ pass → done         │
  │               └──────┘   └────┬─────┘                           │
  │                               │ ✗ fail                          │
  │                               ▼                                 │
  │               ┌──────┐   ┌──────────┐                           │
  │               │ full │─→ │ contract │──→ ✓ pass → done         │
  │               └──────┘   └──────────┘                           │
  └───────────────────────────┬─────────────────────────────────────┘
                              │
                              ▼
  ┌─────────────────────────────────────────────────────────────────┐
  │ YOU GET                                                         │
  │                                                                 │
  │   ✓ Valid output guaranteed — schema + business rules enforced  │
  │   ✓ Cheapest model that works — most requests stay on nano     │
  │   ✓ Cost, latency, tokens — tracked on every call              │
  │   ✓ Eval scores per model — data instead of gut feeling        │
  │   ✓ Regressions caught — before deploy, not after              │
  │   ✓ Recommendation — "use nano+mini, drop full, save $X/mo"   │
  └─────────────────────────────────────────────────────────────────┘
```

## 30-second version

```ruby
class ClassifyTicket < RubyLLM::Contract::Step::Base
  prompt "Classify this support ticket by priority and category.\n\n{input}"

  output_schema do
    string :priority, enum: %w[low medium high urgent]
    string :category
  end

  validate("urgent needs justification") { |o, input| o[:priority] != "urgent" || input.length > 20 }
  retry_policy models: %w[gpt-4.1-nano gpt-4.1-mini gpt-4.1]
end

result = ClassifyTicket.run("I was charged twice")
result.parsed_output  # => {priority: "high", category: "billing"}
result.trace[:model]  # => "gpt-4.1-nano" (first model that passed)
result.trace[:cost]   # => 0.000032
```

Bad JSON? Retried automatically. Wrong answer? Escalated to a smarter model. Schema violated? Caught client-side. The contract guarantees every response meets your rules — you pay for the cheapest model that passes.

## Install

```ruby
gem "ruby_llm-contract"
```

```ruby
RubyLLM.configure { |c| c.openai_api_key = ENV["OPENAI_API_KEY"] }
RubyLLM::Contract.configure { |c| c.default_model = "gpt-4.1-mini" }
```

Works with any ruby_llm provider (OpenAI, Anthropic, Gemini, etc).

## Handle output variance with model escalation

Models are non-deterministic. A prompt that works on 95% of inputs can break on the edge case sitting in your production traffic right now. The defensive response is to pick the strongest model and pay for it on every call. The measured response is to define a contract and let the gem escalate only when the cheaper model's output actually fails the rules:

```ruby
retry_policy models: %w[gpt-4.1-nano gpt-4.1-mini gpt-4.1]
```

```
Attempt 1: gpt-4.1-nano  → contract failed  ($0.0001)
Attempt 2: gpt-4.1-mini  → contract passed  ($0.0004)
           gpt-4.1       → never called      ($0.00)
```

Most requests succeed on the cheapest model. The expensive ones fire only when output variance demands it. The cost win is a consequence of measuring variance correctly — not the primary goal. Want to know how often each tier triggers? Run `compare_models` against your dataset.

Default retry statuses (since 0.7.0) are `:validation_failed` and `:parse_error` — the two flavors of LLM output variance. Transport errors (rate limits, timeouts, 5xx) are retried by ruby_llm at the HTTP layer and intentionally not duplicated here. If you want `:adapter_error` in retry too, opt in explicitly — it's meaningful paired with an escalation chain.

## Know which model to use — with data

Don't guess. Define test cases, compare models, get numbers:

```ruby
ClassifyTicket.define_eval("regression") do
  add_case "billing", input: "I was charged twice", expected: { priority: "high" }
  add_case "feature", input: "Add dark mode please", expected: { priority: "low" }
  add_case "outage",  input: "Database is down",    expected: { priority: "urgent" }
end

comparison = ClassifyTicket.compare_models("regression",
  models: %w[gpt-4.1-nano gpt-4.1-mini gpt-4.1])
```

```
Candidate                  Score       Cost  Avg Latency
---------------------------------------------------------
gpt-4.1-nano                0.67    $0.0001         48ms
gpt-4.1-mini                1.00    $0.0004         92ms
gpt-4.1                     1.00    $0.0021        210ms

Cheapest at 100%: gpt-4.1-mini
```

Nano fails on edge cases. Mini and full both score 100% — but mini is **5x cheaper**. Now you know.

Running live against gpt-5 / o-series? Pass `runs: 3` to average out sampling variance (OpenAI forces `temperature=1.0` server-side, so one unlucky run can misclassify a viable candidate). See [Reducing variance with `runs:`](docs/guide/optimizing_retry_policy.md#reducing-variance-with-runs).

Want the *effective* cost — first-attempt plus retries — rather than the single-shot headline number? Pass `production_mode: { fallback: "gpt-5-mini" }` and the table gains `escalation`, `effective cost`, and a `Chain` column. See [Production-mode cost measurement](docs/guide/optimizing_retry_policy.md#production-mode-cost-measurement).

## Let the gem tell you what to do

Don't read tables — get a recommendation. Supports `model + reasoning_effort` combinations:

```ruby
rec = ClassifyTicket.recommend("regression",
  candidates: [
    { model: "gpt-4.1-nano" },
    { model: "gpt-4.1-mini" },
    { model: "gpt-5-mini", reasoning_effort: "low" },
    { model: "gpt-5-mini", reasoning_effort: "high" },
  ],
  min_score: 0.95
)

rec.best           # => { model: "gpt-4.1-mini" }
rec.retry_chain    # => [{ model: "gpt-4.1-nano" }, { model: "gpt-4.1-mini" }]
rec.to_dsl         # => "retry_policy models: %w[gpt-4.1-nano gpt-4.1-mini]"
rec.savings        # => savings vs your current model (if configured)
```

Copy `rec.to_dsl` into your step. Done.

## Catch regressions before users do

A model update silently dropped your accuracy? A prompt tweak broke an edge case? You'll know before deploying:

```ruby
# Save a baseline once:
report = ClassifyTicket.run_eval("regression", context: { model: "gpt-4.1-nano" })
report.save_baseline!(model: "gpt-4.1-nano")

# In CI — block merge if anything regressed:
expect(ClassifyTicket).to pass_eval("regression")
  .with_context(model: "gpt-4.1-nano")
  .without_regressions
```

```ruby
diff = report.compare_with_baseline(model: "gpt-4.1-nano")
diff.regressed?    # => true
diff.regressions   # => [{case: "outage", baseline: {passed: true}, current: {passed: false}}]
diff.score_delta   # => -0.33
```

No more "it worked in the playground". Regressions are caught in CI, not production.

## A/B test your prompts

Changed a prompt? Compare old vs new on the same dataset with regression safety:

```ruby
diff = ClassifyTicketV2.compare_with(ClassifyTicketV1,
  eval: "regression", model: "gpt-4.1-mini")

diff.safe_to_switch?  # => true (no regressions)
diff.improvements     # => [{case: "outage", ...}]
diff.score_delta      # => +0.33
```

```ruby
# CI gate:
expect(ClassifyTicketV2).to pass_eval("regression")
  .compared_with(ClassifyTicketV1)
  .with_minimum_score(0.8)
```

## Chain steps with fail-fast

Pipeline stops at the first contract failure — no wasted tokens on downstream steps:

```ruby
class TicketPipeline < RubyLLM::Contract::Pipeline::Base
  step ClassifyTicket,  as: :classify
  step RouteToTeam,     as: :route
  step DraftResponse,   as: :draft
end

result = TicketPipeline.run("I was charged twice")
result.outputs_by_step[:classify]   # => {priority: "high", category: "billing"}
result.trace.total_cost             # => $0.000128
```

## Gate merges on quality and cost

```ruby
# RSpec — block merge if accuracy drops or cost spikes
expect(ClassifyTicket).to pass_eval("regression")
  .with_minimum_score(0.8)
  .with_maximum_cost(0.01)

# Rake — run all evals across all steps
RubyLLM::Contract::RakeTask.new do |t|
  t.minimum_score = 0.8
  t.maximum_cost = 0.05
end
# bundle exec rake ruby_llm_contract:eval
```

## Full power: data-driven retry chains

The pieces above — evals, compare_models, recommend — combine into a workflow that replaces guesswork with measured optimization. You define evals for your step, run `recommend` against all of them, find the eval that actually needs the strongest model, and build a retry chain where each attempt is as cheap as the data allows.

The difference: instead of "gpt-5-mini seems to work, let's use it everywhere", you get "nano handles 4/6 scenarios, mini@low catches the 5th, full mini only fires on the hardest edge case — first attempt is 4× cheaper."

Full procedure with examples: **[Optimizing retry_policy](docs/guide/optimizing_retry_policy.md)**

## Docs

| Guide | |
|-------|-|
| [Getting Started](docs/guide/getting_started.md) | Features walkthrough, model escalation, eval |
| [Eval-First](docs/guide/eval_first.md) | Practical workflow for prompt engineering with datasets, baselines, and A/B gates |
| [Optimizing retry_policy](docs/guide/optimizing_retry_policy.md) | Find the cheapest retry chain that passes all your evals |
| [Best Practices](docs/guide/best_practices.md) | 6 patterns for bulletproof validates |
| [Output Schema](docs/guide/output_schema.md) | Full schema reference + constraints |
| [Pipeline](docs/guide/pipeline.md) | Multi-step composition, timeout, fail-fast |
| [Testing](docs/guide/testing.md) | Test adapter, RSpec matchers |
| [Migration](docs/guide/migration.md) | Adopting the gem in existing Rails apps |

## Roadmap

**v0.7 (current):** Sharpened retry semantics. `DEFAULT_RETRY_ON` now targets LLM output variance only (`:validation_failed`, `:parse_error`); transport errors are delegated to ruby_llm's Faraday retry. `AdapterCaller` narrowed to let programmer errors propagate instead of masking them as retries. Breaking change — see [CHANGELOG](CHANGELOG.md) for migration.

**v0.6:** "What should I do?" — `Step.recommend` returns optimal model, reasoning effort, and retry chain. Per-attempt `reasoning_effort` in retry policies.

**v0.5:** Prompt A/B testing with `compare_with`. Soft observations with `observe`.

**v0.4:** Eval history, batch concurrency, pipeline per-step eval, Minitest, structured logging.

**v0.3:** Baseline regression detection, migration guide.

## License

MIT
