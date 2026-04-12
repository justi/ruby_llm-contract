# frozen_string_literal: true

RSpec.describe RubyLLM::Contract::Eval::ReportStats do
  def build_case_result(passed:, score: nil, cost: 0.001, duration_ms: 100)
    RubyLLM::Contract::Eval::CaseResult.new(
      name: "case_#{rand(10_000)}",
      input: "test",
      output: {},
      expected: {},
      step_status: :ok,
      score: score || (passed ? 1.0 : 0.0),
      passed: passed,
      cost: cost,
      duration_ms: duration_ms
    )
  end

  describe "#pass_rate_ratio" do
    it "returns 0.0 for empty results" do
      stats = described_class.new(results: [])
      expect(stats.pass_rate_ratio).to eq(0.0)
    end

    it "returns 1.0 when all pass" do
      results = [build_case_result(passed: true), build_case_result(passed: true)]
      stats = described_class.new(results: results)
      expect(stats.pass_rate_ratio).to eq(1.0)
    end

    it "returns correct float for partial pass (3/5 = 0.6)" do
      results = [
        build_case_result(passed: true),
        build_case_result(passed: true),
        build_case_result(passed: true),
        build_case_result(passed: false),
        build_case_result(passed: false)
      ]
      stats = described_class.new(results: results)
      expect(stats.pass_rate_ratio).to eq(0.6)
    end

    it "returns 0.0 when all fail" do
      results = [build_case_result(passed: false), build_case_result(passed: false)]
      stats = described_class.new(results: results)
      expect(stats.pass_rate_ratio).to eq(0.0)
    end

    it "excludes skipped results from the ratio" do
      skipped = RubyLLM::Contract::Eval::CaseResult.new(
        name: "skipped", input: "test", output: {}, expected: {},
        step_status: :skipped, score: 0.0, passed: false
      )
      results = [build_case_result(passed: true), skipped]
      stats = described_class.new(results: results)
      expect(stats.pass_rate_ratio).to eq(1.0)
    end
  end
end
