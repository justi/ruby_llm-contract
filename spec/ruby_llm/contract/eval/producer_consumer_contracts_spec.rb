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

    it "writes the exact prefix that older baseline.json files already contain" do
      # This literal is persisted in every saved baseline, so changing it silently
      # reclassifies previously-skipped cases in files already on disk.
      expect(RubyLLM::Contract::Eval::CaseResult.skipped_details("no adapter"))
        .to eq("skipped: no adapter")
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

  # ModelComparison renders these labels and parses them back to rebuild candidate
  # configs. Drift raises nothing: the parser would return the whole label as the
  # model name.
  describe "candidate label with reasoning effort" do
    let(:label) { RubyLLM::Contract::Eval::CandidateLabel }
    def round_trip(config)
      label.parse(label.render(config))
    end

    it "derives the parser pattern from the literal the renderer emits" do
      # Not just "both agree today": the pattern is BUILT from EFFORT_LABEL_OPEN,
      # so a change to the rendered format cannot leave the parser behind. Three
      # places used to hardcode " (effort: " independently.
      # Behavioural, not structural: the pattern must match what the renderer
      # emits for an effort it has never seen before.
      expect(label.render(model: "m", reasoning_effort: "zzz")).to match(label::PATTERN)
    end

    it "survives the round trip for a model with effort" do
      expect(round_trip(model: "gpt-5-mini", reasoning_effort: "low"))
        .to eq(model: "gpt-5-mini", reasoning_effort: "low")
    end

    it "survives the round trip for a model without effort" do
      expect(round_trip(model: "gpt-4.1-mini")).to eq(model: "gpt-4.1-mini")
    end

    it "keeps a model name containing parentheses out of the effort slot" do
      expect(round_trip(model: "custom (beta)")).to eq(model: "custom (beta)")
    end
  end

  # `model@effort` is documented CANDIDATES= shorthand, and the optimizer's table
  # renders the same notation in its headers. If they diverge, the table prints a
  # syntax the CLI would reject. No round trip is tested: the short label is
  # display only and nothing feeds it back into the parser.
  describe "model@effort CLI shorthand" do
    let(:result) { RubyLLM::Contract::Eval::RetryOptimizer::Result.allocate }
    let(:rake_task) { RubyLLM::Contract::OptimizeRakeTask.allocate }
    let(:separator) { RubyLLM::Contract::Eval::RetryOptimizer::EFFORT_SEPARATOR }

    it "parses the documented shorthand into a model plus effort" do
      expect(rake_task.send(:parse_candidates, "gpt-4.1-mini#{separator}low"))
        .to eq([{ model: "gpt-4.1-mini", reasoning_effort: "low" }])
    end

    it "parses a plain model name as a bare model" do
      expect(rake_task.send(:parse_candidates, "gpt-4.1-mini"))
        .to eq([{ model: "gpt-4.1-mini" }])
    end

    it "keeps a parenthesised model name intact in the header" do
      label = RubyLLM::Contract::Eval::ModelComparison.candidate_label(
        model: "custom (beta)", reasoning_effort: "high"
      )

      # Cutting the first ")" used to claim the model's own bracket, yielding
      # "custom (beta@high)".
      expect(result.send(:short_candidate_label, label)).to eq("custom (beta)#{separator}high")
    end

    it "renders the table header in the same notation the CLI accepts" do
      label = RubyLLM::Contract::Eval::ModelComparison.candidate_label(
        model: "gpt-4.1-mini", reasoning_effort: "low"
      )

      header = result.send(:short_candidate_label, label)

      # Whatever abbreviation the header applies, the effort must still be
      # attached with the separator the CLI documents.
      expect(header).to end_with("#{separator}low")
    end
  end

  # CaseExecutor decides skip-versus-raise by substring-matching the sentence
  # Step::Base raises, so both ends must keep agreeing.
  describe "missing-adapter message" do
    let(:executor) { RubyLLM::Contract::Eval::CaseExecutor.allocate }

    it "recognises the real error the step raises" do
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
