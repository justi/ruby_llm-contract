# frozen_string_literal: true

RSpec.describe "F7: max_cost fail closed + CostCalculator.register_model" do
  before do
    RubyLLM::Contract.reset_configuration!
    RubyLLM::Contract::CostCalculator.reset_custom_models!
  end

  after do
    RubyLLM::Contract::CostCalculator.reset_custom_models!
  end

  let(:test_adapter) { RubyLLM::Contract::Adapters::Test.new(response: '{"v": 1}') }

  describe "unknown model with max_cost (fail closed by default)" do
    it "refuses the call with :limit_exceeded and clear error message" do
      step = Class.new(RubyLLM::Contract::Step::Base) do
        prompt "Analyze {input}"
        max_cost 0.05
      end

      result = step.run("hello", context: { adapter: test_adapter, model: "ft:custom-unknown-model" })

      expect(result.status).to eq(:limit_exceeded)
      expect(result.validation_errors.first).to include("no pricing data")
      expect(result.validation_errors.first).to include("ft:custom-unknown-model")
      expect(result.validation_errors.first).to include("CostCalculator.register_model")
    end

    it "does not call the adapter when pricing is unknown" do
      adapter_called = false
      spy_adapter = Class.new(RubyLLM::Contract::Adapters::Base) do
        define_method(:call) do |messages:, **_opts|
          adapter_called = true
          RubyLLM::Contract::Adapters::Response.new(
            content: '{"v":1}', usage: { input_tokens: 0, output_tokens: 0 }
          )
        end
      end.new

      step = Class.new(RubyLLM::Contract::Step::Base) do
        prompt "Analyze {input}"
        max_cost 0.05
      end

      step.run("hello", context: { adapter: spy_adapter, model: "ft:custom-unknown-model" })

      expect(adapter_called).to be false
    end
  end

  describe "on_unknown_pricing: :warn (opt-in to old behavior)" do
    it "warns but proceeds when model has no pricing data" do
      step = Class.new(RubyLLM::Contract::Step::Base) do
        prompt "Analyze {input}"
        max_cost 0.05, on_unknown_pricing: :warn
      end

      result = step.run("hello", context: { adapter: test_adapter, model: "ft:custom-unknown-model" })

      expect(result.status).to eq(:ok)
    end

    it "emits a warning about missing pricing data" do
      step = Class.new(RubyLLM::Contract::Step::Base) do
        prompt "Analyze {input}"
        max_cost 0.05, on_unknown_pricing: :warn
      end

      # warn is dispatched on the Runner instance (private Kernel method)
      expect_any_instance_of(RubyLLM::Contract::Step::Runner).to receive(:warn) # rubocop:disable RSpec/AnyInstance
        .with(/no pricing data/)
      step.run("hello", context: { adapter: test_adapter, model: "ft:custom-unknown-model" })
    end
  end

  describe "CostCalculator.register_model" do
    it "makes an unknown model known for cost checks" do
      RubyLLM::Contract::CostCalculator.register_model(
        "ft:gpt-4o-custom",
        input_per_1m: 3.0,
        output_per_1m: 6.0
      )

      # With registered pricing, cost calculation works
      cost = RubyLLM::Contract::CostCalculator.calculate(
        model_name: "ft:gpt-4o-custom",
        usage: { input_tokens: 1000, output_tokens: 500 }
      )

      # 1000 * 3.0 / 1_000_000 + 500 * 6.0 / 1_000_000 = 0.003 + 0.003 = 0.006
      expect(cost).to eq(0.006)
    end

    it "allows max_cost check to work for registered model" do
      RubyLLM::Contract::CostCalculator.register_model(
        "ft:gpt-4o-custom",
        input_per_1m: 3.0,
        output_per_1m: 6.0
      )

      step = Class.new(RubyLLM::Contract::Step::Base) do
        prompt "Analyze {input}"
        max_cost 1.00 # generous limit
      end

      result = step.run("hello", context: { adapter: test_adapter, model: "ft:gpt-4o-custom" })

      expect(result.status).to eq(:ok)
    end

    it "refuses when registered model cost exceeds max_cost" do
      RubyLLM::Contract::CostCalculator.register_model(
        "ft:gpt-4o-expensive",
        input_per_1m: 500.0,
        output_per_1m: 1000.0
      )

      long_text = "x" * 40_000 # ~10,000 tokens

      step = Class.new(RubyLLM::Contract::Step::Base) do
        prompt "Analyze: {input}"
        max_cost 0.001 # very low
      end

      result = step.run(long_text, context: { adapter: test_adapter, model: "ft:gpt-4o-expensive" })

      expect(result.status).to eq(:limit_exceeded)
      expect(result.validation_errors.first).to include("Cost limit exceeded")
    end

    it "can be unregistered" do
      RubyLLM::Contract::CostCalculator.register_model(
        "ft:temp-model", input_per_1m: 1.0, output_per_1m: 2.0
      )
      RubyLLM::Contract::CostCalculator.unregister_model("ft:temp-model")

      cost = RubyLLM::Contract::CostCalculator.calculate(
        model_name: "ft:temp-model",
        usage: { input_tokens: 100, output_tokens: 50 }
      )

      expect(cost).to be_nil
    end
  end

  describe "known model with max_cost (no regression)" do
    it "works as before when model has pricing and cost is within limit" do
      step = Class.new(RubyLLM::Contract::Step::Base) do
        prompt "Hi {input}"
        max_cost 1.00
      end

      result = step.run("test", context: { adapter: test_adapter, model: "gpt-4.1-mini" })

      expect(result.status).to eq(:ok)
    end

    it "refuses when known model cost exceeds limit" do
      long_text = "x" * 40_000 # ~10,000 tokens

      step = Class.new(RubyLLM::Contract::Step::Base) do
        prompt "Analyze: {input}"
        max_cost 0.0001 # very low
      end

      result = step.run(long_text, context: { adapter: test_adapter, model: "gpt-4.1-mini" })

      expect(result.status).to eq(:limit_exceeded)
      expect(result.validation_errors.first).to include("Cost limit exceeded")
    end
  end

  describe "DSL validation" do
    it "rejects invalid on_unknown_pricing values" do
      expect {
        Class.new(RubyLLM::Contract::Step::Base) do
          prompt "test {input}"
          max_cost 0.05, on_unknown_pricing: :ignore
        end
      }.to raise_error(ArgumentError, /on_unknown_pricing must be :refuse or :warn/)
    end

    it "defaults on_unknown_pricing to :refuse" do
      step = Class.new(RubyLLM::Contract::Step::Base) do
        prompt "test {input}"
        max_cost 0.05
      end

      expect(step.on_unknown_pricing).to eq(:refuse)
    end
  end
end
