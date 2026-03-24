# frozen_string_literal: true

require "ruby_llm/contract/rspec"
require "ruby_llm/contract/minitest"

class Round4StepA < RubyLLM::Contract::Step::Base
  prompt { user "{input}" }
  output_type RubyLLM::Contract::Types::Hash
  contract { parse :json }
end

RSpec.describe "Audit round 4 bugfixes" do
  before do
    RubyLLM::Contract.reset_configuration!
    RubyLLM::Contract::CostCalculator.reset_custom_models!
  end

  # Bug 14: Float::NAN bypasses register_model
  describe "Bug 14: register_model rejects NaN" do
    it "rejects Float::NAN for input_per_1m" do
      expect {
        RubyLLM::Contract::CostCalculator.register_model("ft:nan",
          input_per_1m: Float::NAN, output_per_1m: 1.0)
      }.to raise_error(ArgumentError, /finite non-negative/)
    end

    it "rejects Float::INFINITY" do
      expect {
        RubyLLM::Contract::CostCalculator.register_model("ft:inf",
          input_per_1m: Float::INFINITY, output_per_1m: 1.0)
      }.to raise_error(ArgumentError, /finite non-negative/)
    end
  end

  # Bug 15: non-block stub_all_steps auto-cleanup in RSpec
  describe "Bug 15: non-block stub_all_steps cleaned up by around hook" do
    it "first example stubs all steps" do
      stub_all_steps(response: '{"from":"first"}')
      result = Round4StepA.run("x")
      expect(result.parsed_output).to eq({ from: "first" })
    end

    it "second example does not see first example's stub" do
      fallback = RubyLLM::Contract::Adapters::Test.new(response: '{"from":"fallback"}')
      RubyLLM::Contract.configuration.default_adapter = fallback

      result = Round4StepA.run("x")
      expect(result.parsed_output).to eq({ from: "fallback" })
    end
  end

  # Bug 16: estimate_cost uses step DSL model
  describe "Bug 16: estimate_cost falls back to step DSL model" do
    it "uses step-level model when no model arg given" do
      RubyLLM::Contract::CostCalculator.register_model("ft:dsl-model",
        input_per_1m: 1.0, output_per_1m: 2.0)

      step = Class.new(RubyLLM::Contract::Step::Base) do
        prompt "Test {input}"
        model "ft:dsl-model"
      end

      estimate = step.estimate_cost(input: "hello")
      expect(estimate).not_to be_nil
      expect(estimate[:model]).to eq("ft:dsl-model")
    end
  end

  # Bug 17: RSpec stub_steps normalizes string keys
  describe "Bug 17: RSpec stub_steps handles string-keyed options" do
    it "works with string keys" do
      fallback = RubyLLM::Contract::Adapters::Test.new(response: '{"from":"fallback"}')
      RubyLLM::Contract.configuration.default_adapter = fallback

      stub_steps(
        Round4StepA => { "response" => '{"from":"string_key"}' }
      ) do
        result = Round4StepA.run("x")
        expect(result.parsed_output).to eq({ from: "string_key" })
      end
    end
  end

  # Bug 18: DSL :default resets inherited values
  describe "Bug 18: DSL :default resets inherited settings" do
    it "child resets inherited model with model(:default)" do
      parent = Class.new(RubyLLM::Contract::Step::Base) do
        prompt { user "{input}" }
        model "ft:parent"
      end

      child = Class.new(parent) do
        model :default
      end

      expect(parent.model).to eq("ft:parent")
      expect(child.model).to be_nil
    end

    it "child resets inherited temperature with temperature(:default)" do
      parent = Class.new(RubyLLM::Contract::Step::Base) do
        prompt { user "{input}" }
        temperature 0.3
      end

      child = Class.new(parent) do
        temperature :default
      end

      expect(parent.temperature).to eq(0.3)
      expect(child.temperature).to be_nil
    end

    it "child resets inherited max_cost with max_cost(:default)" do
      parent = Class.new(RubyLLM::Contract::Step::Base) do
        prompt { user "{input}" }
        max_cost 0.05
      end

      child = Class.new(parent) do
        max_cost :default
      end

      expect(parent.max_cost).to eq(0.05)
      expect(child.max_cost).to be_nil
    end
  end
end
