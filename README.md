# ruby_llm-contract

Contracts for LLM quality. Know which model to use, what it costs, and when accuracy drops.

Companion gem for [ruby_llm](https://github.com/crmne/ruby_llm).

## The problem

Which model should you use? The expensive one is accurate but costs 4x more. The cheap one is fast but hallucinates on edge cases. You tweak a prompt — did accuracy improve or drop? You have no data. Just gut feeling.

## The fix

```ruby
class ClassifyTicket < RubyLLM::Contract::Step::Base
  prompt do
    system "You are a support ticket classifier."
    rule "Return valid JSON only, no markdown."
    rule "Use exactly one priority: low, medium, high, urgent."
    example input: "My invoice is wrong", output: '{"priority": "high"}'
    user "{input}"
  end

  output_schema do
    string :priority, enum: %w[low medium high urgent]
    string :category
  end

  validate("urgent needs justification") { |o, input| o[:priority] != "urgent" || input.length > 20 }
  retry_policy models: %w[gpt-4.1-nano gpt-4.1-mini gpt-4.1]
end

result = ClassifyTicket.run("I was charged twice")
result.ok?               # => true
result.parsed_output     # => {priority: "high", category: "billing"}
result.trace[:cost]      # => 0.000032
result.trace[:model]     # => "gpt-4.1-nano"
```

Bad JSON? Auto-retry. Wrong value? Escalate to a smarter model. Schema violated? Caught client-side even if the provider ignores it. All with cost tracking.

## Which model should I use?

Define test cases. Compare models. Get data.

```ruby
ClassifyTicket.define_eval("regression") do
  add_case "billing", input: "I was charged twice", expected: { priority: "high" }
  add_case "feature", input: "Add dark mode please", expected: { priority: "low" }
  add_case "outage",  input: "Database is down",    expected: { priority: "urgent" }
end

comparison = ClassifyTicket.compare_models("regression",
  models: %w[gpt-4.1-nano gpt-4.1-mini])
```

Real output from real API calls:

```
Model                      Score       Cost  Avg Latency
---------------------------------------------------------
gpt-4.1-nano                0.67    $0.000032      687ms
gpt-4.1-mini                1.00    $0.000102     1070ms

Cheapest at 100%: gpt-4.1-mini
```

```ruby
comparison.best_for(min_score: 0.95)  # => "gpt-4.1-mini"

# Inspect failures
comparison.reports["gpt-4.1-nano"].failures.each do |f|
  puts "#{f.name}: expected #{f.expected}, got #{f.output}"
  puts "  mismatches: #{f.mismatches}"
  # => outage: expected {priority: "urgent"}, got {priority: "high"}
  #      mismatches: {priority: {expected: "urgent", got: "high"}}
end
```

## Pipeline

Chain steps with fail-fast. Hallucination in step 1 stops before step 2 spends tokens.

```ruby
class TicketPipeline < RubyLLM::Contract::Pipeline::Base
  step ClassifyTicket,  as: :classify
  step RouteToTeam,     as: :route
  step DraftResponse,   as: :draft
end

result = TicketPipeline.run("I was charged twice")
result.ok?                          # => true
result.outputs_by_step[:classify]   # => {priority: "high", category: "billing"}
result.trace.total_cost             # => 0.000128
```

## CI gate

```ruby
# RSpec — block merge if accuracy drops or cost spikes
expect(ClassifyTicket).to pass_eval("regression")
  .with_context(model: "gpt-4.1-mini")
  .with_minimum_score(0.8)
  .with_maximum_cost(0.01)

# Rake — run all evals across all steps
require "ruby_llm/contract/rake_task"
RubyLLM::Contract::RakeTask.new do |t|
  t.minimum_score = 0.8
  t.maximum_cost = 0.05
end
# bundle exec rake ruby_llm_contract:eval
```

## Detect quality drops

Save a baseline. Next run, see what regressed.

```ruby
report = ClassifyTicket.run_eval("regression", context: { model: "gpt-4.1-nano" })
report.save_baseline!(model: "gpt-4.1-nano")

# Later — after prompt change, model update, or provider weight shift:
report = ClassifyTicket.run_eval("regression", context: { model: "gpt-4.1-nano" })
diff = report.compare_with_baseline(model: "gpt-4.1-nano")

diff.regressed?    # => true
diff.regressions   # => [{case: "outage", baseline: {passed: true}, current: {passed: false}}]
diff.score_delta   # => -0.33
```

```ruby
# CI: block merge if any previously-passing case now fails
expect(ClassifyTicket).to pass_eval("regression")
  .with_context(model: "gpt-4.1-nano")
  .without_regressions
```

## Predict cost before running

```ruby
ClassifyTicket.estimate_eval_cost("regression", models: %w[gpt-4.1-nano gpt-4.1-mini])
# => { "gpt-4.1-nano" => 0.000024, "gpt-4.1-mini" => 0.000096 }
```

## Install

```ruby
gem "ruby_llm-contract"
```

```ruby
RubyLLM.configure { |c| c.openai_api_key = ENV["OPENAI_API_KEY"] }
RubyLLM::Contract.configure { |c| c.default_model = "gpt-4.1-mini" }
```

Works with any ruby_llm provider (OpenAI, Anthropic, Gemini, etc).

## Docs

| Guide | |
|-------|-|
| [Getting Started](docs/guide/getting_started.md) | Features walkthrough, model escalation, eval |
| [Best Practices](docs/guide/best_practices.md) | 6 patterns for bulletproof validates |
| [Output Schema](docs/guide/output_schema.md) | Full schema reference + constraints |
| [Pipeline](docs/guide/pipeline.md) | Multi-step composition, timeout, fail-fast |
| [Testing](docs/guide/testing.md) | Test adapter, RSpec matchers |
| [Migration](docs/guide/migration.md) | Adopting the gem in existing Rails apps |

## Roadmap

**v0.3 (current):** Baseline regression detection, migration guide, production hardening.

**v0.4:** Observability & scale — eval history with trending, batch eval with concurrency, pipeline per-step eval, Minitest support, structured logging.

**v0.5:** Prompt A/B testing — `compare_with(OtherStep)` for data-driven prompt engineering with regression safety. Cross-provider comparison docs.

## License

MIT
