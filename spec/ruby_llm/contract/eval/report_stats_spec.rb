# frozen_string_literal: true

RSpec.describe RubyLLM::Contract::Eval::ReportStats do
  def build_case(passed:, score: nil, cost: 0.001, duration_ms: 100, step_status: :ok, name: nil)
    @case_counter ||= 0
    @case_counter += 1
    RubyLLM::Contract::Eval::CaseResult.new(
      name: name || "case_#{@case_counter}",
      input: "test",
      output: {},
      expected: {},
      step_status: step_status,
      score: score || (passed ? 1.0 : 0.0),
      passed: passed,
      cost: cost,
      duration_ms: duration_ms
    )
  end

  describe "#score" do
    it "returns 0.0 for empty results" do
      expect(described_class.new(results: []).score).to eq(0.0)
    end

    it "returns 1.0 when all cases score 1.0" do
      results = [build_case(passed: true, score: 1.0), build_case(passed: true, score: 1.0)]
      expect(described_class.new(results: results).score).to eq(1.0)
    end

    it "averages scores across evaluated results" do
      results = [build_case(passed: true, score: 1.0), build_case(passed: false, score: 0.0)]
      expect(described_class.new(results: results).score).to eq(0.5)
    end

    it "excludes skipped results from score" do
      results = [
        build_case(passed: true, score: 1.0),
        build_case(passed: false, score: 0.0, step_status: :skipped)
      ]
      expect(described_class.new(results: results).score).to eq(1.0)
    end
  end

  describe "#total_cost" do
    it "sums costs across all results including skipped" do
      results = [build_case(passed: true, cost: 0.01), build_case(passed: true, cost: 0.02)]
      expect(described_class.new(results: results).total_cost).to eq(0.03)
    end

    it "treats nil cost as 0.0" do
      results = [build_case(passed: true, cost: 0.01), build_case(passed: true, cost: nil)]
      expect(described_class.new(results: results).total_cost).to eq(0.01)
    end

    it "returns 0.0 for empty results" do
      expect(described_class.new(results: []).total_cost).to eq(0.0)
    end
  end

  describe "#avg_latency_ms" do
    it "averages latencies excluding nil" do
      results = [build_case(passed: true, duration_ms: 100), build_case(passed: true, duration_ms: 200)]
      expect(described_class.new(results: results).avg_latency_ms).to eq(150.0)
    end

    it "returns nil when all latencies are nil" do
      results = [build_case(passed: true, duration_ms: nil)]
      expect(described_class.new(results: results).avg_latency_ms).to be_nil
    end

    it "excludes nil latencies from count" do
      results = [build_case(passed: true, duration_ms: 300), build_case(passed: true, duration_ms: nil)]
      expect(described_class.new(results: results).avg_latency_ms).to eq(300.0)
    end
  end

  describe "#passed?" do
    it "returns false for empty results" do
      expect(described_class.new(results: []).passed?).to be false
    end

    it "returns true when all evaluated results pass" do
      results = [build_case(passed: true), build_case(passed: true)]
      expect(described_class.new(results: results).passed?).to be true
    end

    it "returns false when any evaluated result fails" do
      results = [build_case(passed: true), build_case(passed: false)]
      expect(described_class.new(results: results).passed?).to be false
    end
  end

  describe "#pass_rate" do
    it "returns string format passed/total" do
      results = [build_case(passed: true), build_case(passed: false), build_case(passed: true)]
      expect(described_class.new(results: results).pass_rate).to eq("2/3")
    end
  end

  describe "#pass_rate_ratio" do
    it "returns 0.0 for empty results" do
      expect(described_class.new(results: []).pass_rate_ratio).to eq(0.0)
    end

    it "returns 1.0 when all pass" do
      results = [build_case(passed: true), build_case(passed: true)]
      expect(described_class.new(results: results).pass_rate_ratio).to eq(1.0)
    end

    it "returns correct float for partial pass (3/5 = 0.6)" do
      results = Array.new(3) { build_case(passed: true) } + Array.new(2) { build_case(passed: false) }
      expect(described_class.new(results: results).pass_rate_ratio).to eq(0.6)
    end

    it "returns 0.0 when all fail" do
      results = [build_case(passed: false), build_case(passed: false)]
      expect(described_class.new(results: results).pass_rate_ratio).to eq(0.0)
    end

    it "excludes skipped results from the ratio" do
      results = [build_case(passed: true), build_case(passed: false, step_status: :skipped)]
      expect(described_class.new(results: results).pass_rate_ratio).to eq(1.0)
    end
  end
end
