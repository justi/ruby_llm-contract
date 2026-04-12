# frozen_string_literal: true

RSpec.describe RubyLLM::Contract::Eval::Recommendation do
  describe "frozen after creation" do
    it "is frozen" do
      rec = described_class.new(
        best: { model: "gpt-4.1-mini" },
        retry_chain: [{ model: "gpt-4.1-mini" }],
        score: 0.95,
        cost_per_call: 0.001,
        rationale: ["gpt-4.1-mini, score 0.95"],
        current_config: nil,
        savings: {},
        warnings: []
      )

      expect(rec).to be_frozen
      expect(rec.best).to be_frozen
      expect(rec.retry_chain).to be_frozen
      expect(rec.rationale).to be_frozen
      expect(rec.savings).to be_frozen
      expect(rec.warnings).to be_frozen
    end

    it "is deeply frozen — nested hashes cannot be mutated" do
      rec = described_class.new(
        best: { model: "gpt-4.1-mini" },
        retry_chain: [{ model: "gpt-4.1-mini" }],
        score: 0.95,
        cost_per_call: 0.001,
        rationale: ["line one"],
        current_config: { model: "gpt-4.1" },
        savings: { per_call: 0.01 },
        warnings: ["warning"]
      )

      expect { rec.retry_chain.first[:model] = "hacked" }.to raise_error(FrozenError)
      expect { rec.savings[:per_call] = 999 }.to raise_error(FrozenError)
      expect { rec.best[:model] = "hacked" }.to raise_error(FrozenError)
    end
  end

  describe "attribute access" do
    subject(:rec) do
      described_class.new(
        best: { model: "gpt-4.1-mini" },
        retry_chain: [{ model: "gpt-4.1-nano" }, { model: "gpt-4.1-mini" }],
        score: 0.98,
        cost_per_call: 0.002,
        rationale: ["gpt-4.1-nano cheapest", "gpt-4.1-mini best"],
        current_config: { model: "gpt-4.1" },
        savings: { per_call: 0.048 },
        warnings: ["gpt-4.1-nano: unknown pricing"]
      )
    end

    it "exposes all attributes" do
      expect(rec.best).to eq({ model: "gpt-4.1-mini" })
      expect(rec.retry_chain.length).to eq(2)
      expect(rec.score).to eq(0.98)
      expect(rec.cost_per_call).to eq(0.002)
      expect(rec.rationale).to eq(["gpt-4.1-nano cheapest", "gpt-4.1-mini best"])
      expect(rec.current_config).to eq({ model: "gpt-4.1" })
      expect(rec.savings).to eq({ per_call: 0.048 })
      expect(rec.warnings).to eq(["gpt-4.1-nano: unknown pricing"])
    end
  end

  describe "#to_dsl" do
    it "generates shorthand for model-only chains" do
      rec = described_class.new(
        best: { model: "gpt-4.1-mini" },
        retry_chain: [{ model: "gpt-4.1-nano" }, { model: "gpt-4.1-mini" }],
        score: 0.95,
        cost_per_call: 0.001,
        rationale: [],
        current_config: nil,
        savings: {},
        warnings: []
      )

      expect(rec.to_dsl).to eq("retry_policy models: %w[gpt-4.1-nano gpt-4.1-mini]")
    end

    it "generates block form when reasoning_effort present" do
      rec = described_class.new(
        best: { model: "gpt-4.1-mini", reasoning_effort: "high" },
        retry_chain: [
          { model: "gpt-4.1-nano" },
          { model: "gpt-4.1-mini", reasoning_effort: "high" }
        ],
        score: 0.95,
        cost_per_call: 0.001,
        rationale: [],
        current_config: nil,
        savings: {},
        warnings: []
      )

      dsl = rec.to_dsl
      expect(dsl).to include("retry_policy do")
      expect(dsl).to include("escalate(")
      expect(dsl).to include("reasoning_effort")
    end

    it "returns comment when chain is empty" do
      rec = described_class.new(
        best: nil,
        retry_chain: [],
        score: 0.0,
        cost_per_call: 0.0,
        rationale: [],
        current_config: nil,
        savings: {},
        warnings: []
      )

      expect(rec.to_dsl).to eq("# No recommendation — no candidate met the minimum score")
    end

    it "generates model DSL for single model chain" do
      rec = described_class.new(
        best: { model: "gpt-4.1-mini" },
        retry_chain: [{ model: "gpt-4.1-mini" }],
        score: 1.0,
        cost_per_call: 0.01,
        rationale: [],
        current_config: nil,
        savings: {},
        warnings: []
      )

      expect(rec.to_dsl).to eq('model "gpt-4.1-mini"')
    end
  end
end
