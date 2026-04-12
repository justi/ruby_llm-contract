# frozen_string_literal: true

RSpec.describe RubyLLM::Contract::Eval::ModelComparison do
  before { RubyLLM::Contract.reset_configuration! }

  def build_report(name, cases, step_name: nil)
    results = cases.map do |c|
      RubyLLM::Contract::Eval::CaseResult.new(
        name: c[:name] || "case", input: "test", output: c[:output] || {},
        expected: c[:expected] || {}, step_status: :ok,
        score: c[:passed] ? 1.0 : 0.0, passed: c[:passed],
        details: c[:details], cost: c[:cost] || 0.001,
        duration_ms: c[:duration_ms] || 100
      )
    end
    RubyLLM::Contract::Eval::Report.new(
      dataset_name: name, results: results, step_name: step_name
    )
  end

  describe ".candidate_label" do
    it "returns model name when no reasoning_effort" do
      expect(described_class.candidate_label({ model: "gpt-4.1-mini" })).to eq("gpt-4.1-mini")
    end

    it "includes reasoning_effort in label when present" do
      config = { model: "gpt-4.1-mini", reasoning_effort: "high" }
      expect(described_class.candidate_label(config)).to eq("gpt-4.1-mini (effort: high)")
    end

    it "does not include reasoning_effort when nil" do
      config = { model: "gpt-4.1-mini", reasoning_effort: nil }
      expect(described_class.candidate_label(config)).to eq("gpt-4.1-mini")
    end
  end

  describe "#score_for and #cost_for" do
    let(:report_a) { build_report("eval", [{ passed: true, cost: 0.01 }]) }
    let(:report_b) { build_report("eval", [{ passed: false, cost: 0.05 }]) }

    let(:comparison) do
      described_class.new(
        eval_name: "test_eval",
        reports: { "gpt-4.1-nano" => report_a, "gpt-4.1-mini" => report_b }
      )
    end

    it "accepts string key" do
      expect(comparison.score_for("gpt-4.1-nano")).to eq(1.0)
      expect(comparison.cost_for("gpt-4.1-mini")).to eq(0.05)
    end

    it "accepts config hash key" do
      expect(comparison.score_for({ model: "gpt-4.1-nano" })).to eq(1.0)
      expect(comparison.cost_for({ model: "gpt-4.1-mini" })).to eq(0.05)
    end

    it "returns nil for unknown candidate" do
      expect(comparison.score_for("nonexistent")).to be_nil
      expect(comparison.cost_for("nonexistent")).to be_nil
    end
  end

  describe "#configs accessor" do
    it "returns correct mapping when provided explicitly" do
      report = build_report("eval", [{ passed: true }])
      configs = {
        "gpt-4.1-nano" => { model: "gpt-4.1-nano" },
        "gpt-4.1-mini (effort: high)" => { model: "gpt-4.1-mini", reasoning_effort: "high" }
      }

      comparison = described_class.new(
        eval_name: "test",
        reports: { "gpt-4.1-nano" => report, "gpt-4.1-mini (effort: high)" => report },
        configs: configs
      )

      expect(comparison.configs["gpt-4.1-nano"]).to eq({ model: "gpt-4.1-nano" })
      expect(comparison.configs["gpt-4.1-mini (effort: high)"]).to eq({ model: "gpt-4.1-mini", reasoning_effort: "high" })
    end

    it "builds default configs from report keys when configs: not provided" do
      report = build_report("eval", [{ passed: true }])
      comparison = described_class.new(
        eval_name: "test",
        reports: { "gpt-4.1-nano" => report }
      )

      expect(comparison.configs).to eq({ "gpt-4.1-nano" => { model: "gpt-4.1-nano" } })
    end
  end

  describe "#to_h" do
    it "includes pass_rate_ratio" do
      report = build_report("eval", [
        { name: "a", passed: true, cost: 0.01 },
        { name: "b", passed: false, cost: 0.02 }
      ])

      comparison = described_class.new(
        eval_name: "test",
        reports: { "gpt-4.1-mini" => report }
      )

      h = comparison.to_h
      expect(h["gpt-4.1-mini"]).to eq({
        score: 0.5,
        total_cost: 0.03,
        avg_latency_ms: 100.0,
        pass_rate: "1/2",
        pass_rate_ratio: 0.5,
        passed: false
      })
    end
  end

  describe "backward compatibility" do
    it "creating without configs: still works" do
      report = build_report("eval", [{ passed: true }])
      comparison = described_class.new(eval_name: "test", reports: { "gpt-4.1-nano" => report })

      expect(comparison.models).to eq(["gpt-4.1-nano"])
      expect(comparison.score_for("gpt-4.1-nano")).to eq(1.0)
      expect(comparison.configs).to be_frozen
    end
  end
end
