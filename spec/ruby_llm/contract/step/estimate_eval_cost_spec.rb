# frozen_string_literal: true

# Pins the documented contract of `estimate_eval_cost`, which had no spec at all.
# docs/guide/getting_started.md:194 promises it "silently treats unknown-pricing
# cases as $0.00 and sums the rest - it does NOT fail closed the way max_cost
# does. Treat its output as a floor."
#
# The 1.0.0 port broke that: CostCalculator#calculate gained a second meaning for
# nil (model found, but pricing unreadable), and this summation only guarded the
# first (model not found at all), so it raised TypeError instead of flooring.
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

    it "floors the unknown-pricing cases at $0.00 instead of raising" do
      expect { step.estimate_eval_cost("regression", models: ["some-model"]) }.not_to raise_error
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

    it "sums a positive cost across the dataset" do
      total = step.estimate_eval_cost("regression", models: ["ft:priced"])["ft:priced"]

      expect(total).to be_a(Float)
      expect(total).to be > 0
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
