# ruby_llm-contract

Contracts for LLM quality. Know which model to use, what it costs, and when accuracy drops.

Companion gem for [ruby_llm](https://github.com/crmne/ruby_llm).

## The problem

You call an LLM. It returns bad JSON, wrong values, or costs 4x more than it should. You switch models and quality drops silently. You have no data to decide which model to use.

## The fix

```ruby
class ClassifyTicket < RubyLLM::Contract::Step::Base
  prompt "Classify this support ticket by priority. Return JSON. {input}"
  validate("valid priority") { |o| %w[low medium high urgent].include?(o[:priority]) }
  retry_policy models: %w[gpt-4.1-nano gpt-4.1-mini gpt-4.1]
end

result = ClassifyTicket.run(ticket_text)
result.ok?               # => true
result.parsed_output     # => {priority: "high"}
result.trace[:cost]      # => 0.000032
```

Bad JSON? Auto-retry. Wrong value? Escalate to a smarter model. All with cost tracking.

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

nano got 2/3 right at 3x less cost. mini got 3/3. Now you have data to decide.

```ruby
comparison.best_for(min_score: 0.95)  # => "gpt-4.1-mini"
```

## Predict cost before running

```ruby
ClassifyTicket.estimate_eval_cost("regression", models: %w[gpt-4.1-nano gpt-4.1-mini])
# => { "gpt-4.1-nano" => 0.000024, "gpt-4.1-mini" => 0.000096 }
```

## CI gate

```ruby
# RSpec
expect(ClassifyTicket).to pass_eval("regression")
  .with_context(model: "gpt-4.1-mini")
  .with_minimum_score(0.8)
  .with_maximum_cost(0.01)

# Rake (add to Rakefile)
require "ruby_llm/contract/rake_task"
RubyLLM::Contract::RakeTask.new do |t|
  t.minimum_score = 0.8
  t.maximum_cost = 0.05
end
# bundle exec rake ruby_llm_contract:eval
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

## What you get

- **Model comparison** — `compare_models` runs same eval on multiple models, shows score/cost/latency table. `best_for(min_score: 0.95)` returns cheapest model meeting your threshold.
- **Cost prediction** — `estimate_cost` and `estimate_eval_cost` predict spend before calling the API.
- **Eval in CI** — `add_case input:, expected:` with partial matching. `with_minimum_score(0.8)` + `with_maximum_cost(0.01)` gates merges.
- **Model escalation** — `retry_policy models: %w[nano mini full]` starts cheap, auto-escalates on failure.
- **Validated responses** — `validate` + `output_schema` enforce correctness at runtime.
- **Cost control** — `max_input`, `max_cost` refuse before calling the LLM.
- **Pipeline** — chain steps with fail-fast, timeout, cost tracking across all steps.
- **Defensive parsing** — code fences, BOM, prose wrapping — 14 edge cases handled.

## Docs

| Guide | |
|-------|-|
| [Getting Started](docs/guide/getting_started.md) | Features walkthrough, model escalation, eval |
| [Best Practices](docs/guide/best_practices.md) | 6 patterns for bulletproof validates |
| [Output Schema](docs/guide/output_schema.md) | Full schema reference + constraints |
| [Pipeline](docs/guide/pipeline.md) | Multi-step composition, timeout, fail-fast |
| [Testing](docs/guide/testing.md) | Test adapter, RSpec matchers |

## Roadmap

**v0.2 (current):** Model comparison, cost tracking, eval with `add_case`, CI gating, Rails Railtie.

**v0.3:** Regression baselines — compare eval results with previous run, detect quality drift.

**v0.4:** Auto-routing — learn which model works for which input pattern.

## License

MIT
