# frozen_string_literal: true

RSpec.describe "Validate block crash should return validation_failed, not raise" do
  before { RubyLLM::Contract.reset_configuration! }

  it "returns :validation_failed when validate block raises TypeError" do
    step = Class.new(RubyLLM::Contract::Step::Base) do
      prompt "test {input}"
      # This validate expects output[:items] to be an Array of Hashes
      # but the LLM returns items as an Array of Strings
      validate("items have name") { |o| o[:items].all? { |i| i[:name].to_s.size > 0 } }
    end

    # LLM returns items as strings, not hashes — g[:name] raises TypeError
    adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"items": ["foo", "bar"]}')
    result = step.run("test", context: { adapter: adapter })

    # Should be a clean validation failure, NOT a raised exception
    expect(result.status).to eq(:validation_failed)
    expect(result.validation_errors.first).to include("items have name")
  end

  it "returns :validation_failed when validate block raises NoMethodError" do
    step = Class.new(RubyLLM::Contract::Step::Base) do
      prompt "test {input}"
      validate("has nested field") { |o| o[:deep][:nested].size > 0 }
    end

    # LLM returns deep as string, not hash — [:nested] raises NoMethodError
    adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"deep": "not a hash"}')
    result = step.run("test", context: { adapter: adapter })

    expect(result.status).to eq(:validation_failed)
    expect(result.validation_errors.first).to include("has nested field")
  end

  it "still reports normal validate failures cleanly" do
    step = Class.new(RubyLLM::Contract::Step::Base) do
      prompt "test {input}"
      validate("must be positive") { |o| o[:value] > 0 }
    end

    adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"value": -1}')
    result = step.run("test", context: { adapter: adapter })

    expect(result.status).to eq(:validation_failed)
    expect(result.validation_errors).to eq(["must be positive"])
  end
end
