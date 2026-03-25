# Getting Started

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
  max_input  2_000
  max_output 4_000
  max_cost   0.01
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

**Model priority:** `retry_policy models: %w[nano mini full]` tries models left to right. First model is always tried first. `context: { model: "..." }` is ignored when `retry_policy` is set — the policy controls model selection. Without `retry_policy`, the model comes from `context[:model]` or `default_model`.

**Limits prevent runaway costs:**
```ruby
result = ClassifyTicket.run(giant_10mb_document)
result.status            # => :limit_exceeded
result.validation_errors # => ["Input token limit exceeded: estimated 32000 tokens, max 2000"]
# LLM was never called. Zero tokens spent. Zero cost.
```

`max_cost` refuses the call when model pricing is unknown (fail closed). Register pricing for custom or fine-tuned models:

```ruby
RubyLLM::Contract::CostCalculator.register_model("ft:gpt-4o-custom",
  input_per_1m: 3.0, output_per_1m: 6.0)
```

**Eval verifies your contract — offline or online:**

Offline mode (zero API calls) — uses a canned response to verify schema + validates:
```ruby
ClassifyTicket.define_eval("smoke") do
  default_input "My invoice is wrong"
  sample_response({ priority: "high", category: "billing", confidence: 0.92 })
end

report = ClassifyTicket.run_eval("smoke")
report.passed?  # => true — schema + validates pass on sample data
report.score    # => 1.0
```

Online mode (v0.2) — define cases with expected output, then compare models:
```ruby
ClassifyTicket.define_eval("regression") do
  add_case "billing complaint",
           input: "My invoice is wrong",
           expected: { priority: "high", category: "billing" }  # partial match

  add_case "urgent outage",
           input: "Server is down, customers affected",
           expected: { priority: "urgent" }
end

# Run against one model
report = ClassifyTicket.run_eval("regression")
report.score  # => 1.0

# Compare models — find the cheapest one that passes
comparison = ClassifyTicket.compare_models("regression",
                                           models: %w[gpt-4.1-nano gpt-4.1-mini gpt-4.1])
comparison.print_summary
#   Model                      Score       Cost  Avg Latency
#   ---------------------------------------------------------
#   gpt-4.1-nano                0.50    $0.0001         48ms
#   gpt-4.1-mini                1.00    $0.0004         92ms
#   gpt-4.1                     1.00    $0.0021        210ms
#
#   Cheapest at 100%: gpt-4.1-mini
```

In CI — gate on score threshold and cost:
```ruby
# rspec
expect(ClassifyTicket).to pass_eval("regression")
  .with_minimum_score(0.8)
  .with_maximum_cost(0.01)
```

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

## Already using ruby_llm?

You might think: "I already have `RubyLLM.chat`, `with_schema`, and my own retry loop. Why do I need this?"

**What you write today (per call site):**
```ruby
3.times do |attempt|
  response = RubyLLM.chat(model: "gpt-4.1-mini").ask(prompt)
  parsed = JSON.parse(response.content)
  break if parsed["priority"].in?(%w[low medium high urgent])
rescue JSON::ParserError
  next
end
```
Multiply by 7 call sites = ~500 lines of boilerplate. Each with its own retry logic, error handling, and validation.

**What you write with this gem:**
```ruby
class ClassifyTicket < RubyLLM::Contract::Step::Base
  prompt "Classify this ticket by priority.\n\n{input}"
  validate("valid priority") { |o| %w[low medium high urgent].include?(o[:priority]) }
  retry_policy models: %w[gpt-4.1-nano gpt-4.1-mini gpt-4.1]
end
```

**Three things you can't easily build yourself:**

1. **Model escalation with quality gate.** Start every request on nano ($0.10/M tokens). When `validate` catches a bad answer, auto-retry on mini ($0.40/M), then full ($2.00/M). 90% of requests succeed on nano. At 10k requests/month: ~$40 instead of ~$200.

2. **Eval that matters.** Offline smoke tests with `sample_response` (zero API calls). Online regression with `add_case` + partial matching. `compare_models` to find the cheapest model that passes. Cost tracking per eval run. CI gating with `with_minimum_score(0.8)` and `with_maximum_cost(0.01)`. No other Ruby gem does this.

3. **Defensive parsing.** LLM wraps JSON in ` ```json ``` `? Stripped. UTF-8 BOM? Stripped. Prose around JSON? Extracted. `null` response? Caught. 14 edge cases in the parser.

**`output_schema` vs `with_schema`:**

`with_schema` in ruby_llm tells the provider to force a specific JSON structure. `output_schema` in this gem does the **same thing** (calls `with_schema` under the hood) **plus** validates the response client-side. Why both? Because cheaper models sometimes ignore schema constraints. `with_schema` is a request; `output_schema` is a request + verification.
