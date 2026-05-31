# frozen_string_literal: true

require "spec_helper"

# Characterization tests pinning CostCalculator.find_model behaviour
# before exposing it as a public method (Batch 2 / B2-T3 / TODO).
RSpec.describe RubyLLM::Contract::CostCalculator do
  describe ".find_model" do
    after { described_class.reset_custom_models! }

    it "returns nil for an unknown model name" do
      expect(described_class.find_model("nonexistent-xyz-9999")).to be_nil
    end

    it "returns nil when model_name is nil" do
      expect(described_class.find_model(nil)).to be_nil
    end

    it "returns the registered model for a custom-registered name" do
      described_class.register_model("custom-test-model",
                                     input_per_1m: 0.5, output_per_1m: 1.5)

      info = described_class.find_model("custom-test-model")

      # Independently specified literals: pin the actual pricing values rather
      # than just verifying that price-reading methods *exist* (the prior
      # `respond_to(...)` form passed for any object with those method names —
      # e.g. a struct holding nil/0 would have satisfied it).
      expect(info.input_price_per_million).to eq(0.5)
      expect(info.output_price_per_million).to eq(1.5)
    end

    it "prefers custom-registered model over RubyLLM registry on name collision" do
      # If a name shadows a real RubyLLM model, the custom override wins.
      described_class.register_model("gpt-4.1-nano",
                                     input_per_1m: 99.0, output_per_1m: 99.0)

      info = described_class.find_model("gpt-4.1-nano")

      expect(info.input_price_per_million).to eq(99.0)
    end
  end

  describe ".calculate" do
    it "uses find_model internally and returns nil when model is unknown" do
      expect(
        described_class.calculate(
          model_name: "nonexistent-xyz-9999",
          usage: { input_tokens: 100, output_tokens: 50 }
        )
      ).to be_nil
    end
  end
end
