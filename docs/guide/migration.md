# Migration Guide

How to adopt ruby_llm-contract in an existing Rails app.

## Step 1: Start with the simplest service

Pick the LLM service with: single input → JSON output → DB save. Don't start with parallel batches or complex pipelines.

## Step 2: Define the contract

**Before — raw HTTP:**
```ruby
class ClassifyService
  def call(text)
    response = LlmClient.new(model: "gpt-4o-mini").call(prompt(text))
    JSON.parse(response[:content], symbolize_names: true)
  end
end
```

**After — contract:**
```ruby
class ClassifyTicket < RubyLLM::Contract::Step::Base
  model "gpt-4.1-mini"

  prompt do
    system "You classify support tickets."
    rule "Return valid JSON only."
    user "{input}"
  end

  output_schema do
    string :priority, enum: %w[low medium high urgent]
    string :category
  end

  validate("urgent needs justification") { |o, input| o[:priority] != "urgent" || input.length > 20 }
  retry_policy models: %w[gpt-4.1-mini gpt-4.1]
end
```

## Step 3: Replace the caller

```ruby
# Before
parsed = ClassifyService.new.call(ticket_text)
Ticket.update!(priority: parsed["priority"])

# After
result = ClassifyTicket.run(ticket_text)
if result.ok?
  Ticket.update!(priority: result.parsed_output[:priority])
else
  Rails.logger.warn "Classification failed: #{result.status}"
end
```

## Step 4: Add logging via around_call

```ruby
class ClassifyTicket < RubyLLM::Contract::Step::Base
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
ClassifyTicket.define_eval("regression") do
  add_case "billing", input: "I was charged twice", expected: { priority: "high" }
  add_case "feature", input: "Add dark mode", expected: { priority: "low" }
  add_case "outage", input: "Database is down", expected: { priority: "urgent" }
end
```

## Step 6: Find the cheapest model

```ruby
comparison = ClassifyTicket.compare_models("regression",
  models: %w[gpt-4.1-nano gpt-4.1-mini])

comparison.print_summary
comparison.best_for(min_score: 0.95)  # => cheapest model at >= 95%
```

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

**Rails apps:** If your adapter is configured in an initializer, use a Proc so context is resolved after Rails boots:

```ruby
RubyLLM::Contract::RakeTask.new do |t|
  t.context = -> { { adapter: RubyLLM::Contract.configuration.default_adapter } }
  t.minimum_score = 0.8
end
```

## Common patterns

| Old pattern | New pattern |
|-------------|-------------|
| `LlmClient.new(model:).call(prompt)` | `MyStep.run(input)` |
| `JSON.parse(response[:content])` | `result.parsed_output` |
| `begin; rescue; retry; end` | `retry_policy models: [...]` |
| `body[:temperature] = 0.7` | `temperature 0.7` |
| `AiCallLog.create(...)` | `around_call { \|s, i, r\| ... }` |
| `response_format: JsonSchema.build(...)` | `output_schema do...end` |
| `stub_request(:post, ...)` | `stub_step(MyStep, response: {...})` |

## Anti-patterns

**Don't migrate markdown/text output services.** The gem is for structured JSON. Prose output gets no benefit from schema validation.

**Don't put parallelism in the gem.** Thread management is your app's concern. The gem provides the contract; you call it however you want.

**Don't migrate all services at once.** Start with one. Validate the pattern. Then migrate the next.

## Parallel batch generation

The gem handles single calls. You handle parallelism:

```ruby
class GenerateBatch < RubyLLM::Contract::Step::Base
  output_schema do
    array :items do; object do; string :name; end; end
  end
  retry_policy models: %w[gpt-4.1-mini gpt-4.1]
end

# Your orchestrator
threads = 10.times.map do |i|
  Thread.new { Rails.application.executor.wrap { GenerateBatch.run(input(i)) } }
end
results = threads.map(&:value)
```

**Note:** In tests, `stub_step` overrides are thread-local. If your orchestrator spawns threads, propagate overrides manually:

```ruby
overrides = RubyLLM::Contract.step_adapter_overrides.dup
Thread.new { RubyLLM::Contract.step_adapter_overrides = overrides; GenerateBatch.run(input) }
```
