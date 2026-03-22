# frozen_string_literal: true

RSpec.describe "Eval::Report display" do
  def build_case_result(name:, score:, passed:, details: nil)
    RubyLLM::Contract::Eval::CaseResult.new(
      name: name,
      input: "test",
      output: {},
      expected: nil,
      step_status: :ok,
      score: score,
      passed: passed,
      details: details
    )
  end

  let(:passing_report) do
    RubyLLM::Contract::Eval::Report.new(
      dataset_name: "smoke",
      results: [
        build_case_result(name: "has intent", score: 1.0, passed: true, details: "all keys match"),
        build_case_result(name: "has confidence", score: 1.0, passed: true, details: "passed")
      ]
    )
  end

  let(:mixed_report) do
    RubyLLM::Contract::Eval::Report.new(
      dataset_name: "hard",
      results: [
        build_case_result(name: "locale is Polish", score: 1.0, passed: true, details: "all keys match"),
        build_case_result(name: "who in Polish", score: 1.0, passed: true, details: "passed"),
        build_case_result(name: "min 2 groups", score: 0.0, passed: false, details: "not passed"),
        build_case_result(name: "use_cases specific", score: 0.0, passed: false, details: "expected pattern not found")
      ]
    )
  end

  describe "#to_s" do
    it "shows 'checks passed' when all pass" do
      str = passing_report.to_s
      expect(str).to include("smoke: 2/2 checks passed")
      expect(str).not_to include("FAIL")
    end

    it "shows 'checks passed' + failed cases when some fail" do
      str = mixed_report.to_s
      expect(str).to include("hard: 2/4 checks passed")
      expect(str).to include("FAIL")
      expect(str).to include("min 2 groups")
      expect(str).to include("use_cases specific")
    end

    it "does not show passing cases in failure output" do
      str = mixed_report.to_s
      expect(str).not_to include("locale is Polish")
      expect(str).not_to include("who in Polish")
    end

    it "does not include score decimal" do
      str = mixed_report.to_s
      expect(str).not_to include("score=")
    end
  end

  describe "#summary" do
    it "uses 'checks passed' wording" do
      expect(passing_report.summary).to eq("smoke: 2/2 checks passed")
      expect(mixed_report.summary).to eq("hard: 2/4 checks passed")
    end
  end

  describe "#print_summary" do
    it "shows all cases with PASS/FAIL" do
      output = StringIO.new
      mixed_report.print_summary(output)
      str = output.string

      expect(str).to include("PASS")
      expect(str).to include("FAIL")
      expect(str).to include("locale is Polish")
      expect(str).to include("min 2 groups")
    end

    it "hides generic details like 'not passed'" do
      output = StringIO.new
      mixed_report.print_summary(output)
      str = output.string

      expect(str).not_to include("not passed")
    end

    it "shows useful details" do
      report = RubyLLM::Contract::Eval::Report.new(
        dataset_name: "test",
        results: [
          build_case_result(name: "check", score: 0.0, passed: false, details: "expected 3 items, got 1")
        ]
      )
      output = StringIO.new
      report.print_summary(output)
      expect(output.string).to include("expected 3 items, got 1")
    end

    it "header uses 'checks passed'" do
      output = StringIO.new
      mixed_report.print_summary(output)
      expect(output.string).to include("2/4 checks passed")
    end
  end
end
