# ruby_llm-contract

Stop guessing which model to use. Stop hoping your prompts still work after changes. Get contracts, cost tracking, and data-driven model selection for [ruby_llm](https://github.com/crmne/ruby_llm).

```
  YOU WRITE                       THE GEM HANDLES                 YOU GET
  ─────────                       ───────────────                 ───────

  validate { |o| ... }            catch bad answers, retry,       Zero garbage
                                  escalate to smarter model       in production

  retry_policy                    start cheap, escalate only      $7/mo not $200
  models: %w[nano mini full]      when validation fails           (10k calls)

  max_cost 0.01                   estimate tokens, check price,   No surprise bills
                                  refuse before calling LLM

  output_schema { ... }           force JSON structure, parse,    Zero parsing code
                                  validate client-side

  define_eval { ... }             run cases every PR, compare     Regressions caught
                                  baselines, gate merge           in CI not prod

  recommend(candidates: [...])    evaluate all configs, pick      Optimal model +
                                  cheapest that passes            $17/mo saved
```

## The problem

You call an LLM. Sometimes it returns garbage. You retry manually. You pick gpt-4.1 "because it's good" but it costs 20x more than nano — and nano handles 90% of your requests just fine. You change a prompt, eyeball a few outputs, and deploy. Two weeks later, a model update quietly drops your accuracy from 95% to 70%. Nobody notices until users complain.

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
result.trace[:model]  # => "gpt-4.1-nano" (cheapest model that passed)
result.trace[:cost]   # => $0.000032
```

Bad JSON? Retried automatically. Wrong answer? Escalated to a smarter model. Schema violated? Caught client-side. You pay for the cheapest model that works — not the most expensive one "just in case".

## Install

```ruby
gem "ruby_llm-contract"
```

```ruby
RubyLLM.configure { |c| c.openai_api_key = ENV["OPENAI_API_KEY"] }
RubyLLM::Contract.configure { |c| c.default_model = "gpt-4.1-mini" }
```

Works with any ruby_llm provider (OpenAI, Anthropic, Gemini, etc).

## Save money with model escalation

Without contracts, you use gpt-4.1 for everything because you can't tell when a cheaper model gets it wrong. With contracts, you start on nano and only escalate when the answer fails validation:

```ruby
retry_policy models: %w[gpt-4.1-nano gpt-4.1-mini gpt-4.1]
```

```
Attempt 1: gpt-4.1-nano  → validation_failed  ($0.0001)
Attempt 2: gpt-4.1-mini  → ok                  ($0.0004)
           gpt-4.1       → never called         ($0.00)
```

90% of requests succeed on nano. At 10k requests/month: **~$40 instead of ~$200**.

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
rec.savings        # => { per_call: 0.0017, monthly_at: { 10000 => 17.0 } }
rec.to_dsl         # => "retry_policy models: %w[gpt-4.1-nano gpt-4.1-mini]"
```

Copy `rec.to_dsl` into your step. Done. **$17/month saved at 10k calls**.

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

Pipeline stops at the first contract failure. No wasted tokens on downstream steps:

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

## Docs

| Guide | |
|-------|-|
| [Getting Started](docs/guide/getting_started.md) | Features walkthrough, model escalation, eval |
| [Eval-First](docs/guide/eval_first.md) | Practical workflow for prompt engineering with datasets, baselines, and A/B gates |
| [Best Practices](docs/guide/best_practices.md) | 6 patterns for bulletproof validates |
| [Output Schema](docs/guide/output_schema.md) | Full schema reference + constraints |
| [Pipeline](docs/guide/pipeline.md) | Multi-step composition, timeout, fail-fast |
| [Testing](docs/guide/testing.md) | Test adapter, RSpec matchers |
| [Migration](docs/guide/migration.md) | Adopting the gem in existing Rails apps |

## Roadmap

**v0.6 (current):** "What should I do?" — `Step.recommend` returns optimal model, reasoning effort, and retry chain. Per-attempt `reasoning_effort` in retry policies.

**v0.5:** Prompt A/B testing with `compare_with`. Soft observations with `observe`.

**v0.4:** Eval history, batch concurrency, pipeline per-step eval, Minitest, structured logging.

**v0.3:** Baseline regression detection, migration guide.

## License

MIT
