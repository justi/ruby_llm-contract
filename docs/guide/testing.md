# Testing

## Test Adapter

Ship deterministic specs with zero API calls. The adapter accepts String, Hash, or Array:

```ruby
# String JSON
adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"intent":"billing"}')

# Hash — auto-converted to JSON
adapter = RubyLLM::Contract::Adapters::Test.new(response: { intent: "billing" })

# Multiple sequential responses
adapter = RubyLLM::Contract::Adapters::Test.new(
  responses: [{ intent: "billing" }, { intent: "sales" }]
)

result = ClassifyIntent.run("Change my invoice", context: { adapter: adapter })
result.ok?  # => true
```

Multi-step pipeline testing with named responses:

```ruby
result = MyPipeline.test("input",
  responses: {
    extract:  { decisions: [...] },
    analyze:  { analyses: [...] },
    email:    { subject: "Follow-up", body: "..." }
  }
)
```

## Output keys are always symbols

Parsed output uses **symbol keys**, never string keys:

```ruby
result.parsed_output[:priority]   # => "high" ✓
result.parsed_output["priority"]  # => nil ✗
```

The gem warns if a `validate` or `verify` block returns `nil` — usually a sign of string key access on symbolized data.

## RSpec Setup

Add to your `spec_helper.rb`:

```ruby
require "ruby_llm/contract/rspec"
```

This gives you: `satisfy_contract`, `pass_eval` matchers, and the `stub_step` helper.

## stub_step Helper

Reduces test boilerplate — sets a global test adapter for a step:

```ruby
RSpec.describe ClassifyIntent do
  before { stub_step(described_class, response: { intent: "billing" }) }
  after  { RubyLLM::Contract.reset_configuration! }

  it "satisfies contract" do
    result = described_class.run("Change my invoice")
    expect(result).to satisfy_contract
  end
end
```

For multiple responses:
```ruby
stub_step(described_class, responses: [{ intent: "billing" }, { intent: "sales" }])
```

## RSpec Matchers

```ruby
RSpec.describe ClassifyIntent do
  before { stub_step(described_class, response: { intent: "billing" }) }

  it "satisfies contract" do
    result = described_class.run("Change my invoice")
    expect(result).to satisfy_contract
  end

  it "catches invalid output" do
    stub_step(described_class, response: { intent: "unknown" })
    result = described_class.run("hello")
    expect(result).not_to satisfy_contract
  end

  it "passes eval" do
    expect(described_class).to pass_eval("smoke")
  end
end
```

## Eval with Test Cases

v0.2 adds `add_case` inside `define_eval` for dataset-driven evaluation:

```ruby
ClassifyTicket.define_eval("regression") do
  add_case "billing", input: "I was charged twice", expected: { priority: "high" }
  add_case "feature", input: "Add dark mode", expected: { priority: "low" }
end
```

Each case runs the step and compares the output against `expected`. Fields in `expected` are matched by key -- extra output keys are ignored.

Set a shared input with `default_input` when all cases share the same shape:

```ruby
ClassifyTicket.define_eval("regression") do
  default_input "I was charged twice"
  add_case "detects billing", expected: { category: "billing" }
  add_case "high priority",  expected: { priority: "high" }
end
```

## Threshold-Based Gating

Chain `.with_minimum_score` and `.with_maximum_cost` onto `pass_eval` to set acceptance thresholds:

```ruby
expect(ClassifyTicket).to pass_eval("regression")
  .with_context(model: "gpt-4.1-mini")
  .with_minimum_score(0.8)
  .with_maximum_cost(0.01)
```

- `with_minimum_score(0.8)` -- pass if average score >= 0.8 (default requires 1.0)
- `with_maximum_cost(0.01)` -- fail if total cost exceeds $0.01

Both constraints must hold for the matcher to pass.

## Rake Task

Run all evals from the command line with a Rake task:

```ruby
# Rakefile
require "ruby_llm/contract/rake_task"

RubyLLM::Contract::RakeTask.new do |t|
  t.minimum_score = 0.8
  t.maximum_cost = 0.05
end
```

```sh
rake ruby_llm_contract:eval
```

The task discovers every `define_eval` across your steps, runs them, and aborts if any threshold is breached. In Rails apps it automatically depends on `:environment`.

## Inspecting Failures

`run_eval` returns a `Report`. Drill into failures for programmatic assertions or debugging:

```ruby
report = ClassifyTicket.run_eval("regression")

report.score       # => 0.5
report.pass_rate   # => "1/2"
report.total_cost  # => 0.003

report.failures.each do |result|
  puts result.name       # => "feature"
  puts result.mismatches # => { priority: { expected: "low", got: "medium" } }
  puts result.output     # full parsed output hash
  puts result.details    # human-readable explanation
end
```

`mismatches` returns a hash of keys where `expected` and actual output diverge -- handy for pinpointing which field a model got wrong.
