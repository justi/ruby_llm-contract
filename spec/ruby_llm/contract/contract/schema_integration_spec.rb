# frozen_string_literal: true

require "ruby_llm/schema"

RSpec.describe "output_schema client-side validation" do
  before { RubyLLM::Contract.reset_configuration! }

  let(:schema_step) do
    Class.new(RubyLLM::Contract::Step::Base) do
      input_type RubyLLM::Contract::Types::String

      output_schema do
        string :intent, enum: %w[sales support billing]
        number :confidence, minimum: 0.0, maximum: 1.0
      end

      prompt do
        system "Classify intent."
        user "{input}"
      end
    end
  end

  it "passes valid output with Test adapter" do
    adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"intent": "sales", "confidence": 0.9}')
    result = schema_step.run("test", context: { adapter: adapter })

    expect(result.status).to eq(:ok)
  end

  it "catches invalid enum with Test adapter" do
    adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"intent": "INVALID", "confidence": 0.9}')
    result = schema_step.run("test", context: { adapter: adapter })

    expect(result.status).to eq(:validation_failed)
    expect(result.validation_errors.join).to match(/intent.*not in enum/)
  end

  it "catches out-of-range number with Test adapter" do
    adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"intent": "sales", "confidence": 2.5}')
    result = schema_step.run("test", context: { adapter: adapter })

    expect(result.status).to eq(:validation_failed)
    expect(result.validation_errors.join).to match(/confidence.*above maximum/)
  end

  it "catches missing required field with Test adapter" do
    adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"intent": "sales"}')
    result = schema_step.run("test", context: { adapter: adapter })

    expect(result.status).to eq(:validation_failed)
    expect(result.validation_errors.join).to match(/missing required field: confidence/)
  end

  it "catches wrong type with Test adapter" do
    adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"intent": 42, "confidence": 0.9}')
    result = schema_step.run("test", context: { adapter: adapter })

    expect(result.status).to eq(:validation_failed)
    expect(result.validation_errors.join).to match(/intent.*expected string/i)
  end

  it "still evaluates invariants alongside schema validation" do
    step_with_invariant = Class.new(RubyLLM::Contract::Step::Base) do
      input_type RubyLLM::Contract::Types::String

      output_schema do
        string :intent, enum: %w[sales support billing]
        number :confidence, minimum: 0.0, maximum: 1.0
      end

      prompt { user "{input}" }

      contract do
        invariant("high confidence required") { |o| o[:confidence] >= 0.8 }
      end
    end

    # Schema passes, invariant fails
    adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"intent": "sales", "confidence": 0.3}')
    result = step_with_invariant.run("test", context: { adapter: adapter })

    expect(result.status).to eq(:validation_failed)
    expect(result.validation_errors).to include("high confidence required")
  end
end
