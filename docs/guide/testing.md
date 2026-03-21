# Testing

## Test Adapter

Ship deterministic specs with zero API calls:

```ruby
adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"intent":"billing"}')
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

## RSpec Matchers

Add to your `spec_helper.rb`:

```ruby
require "ruby_llm/contract/rspec"
```

Then test your steps with clean, expressive assertions:

```ruby
RSpec.describe ClassifyIntent do
  let(:adapter) { RubyLLM::Contract::Adapters::Test.new(response: '{"intent":"billing"}') }

  it "satisfies contract" do
    result = described_class.run("Change my invoice", context: { adapter: adapter })
    expect(result).to satisfy_contract
  end

  it "catches invalid output" do
    bad_adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"intent":"unknown"}')
    result = described_class.run("hello", context: { adapter: bad_adapter })
    expect(result).not_to satisfy_contract
    # Failure message:
    #   expected step result to satisfy contract, but got status: validation_failed
    #   Validation errors:
    #     - valid intent
    #   Raw output: {"intent":"unknown"}
  end

  it "passes eval" do
    expect(described_class).to pass_eval("smoke")
    # Runs define_eval("smoke") with sample_response — zero API calls
  end

  it "passes eval with real LLM" do
    expect(described_class).to pass_eval("smoke").with_context(adapter: real_adapter)
  end
end
```
