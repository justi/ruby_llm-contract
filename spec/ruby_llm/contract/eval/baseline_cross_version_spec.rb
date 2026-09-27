# frozen_string_literal: true

require "json"

# 1.0.0 must keep reading baseline files written by 0.10.x. Adopters gate CI on
# these, so a change in how the score is recomputed silently moves everyone's
# threshold, and a change in the skipped-case convention fires regressions that
# did not happen.
#
# The fixture is not hand-written: it was produced by ruby_llm-contract 0.10.6
# installed in an isolated GEM_HOME (on ruby_llm 1.14.1 and ruby_llm-schema
# 0.4.0), by calling that version's own save_baseline!. Regenerating it means
# installing 0.10.6 again, not editing the JSON.
RSpec.describe "reading a baseline written by 0.10.6" do
  before do
    RubyLLM::Contract.reset_configuration!
    RubyLLM::Contract.reset_eval_hosts!
  end

  let(:fixture) { File.expand_path("../../../fixtures/baseline_written_by_0.10.6.json", __dir__) }

  # 0.10.6 wrote only non-skipped cases into the file (it serialised
  # ReportStats#evaluated_results), so the file holds 3 cases and its own stored
  # score is 2/3.
  def case_result(name:, passed:, score:, details:, status: :ok, cost: 0.00123)
    RubyLLM::Contract::Eval::CaseResult.new(
      name: name, input: "in-#{name}", output: { v: name }, expected: { v: name },
      step_status: status, score: score, passed: passed, details: details, cost: cost
    )
  end

  def report(results)
    RubyLLM::Contract::Eval::Report.new(
      dataset_name: "returns_policy", step_name: "AnswerReturnsQuestion", results: results
    )
  end

  let(:unchanged) do
    [case_result(name: "billing", passed: true, score: 1.0, details: "passed"),
     case_result(name: "refunds", passed: false, score: 0.0, details: "tone mismatch"),
     case_result(name: "shipping", passed: true, score: 1.0, details: "passed")]
  end

  it "recomputes the same baseline score the old version stored in the file" do
    # If this drifts, every adopter's gate moves without anyone touching a gate.
    stored = JSON.parse(File.read(fixture))["score"]
    diff = report(unchanged).compare_with_baseline(path: fixture)

    expect(stored).to be_within(1e-9).of(2.0 / 3)
    expect(diff.baseline_score).to be_within(1e-9).of(stored)
  end

  it "reports no regression when the current run matches the old file" do
    diff = report(unchanged).compare_with_baseline(path: fixture)

    expect(diff.regressed?).to be false
    expect(diff.score_delta).to eq(0.0)
    expect(diff.new_cases).to be_empty
    expect(diff.removed_cases).to be_empty
  end

  it "names the case that actually regressed against the old file" do
    current = unchanged.dup
    current[2] = case_result(name: "shipping", passed: false, score: 0.0, details: "wrong tone")

    diff = report(current).compare_with_baseline(path: fixture)

    expect(diff.regressed?).to be true
    expect(diff.regressions.map { |r| r[:case] }).to eq(["shipping"])
  end

  # The crux: the old file has no skipped cases at all, but a current run can
  # produce one. It must not enter the denominator, or comparing against an
  # older baseline reports a regression nobody caused.
  it "does not turn a newly skipped case into a regression against the old file" do
    current = unchanged + [
      case_result(name: "live-only", passed: false, score: 0.0, status: :skipped, cost: nil,
                  details: RubyLLM::Contract::Eval::CaseResult.skipped_details("No adapter configured"))
    ]

    diff = report(current).compare_with_baseline(path: fixture)

    expect(diff.current_score).to be_within(1e-9).of(2.0 / 3)
    expect(diff.score_delta).to eq(0.0)
    expect(diff.regressed?).to be false
  end

  it "refuses a baseline from a different eval" do
    mismatched = RubyLLM::Contract::Eval::Report.new(
      dataset_name: "something_else", step_name: "AnswerReturnsQuestion", results: unchanged
    )

    expect { mismatched.compare_with_baseline(path: fixture) }
      .to raise_error(ArgumentError, /does not match/)
  end
end
