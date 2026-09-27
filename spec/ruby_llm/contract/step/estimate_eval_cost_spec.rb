# frozen_string_literal: true

# getting_started.md promises `estimate_eval_cost` "silently treats unknown-pricing
# cases as $0.00 and sums the rest - it does NOT fail closed the way max_cost
# does. Treat its output as a floor." Two distinct misses have to floor: model
# absent from the registry, and model present with unreadable pricing.
RSpec.describe "Step::Base.estimate_eval_cost unknown-pricing contract" do
  let(:step) do
    Class.new(RubyLLM::Contract::Step::Base) do
      prompt "Summarize {input}"
      define_eval("regression") do
        add_case "one", input: "first input", expected: { ok: true }
        add_case "two", input: "second input", expected: { ok: true }
      end
    end
  end

  context "when the model is in the registry but its pricing is unreadable" do
    before do
      # Stubbing the lookup rather than naming a real unpriced model keeps this
      # version-independent: the ruby_llm 2.x CI arm tracks the newest registry.
      allow(RubyLLM::Contract::CostCalculator).to receive(:find_model).and_return(Object.new)
    end

    it "returns 0.0 for that model" do
      expect(step.estimate_eval_cost("regression", models: ["some-model"])).to eq("some-model" => 0.0)
    end
  end

  context "when pricing is available" do
    before do
      RubyLLM::Contract::CostCalculator.reset_custom_models!
      RubyLLM::Contract::CostCalculator.register_model("ft:priced", input_per_1m: 10.0, output_per_1m: 20.0)
    end

    after { RubyLLM::Contract::CostCalculator.reset_custom_models! }

    it "sums both cases at the registered price, not just the first" do
      # Arithmetic spelled out so the literal is checkable without running the
      # code: each case estimates 6 input + 256 output tokens, so
      # 6 * 10.0/1e6 + 256 * 20.0/1e6 = 0.00518, and two cases give 0.01036.
      # `be > 0` was blind to both a dropped case and a wrong divisor.
      one = step.estimate_cost(input: "first input", model: "ft:priced")[:estimated_cost]
      two = step.estimate_cost(input: "second input", model: "ft:priced")[:estimated_cost]

      total = step.estimate_eval_cost("regression", models: ["ft:priced"])["ft:priced"]

      expect(total).to eq((one + two).round(6))
      expect(total).to be_within(1e-9).of(0.01036)
    end
  end

  context "when some models are priced and others are not" do
    before do
      RubyLLM::Contract::CostCalculator.reset_custom_models!
      RubyLLM::Contract::CostCalculator.register_model("ft:priced", input_per_1m: 10.0, output_per_1m: 20.0)
    end

    after { RubyLLM::Contract::CostCalculator.reset_custom_models! }

    it "still sums the priced one - the floor applies per model, not globally" do
      result = step.estimate_eval_cost("regression", models: ["ft:priced", "ft:never-registered"])

      expect(result["ft:priced"]).to be > 0
      expect(result["ft:never-registered"]).to eq(0.0)
    end
  end
end
