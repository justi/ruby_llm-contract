# frozen_string_literal: true

require "tmpdir"
# OptimizeRakeTask is not autoloaded - rake is a dev-only dependency.
require "ruby_llm/contract/rake_task"

# One producer writes a string, another parser reads it back. Neither side fails
# loudly when the format drifts - the consumer just stops matching and the caller
# gets a wrong answer instead of an error. These specs pin each round trip, so a
# change on one side turns a test red rather than silently changing a verdict.
RSpec.describe "producer/consumer string contracts" do
  before do
    RubyLLM::Contract.reset_configuration!
    RubyLLM::Contract.reset_eval_hosts!
  end

  # CaseExecutor writes `details: "skipped: <reason>"`; BaselineDiff#compute_score
  # excludes those cases from the denominator by matching that prefix. The two
  # sides of a baseline comparison are filtered differently: the baseline side
  # structurally (ReportStats#evaluated_results, by step_status), the current side
  # only by this string. Drift therefore lets a skipped case's 0.0 into the
  # current denominator and reports a regression that did not happen.
  describe "skipped-case details prefix" do
    def result(name:, passed:, step_status: :ok, details: nil)
      RubyLLM::Contract::Eval::CaseResult.new(
        name: name, input: "in", output: {}, expected: {}, step_status: step_status,
        score: passed ? 1.0 : 0.0, passed: passed, details: details, cost: 0.001
      )
    end

    def report(results)
      RubyLLM::Contract::Eval::Report.new(dataset_name: "smoke", results: results)
    end

    it "is written by CaseExecutor and read by BaselineDiff from one constant" do
      expect(RubyLLM::Contract::Eval::CaseResult::SKIPPED_DETAILS_PREFIX).to be_a(String)
      expect(RubyLLM::Contract::Eval::CaseResult.skipped_details("no adapter"))
        .to start_with(RubyLLM::Contract::Eval::CaseResult::SKIPPED_DETAILS_PREFIX)
    end

    it "does not report a regression when a case is skipped in the current run" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "baseline.json")

        report([result(name: "a", passed: true), result(name: "b", passed: true)])
          .save_baseline!(path: path)

        current = report([
                           result(name: "a", passed: true),
                           result(name: "b", passed: true),
                           result(name: "c", passed: false, step_status: :skipped,
                                  details: RubyLLM::Contract::Eval::CaseResult.skipped_details("no API key"))
                         ])

        diff = current.compare_with_baseline(path: path)

        # The skipped case must leave the denominator untouched on both sides.
        expect(diff.current_score).to eq(1.0)
        expect(diff.score_delta).to eq(0.0)
        expect(diff.regressed?).to be false
      end
    end

    it "still counts a genuinely failing case as a regression" do
      # Guards the test above from passing by excluding too much.
      Dir.mktmpdir do |dir|
        path = File.join(dir, "baseline.json")

        report([result(name: "a", passed: true), result(name: "b", passed: true)])
          .save_baseline!(path: path)

        current = report([result(name: "a", passed: true),
                          result(name: "b", passed: false, details: "wrong tone")])

        diff = current.compare_with_baseline(path: path)

        expect(diff.regressed?).to be true
        expect(diff.score_delta).to eq(-0.5)
      end
    end
  end

  # ModelComparison.candidate_label renders "<model> (effort: <x>)" into a table a
  # user may copy; RetryOptimizer#parse_label_to_config reads it back to generate a
  # retry_policy DSL. The loop closes entirely inside lib, with no error on drift:
  # a changed format makes the parser return the whole label as the model name, and
  # that name lands in generated code.
  describe "candidate label with reasoning effort" do
    let(:comparison) { RubyLLM::Contract::Eval::ModelComparison }
    let(:optimizer) { RubyLLM::Contract::Eval::RetryOptimizer.allocate }

    def round_trip(config)
      optimizer.send(:parse_label_to_config, comparison.candidate_label(config))
    end

    it "renders and parses through one shared format and pattern" do
      expect(comparison::EFFORT_LABEL_PATTERN).to be_a(Regexp)
      expect(comparison.candidate_label(model: "m", reasoning_effort: "high"))
        .to match(comparison::EFFORT_LABEL_PATTERN)
    end

    it "survives the round trip for a model with effort" do
      expect(round_trip(model: "gpt-5-mini", reasoning_effort: "low"))
        .to eq(model: "gpt-5-mini", reasoning_effort: "low")
    end

    it "survives the round trip for a model without effort" do
      expect(round_trip(model: "gpt-4.1-mini")).to eq(model: "gpt-4.1-mini")
    end

    it "normalises a symbol effort to a string - the DSL it generates uses strings" do
      # Pre-existing asymmetry, pinned so it cannot change silently.
      expect(round_trip(model: "gpt-5-mini", reasoning_effort: :low))
        .to eq(model: "gpt-5-mini", reasoning_effort: "low")
    end

    it "keeps a model name containing parentheses out of the effort slot" do
      expect(round_trip(model: "custom (beta)")).to eq(model: "custom (beta)")
    end
  end

  # RetryOptimizer prints a short label (`model@effort`) into a table; the user
  # copies it into CANDIDATES= and OptimizeRakeTask#parse_candidates splits it back
  # on "@". The loop runs through a human, so nothing fails when the two ends
  # disagree - the effort is silently dropped and a cheaper config gets optimised.
  describe "model@effort short label" do
    # short_candidate_label lives on the nested Result struct, not on the optimizer.
    let(:result) { RubyLLM::Contract::Eval::RetryOptimizer::Result.allocate }
    let(:rake_task) { RubyLLM::Contract::OptimizeRakeTask.allocate }

    it "renders and parses through one shared separator" do
      sep = RubyLLM::Contract::Eval::RetryOptimizer::EFFORT_SEPARATOR
      expect(sep).to be_a(String)
      expect(result.send(:short_candidate_label, "gpt-5-mini (effort: high)")).to include(sep)
    end

    it "carries the effort from the printed label back into a parsed config" do
      label = RubyLLM::Contract::Eval::ModelComparison.candidate_label(
        model: "gpt-5-mini", reasoning_effort: "high"
      )
      short = result.send(:short_candidate_label, label)

      parsed = rake_task.send(:parse_candidates, short)

      expect(parsed.length).to eq(1)
      expect(parsed.first[:reasoning_effort]).to eq("high")
    end

    it "parses a label without effort as a bare model" do
      short = result.send(:short_candidate_label, "gpt-4.1-mini")

      expect(rake_task.send(:parse_candidates, short).first).not_to have_key(:reasoning_effort)
    end
  end

  # Step::Base raises a plain Contract::Error when no adapter is configured, and
  # CaseExecutor decides skip-versus-raise by substring-matching that sentence. A
  # reworded message turns every eval case from "skipped, no adapter" into a hard
  # failure of the whole run.
  describe "missing-adapter message" do
    let(:executor) { RubyLLM::Contract::Eval::CaseExecutor.allocate }

    it "is produced and recognised through one constant" do
      expect(RubyLLM::Contract::Step::Base::NO_ADAPTER_MESSAGE).to be_a(String)
    end

    it "recognises the real error the step raises" do
      RubyLLM::Contract.reset_configuration!
      step = Class.new(RubyLLM::Contract::Step::Base) { prompt "x {input}" }

      error = begin
        step.run("hello")
        nil
      rescue RubyLLM::Contract::Error => e
        e
      end

      expect(error).not_to be_nil
      expect(executor.send(:missing_adapter?, error)).to be true
    end

    it "does not mistake an unrelated Contract::Error for a missing adapter" do
      other = RubyLLM::Contract::Error.new("Something else went wrong")

      expect(executor.send(:missing_adapter?, other)).to be false
    end
  end
end
