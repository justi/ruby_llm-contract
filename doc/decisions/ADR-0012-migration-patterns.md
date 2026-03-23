---
id: ADR-0012
decision_type: adr
status: Proposed
created: 2026-03-23
summary: "Migration patterns — how to adopt ruby_llm-contract in existing Rails apps"
owners:
  - justi
---

# ADR-0012: Migration Patterns

## Context

First real-world adoption (persona_tool, 5 LLM services) revealed common migration patterns. These should be documented as a guide for any Rails team adopting the gem.

This ADR defines the patterns. The guide will live at `docs/guide/migration.md`.

## Common migration patterns

### Pattern 1: Raw HTTP → Step

**Before:**
```ruby
class MyService
  def call(input)
    response = Faraday.post("https://api.openai.com/v1/chat/completions",
      { model: "gpt-4o-mini", messages: [{ role: "user", content: prompt }] }.to_json,
      headers)
    JSON.parse(response.body).dig("choices", 0, "message", "content")
  end
end
```

**After:**
```ruby
class MyStep < RubyLLM::Contract::Step::Base
  model "gpt-4.1-mini"
  prompt "Classify: {input}"
  validate("valid") { |o| o[:category].present? }
end

result = MyStep.run(input)
result.parsed_output  # => {category: "billing"}
```

### Pattern 2: Manual retry → retry_policy

**Before:**
```ruby
3.times do |attempt|
  response = client.call(prompt)
  parsed = JSON.parse(response)
  break if valid?(parsed)
rescue JSON::ParserError
  next
end
```

**After:**
```ruby
class MyStep < RubyLLM::Contract::Step::Base
  validate("valid") { |o| valid?(o) }
  retry_policy models: %w[gpt-4.1-nano gpt-4.1-mini gpt-4.1]
end
```

### Pattern 3: Manual logging → around_call

**Before:**
```ruby
start = Time.now
response = client.call(prompt)
AiCallLog.create!(model: "gpt-4o-mini", duration: Time.now - start, ...)
```

**After:**
```ruby
class MyStep < RubyLLM::Contract::Step::Base
  around_call do |step, input, result|
    AiCallLog.create!(
      model: result.trace.model,
      latency_ms: result.trace.latency_ms,
      input_tokens: result.trace.usage[:input_tokens],
      output_tokens: result.trace.usage[:output_tokens],
      cost: result.trace.cost,
      status: result.status
    )
  end
end
```

### Pattern 4: response_format JSON schema → output_schema

**Before:**
```ruby
response_format = {
  type: "json_schema",
  json_schema: {
    name: "output",
    strict: true,
    schema: { type: "object", properties: { priority: { type: "string", enum: %w[low high] } } }
  }
}
client.call(prompt, response_format: response_format)
```

**After:**
```ruby
class MyStep < RubyLLM::Contract::Step::Base
  output_schema do
    string :priority, enum: %w[low high]
  end
end
```

### Pattern 5: Parallel batch generation — orchestrator stays in app

**Before:**
```ruby
threads = 10.times.map do |i|
  Thread.new { client.call(batch_prompt(i)) }
end
results = threads.map(&:value)
```

**After:**
```ruby
# Step handles single batch
class GenerateBatch < RubyLLM::Contract::Step::Base
  output_schema do
    array :items do; object do; string :name; end; end
  end
  retry_policy models: %w[gpt-4.1-mini gpt-4.1]
end

# Orchestrator stays in app — parallelism is your concern
threads = 10.times.map do |i|
  Thread.new { GenerateBatch.run(batch_input(i)) }
end
```

### Pattern 6: Model fallback → retry_policy or model DSL

**Before:**
```ruby
begin
  response = client.call(prompt, model: "gpt-4o")
rescue LlmClient::Error
  response = client.call(prompt, model: "gpt-4o-mini")  # fallback
end
```

**After:**
```ruby
class MyStep < RubyLLM::Contract::Step::Base
  retry_policy models: %w[gpt-4.1-mini gpt-4.1]
end
# Or for single model without retry:
class MyStep < RubyLLM::Contract::Step::Base
  model "gpt-4.1-mini"
end
```

### Pattern 7: Test stubbing

**Before:**
```ruby
stub_request(:post, "https://api.openai.com/v1/chat/completions")
  .to_return(body: { choices: [{ message: { content: '{"a":1}' } }] }.to_json)
```

**After:**
```ruby
stub_step(MyStep, response: { a: 1 })
```

## Anti-patterns

### Don't migrate markdown/text output services

The gem is optimized for structured JSON. Services that return free-form text (reports, emails, summaries) get little benefit — schema can't validate prose quality.

### Don't put parallelism in the gem

Thread management, connection pooling, batch coordination = application concern. The gem provides the contract; the app decides how/when to call it.

### Don't migrate all services at once

Start with the simplest (single input → JSON → DB save). Validate the pattern. Then migrate harder services.

## Deliverable

`docs/guide/migration.md` with all 7 patterns + anti-patterns + step-by-step checklist.
