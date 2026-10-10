# frozen_string_literal: true

require "tmpdir"
require "ruby_llm/contract/rspec"

# A case that passed in the baseline and is skipped now (no adapter) was reported
# as REGRESSED while the score, which excludes skips, showed no change.
RSpec.describe RubyLLM::Contract::Eval::BaselineDiff, "with a formerly passing case now skipped" do
  let(:skipped_details) { RubyLLM::Contract::Eval::CaseResult.skipped_details("No adapter configured") }
  let(:baseline) do
    [{ name: "a", passed: true, score: 1.0, details: nil }, { name: "b", passed: true, score: 1.0, details: nil }]
  end
  let(:current) do
    [{ name: "a", passed: false, score: 0.0, details: skipped_details },
     { name: "b", passed: true, score: 1.0, details: nil }]
  end
  let(:diff) { described_class.new(baseline_cases: baseline, current_cases: current) }

  it "reports it as SKIPPED, not REGRESSED, and still fails the gate" do
    expect(diff.regressions).to be_empty
    expect(diff.skipped_passing_cases).to eq([{ case: "a", detail: skipped_details }])
    expect(diff.regressed?).to be(true)
    expect(diff.to_s).to include("SKIPPED    a: #{skipped_details}")
    expect(diff.to_s).not_to include("REGRESSED")
  end

  it "keeps a real failure as REGRESSED" do
    failed = [{ name: "a", passed: false, score: 0.0, details: "wrong label" }, current.last]
    diff = described_class.new(baseline_cases: baseline, current_cases: failed)

    expect(diff.regressions.map { |r| r[:case] }).to eq(["a"])
    expect(diff.skipped_passing_cases).to be_empty
  end

  it "shows the skip in the pass_eval without_regressions failure message" do
    step = Class.new(RubyLLM::Contract::Step::Base) do
      def self.name = "SkippedBaselineProbe"

      input_type String
      output_type Hash
      prompt { user "Classify: {input}" }
    end
    step.define_eval("smoke") { add_case "a", input: "test", expected: { label: "x" } }
    passing = { adapter: RubyLLM::Contract::Adapters::Test.new(response: '{"label":"x"}') }

    Dir.mktmpdir do |dir|
      Dir.chdir(dir) do
        RubyLLM::Contract.reset_configuration!
        step.run_eval("smoke", context: passing).save_baseline!

        matcher = pass_eval("smoke").without_regressions
        expect(matcher.matches?(step)).to be(false)
        expect(matcher.failure_message).to include("a: was PASS, now SKIPPED -- #{skipped_details}")
      end
    end
  end
end
