# ruby_llm-contract

Stop hoping your LLM returns the right JSON. Validate every response, retry with smarter models, catch bad answers before they hit production.

[![Tests](https://img.shields.io/badge/tests-1005%20passing-brightgreen)]()
[![RuboCop](https://img.shields.io/badge/rubocop-0%20offenses-brightgreen)]()
[![Ruby](https://img.shields.io/badge/ruby-%3E%3D%203.2-red)]()
[![Bugs found](https://img.shields.io/badge/adversarial%20QA-42%20bugs%20found%20%26%20fixed-blue)]()

## Why?

You have a prompt that works. You call the LLM, parse JSON, cross your fingers:

```ruby
response = client.chat("Classify this ticket: #{text}")
result = JSON.parse(response)  # crashes at 3am when LLM returns "Sure! Here's the JSON: ..."
priority = result["priority"]  # "urgent"? "CRITICAL"? "idk lol"?
```

Three things go wrong in production:
1. **LLM returns garbage JSON** — your `JSON.parse` crashes and the job dies silently
2. **LLM returns valid JSON with wrong values** — `"CRITICAL"` instead of `"urgent"`, your routing breaks
3. **You switch to a cheaper model** — output quality drops but nothing tells you until users complain

## Before / After

**Before** — raw LLM call, hope for the best:

```ruby
response = client.chat(<<~PROMPT)
  Classify this support ticket by priority.
  Return JSON with a "priority" field.

  #{ticket_text}
PROMPT

parsed = JSON.parse(response)        # crashes on bad JSON
priority = parsed["priority"]        # might be anything
```

**After** — same prompt, wrapped in a contract:

```ruby
class ClassifyTicket < RubyLLM::Contract::Step::Base
  prompt <<~PROMPT
    Classify this support ticket by priority.
    Return JSON with a "priority" field.

    {input}
  PROMPT
end

result = ClassifyTicket.run(ticket_text)
result.ok?             # => true
result.parsed_output   # => {priority: "high"} — symbol keys, parsed automatically
result.raw_output      # => '{"priority":"high"}' — raw string preserved for debugging

# LLM returns garbage? No crash:
result.status            # => :parse_error
result.validation_errors # => ["Failed to parse JSON: ..."]
```

That's it. One class, one heredoc prompt, zero configuration beyond your API key. JSON parsing, error handling, and structured results — out of the box.

> **Note:** `{input}` is a gem placeholder, not Ruby interpolation. Use `{input}` (no `#`), not `#{input}`. The gem replaces it at runtime with the value you pass to `run()`.

## When you need more

The heredoc prompt is the starting point. Add features as your production needs grow:

```ruby
class ClassifyTicket < RubyLLM::Contract::Step::Base
  # STEP 1: You already have this — your prompt as a heredoc
  prompt <<~PROMPT
    Classify this support ticket by priority and category.
    Return JSON with priority, category, and confidence fields.

    {input}
  PROMPT

  # STEP 2: Add schema — sent to the LLM provider, which forces the model
  # to return this exact JSON structure (replaces manual type validates)
  output_schema do
    string :priority, enum: %w[low medium high urgent]
    string :category, enum: %w[billing technical feature other]
    number :confidence, minimum: 0.0, maximum: 1.0
  end

  # STEP 3: Add business logic that schema can't express
  validate("high confidence") { |o| o[:confidence] > 0.5 }

  # STEP 4: Start with a cheap model, auto-escalate when contract fails
  retry_policy models: %w[gpt-4.1-nano gpt-4.1-mini gpt-4.1]

  # STEP 5: Refuse before calling the LLM if input is too large or expensive
  max_input 2_000
  max_cost  0.01
end
```

Each step is optional. Here's what each layer catches in production:

**Validation catches wrong answers** (and retry auto-escalates to fix them):
```ruby
result = ClassifyTicket.run("Server is on fire, data is gone!")
result.status            # => :validation_failed
result.validation_errors # => ["high confidence"]
result.parsed_output     # => {priority: "low", category: "billing", confidence: 0.2}
# ^ LLM said "low priority" for a data loss incident. validate caught it.
# With retry_policy, the gem automatically retries with a smarter model.
# Without retry_policy, you get the failed result and decide what to do.
```

**Retry with model escalation saves money:**
```ruby
result = ClassifyTicket.run("I need help with billing")
result.trace[:attempts]
# => [{attempt: 1, model: "gpt-4.1-nano",  status: :validation_failed},  # $0.0001
#     {attempt: 2, model: "gpt-4.1-mini",  status: :ok}]                 # $0.0004
# Nano hallucinated, mini got it right. Never called full ($0.002).
# 90% of requests succeed on nano. You only pay more when you have to.
```

**Limits prevent runaway costs:**
```ruby
result = ClassifyTicket.run(giant_10mb_document)
result.status            # => :limit_exceeded
result.validation_errors # => ["Input token limit exceeded: estimated 32000 tokens, max 2000"]
# LLM was never called. Zero tokens spent. Zero cost.
```

**Eval verifies your contract offline (zero API calls):**
```ruby
ClassifyTicket.define_eval("smoke") do
  default_input "My invoice is wrong"
  sample_response({ priority: "high", category: "billing", confidence: 0.92 })
end

report = ClassifyTicket.run_eval("smoke")
report.passed?  # => true — schema + validates pass on sample data
report.score    # => 1.0

# In CI: ensure your contract still works after prompt changes
# rspec: expect(ClassifyTicket).to pass_eval("smoke")
```

**Used in production** to replace 8 raw LLM call sites in a Rails app — eliminated ~1,000 lines of manual prompt building, JSON parsing, retry logic, and error handling. Each call site became a single Step class.

## Installation

```ruby
gem "ruby_llm-contract"
```

Requires Ruby >= 3.2. Uses [ruby_llm](https://github.com/crmne/ruby_llm) for LLM calls.

## Quick Start

```ruby
RubyLLM.configure { |c| c.openai_api_key = ENV["OPENAI_API_KEY"] }
RubyLLM::Contract.configure { |c| c.default_model = "gpt-4.1-mini" }

class ClassifyIntent < RubyLLM::Contract::Step::Base
  prompt <<~PROMPT
    Classify the user's intent.
    Return JSON with an "intent" field.

    {input}
  PROMPT
end

result = ClassifyIntent.run("I need help with my invoice")
result.ok?             # => true
result.parsed_output   # => {intent: "billing"}
```

Input defaults to String, output defaults to Hash (JSON parsed automatically). Override only when you need something different.

## Structured Prompts

When you need system instructions, rules, or few-shot examples, upgrade from heredoc to block:

```ruby
class ClassifyIntent < RubyLLM::Contract::Step::Base
  output_schema do
    string :intent, enum: %w[sales support billing]
    number :confidence, minimum: 0.0, maximum: 1.0
  end

  prompt do
    system "Classify the user's intent."
    rule   "Return JSON only."
    example input: "I want to buy", output: '{"intent":"sales","confidence":0.95}'
    user   "{input}"
  end

  validate("high confidence") { |o| o[:confidence] > 0.5 }
  retry_policy models: %w[gpt-4.1-nano gpt-4.1-mini gpt-4.1]
end
```

## Dynamic Prompts

When your prompt needs data from Rails objects — conditional sections, formatted lists, runtime context — the block receives `|input|`:

```ruby
class ClassifyThreads < RubyLLM::Contract::Step::Base
  input_type Hash

  prompt do |input|
    system "You classify Reddit threads for #{input[:url]}."
    section "PRODUCT", input[:product_context]
    section "PAGES", input[:pages].map { |p| "- #{p[:title]}" }.join("\n") if input[:pages]&.any?
    user input[:threads].to_json
  end

  validate("all classified") do |output, input|
    output[:threads].map { |t| t[:id] }.sort == input[:thread_ids].sort
  end

  retry_policy models: %w[gpt-4.1-mini gpt-4.1-mini gpt-4.1]
end
```

| Your prompt needs | Use |
|-------------------|-----|
| Static text, one variable | `prompt "Classify: {input}"` |
| Multiple messages, static | `prompt do; system "..."; user "{input}"; end` |
| Dynamic data from objects | `prompt do \|input\|; section "X", input[:data]; end` |

## Pipeline

Chain steps with fail-fast — hallucinations in step 1 don't propagate:

```ruby
class TicketPipeline < RubyLLM::Contract::Pipeline::Base
  step ClassifyIntent,     as: :classify,  model: "gpt-4.1-nano"
  step GenerateResponse,   as: :respond,   model: "gpt-4.1-mini"
end

result = TicketPipeline.run("My invoice is wrong")
result.ok?                            # => true
result.outputs_by_step[:classify]     # => {intent: "billing", confidence: 0.92}
result.outputs_by_step[:respond]      # => {body: "I'll look into your invoice..."}
```

See [Pipeline guide](docs/guide/pipeline.md) for the full API (timeout, token budget, pretty print).

## Testing

```ruby
# Test adapter — deterministic, zero API calls
adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"intent":"billing"}')
result = ClassifyIntent.run("help", context: { adapter: adapter })
result.ok?  # => true

# RSpec matchers (require "ruby_llm/contract/rspec")
expect(result).to satisfy_contract
expect(ClassifyIntent).to pass_eval("smoke")
```

See [Testing guide](docs/guide/testing.md) for RSpec matchers, pipeline testing, and patterns.

## Configuration

Configure your LLM provider via RubyLLM, then set contract-specific options:

```ruby
# 1. Configure RubyLLM (API keys, provider settings)
RubyLLM.configure do |c|
  c.openai_api_key = ENV["OPENAI_API_KEY"]
end

# 2. Configure contract defaults (adapter auto-created from RubyLLM)
RubyLLM::Contract.configure do |c|
  c.default_model = "gpt-4.1-mini"
end
```

Works with any RubyLLM provider:

```ruby
# Anthropic
RubyLLM.configure { |c| c.anthropic_api_key = ENV["ANTHROPIC_API_KEY"] }
RubyLLM::Contract.configure { |c| c.default_model = "claude-sonnet-4-6" }

# Override per call
result = MyStep.run(input, context: { model: "gpt-4.1", temperature: 0.0 })
```

## Common Gotchas

**Nested schema: array of objects needs `object do...end`:**

```ruby
# WRONG — creates array of strings, not objects:
array :groups do
  string :who
end

# RIGHT — array of objects:
array :groups do
  object do
    string :who
  end
end
```

**Schema validates shape, not meaning.** An LLM can return `{"priority": "low"}` for a critical security incident — structurally valid, logically wrong. Always add `validate` blocks for business rules.

**Retry retries three failure modes by default:** `validation_failed`, `parse_error`, and `adapter_error` (network timeouts). `input_error` is never retried — bad input won't improve with a different model.

## Documentation

| Guide | What it covers |
|-------|---------------|
| [Best Practices](docs/guide/best_practices.md) | 6 patterns for bulletproof validates |
| [Output Schema](docs/guide/output_schema.md) | Full schema reference + constraint table |
| [Pipeline](docs/guide/pipeline.md) | Multi-step composition, timeout, pretty print |
| [Testing](docs/guide/testing.md) | Test adapter, RSpec matchers, pipeline testing |
| [Prompt AST](docs/guide/prompt_ast.md) | Node types, interpolation, dynamic prompts |
| [Architecture](docs/architecture.md) | Module diagram |

## Roadmap

- [ ] `Regression::Baseline` — snapshot comparison and CI gating
- [ ] Prompt diffing — `prompt_a.diff(prompt_b)` on AST
- [ ] CLI: `ruby_llm-contract eval`, `ruby_llm-contract baseline:update`

## License

MIT
