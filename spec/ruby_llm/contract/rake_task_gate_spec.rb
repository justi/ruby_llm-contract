# frozen_string_literal: true

require "tmpdir"
require "ruby_llm/contract/rake_task"

# Characterization tests for the gate logic in RakeTask#define_task
# (lib/ruby_llm/contract/rake_task.rb). Pin pre-refactor behaviour
# BEFORE extracting `SuiteGate` value object (Batch 4 / B4-T2 / TODO).
#
# Four gating dimensions are exercised:
#   1. All reports pass        → task succeeds (no abort)
#   2. Any report fails score  → task aborts with FAILED message
#   3. suite_cost > maximum    → task aborts with cost message (cost gate runs BEFORE score gate)
#   4. Baselines saved only when gate_passed (not on score failure)
RSpec.describe "RakeTask gate logic (pre-SuiteGate extraction)" do
  before do
    RubyLLM::Contract.reset_configuration!
    RubyLLM::Contract.reset_eval_hosts!
  end

  let(:passing_adapter) { RubyLLM::Contract::Adapters::Test.new(response: '{"label":"x"}') }
  let(:failing_adapter) { RubyLLM::Contract::Adapters::Test.new(response: '{"label":""}') }

  def step_with_eval(eval_name = "smoke")
    klass = Class.new(RubyLLM::Contract::Step::Base) do
      input_type String
      output_type Hash
      prompt { user "Classify: {input}" }
      validate("non-empty label") { |o| o[:label].to_s != "" }
    end
    klass.define_eval(eval_name) do
      add_case "case_1", input: "test", expected: { label: "x" }
    end
    klass
  end

  describe "1. gate passes — task runs to completion without abort" do
    it "prints 'All evals passed' and does not raise SystemExit" do
      step_with_eval
      task = RubyLLM::Contract::RakeTask.new(:"gate_pass_#{rand(10_000)}") do |t|
        t.context = { adapter: passing_adapter }
      end

      expect do
        expect { Rake::Task[task.name].invoke }.not_to raise_error
      end.to output(/All evals passed/).to_stdout
    end
  end

  describe "2. gate fails — score threshold not met aborts the task" do
    it "raises SystemExit with 'Eval suite FAILED' message" do
      step_with_eval
      task = RubyLLM::Contract::RakeTask.new(:"gate_fail_#{rand(10_000)}") do |t|
        t.context = { adapter: failing_adapter }
      end

      expect do
        expect { Rake::Task[task.name].invoke }.to raise_error(SystemExit, /Eval suite FAILED/)
      end.to output.to_stdout # absorb the task's output
    end
  end

  describe "3. cost gate takes priority over score gate" do
    it "aborts with cost message when suite_cost > maximum_cost (even on a passing suite)" do
      step_with_eval

      # Register a model so CostCalculator returns non-zero cost for the
      # adapter's reported usage; without this, Test adapter cost is 0
      # and the cost gate would never fire.
      RubyLLM::Contract::CostCalculator.register_model(
        "test-pricey-model", input_per_1m: 1_000.0, output_per_1m: 1_000.0
      )
      adapter = RubyLLM::Contract::Adapters::Test.new(
        response: '{"label":"x"}',
        usage: { input_tokens: 1_000, output_tokens: 500 }
      )

      task = RubyLLM::Contract::RakeTask.new(:"gate_cost_#{rand(10_000)}") do |t|
        t.context = { adapter: adapter, model: "test-pricey-model" }
        t.maximum_cost = 0.0001 # tiny budget — guaranteed exceeded
      end

      expect do
        expect { Rake::Task[task.name].invoke }
          .to raise_error(SystemExit, /total cost.*exceeds budget/)
      end.to output.to_stdout
    ensure
      RubyLLM::Contract::CostCalculator.reset_custom_models!
    end
  end

  describe "4. baselines saved only on full gate pass, not on score failure" do
    it "does NOT save baseline files when a report fails score" do
      step_with_eval

      Dir.mktmpdir do |dir|
        Dir.chdir(dir) do
          task = RubyLLM::Contract::RakeTask.new(:"gate_baseline_fail_#{rand(10_000)}") do |t|
            t.context = { adapter: failing_adapter }
            t.save_baseline = true
          end

          # Positive proof the task actually ran the eval (the report's
          # FAIL case_1 line proves the dataset was loaded, the step was
          # invoked, and validation produced a failed case). Without this,
          # an early-bailout regression (empty results, never-loaded evals)
          # could leave no baselines on disk and pass the negation
          # vacuously. NOTE: the "Eval suite FAILED" message goes to stderr
          # via `abort`, so we match the stdout-bound report dump instead.
          expect do
            expect { Rake::Task[task.name].invoke }.to raise_error(SystemExit)
          end.to output(%r{FAIL\s+case_1}).to_stdout

          baselines = Dir.glob(File.join(dir, ".eval_baselines", "*"))
          expect(baselines).to be_empty
        end
      end
    end

    it "DOES save baseline files when all reports pass" do
      step_with_eval

      Dir.mktmpdir do |dir|
        Dir.chdir(dir) do
          task = RubyLLM::Contract::RakeTask.new(:"gate_baseline_pass_#{rand(10_000)}") do |t|
            t.context = { adapter: passing_adapter }
            t.save_baseline = true
          end

          expect do
            expect { Rake::Task[task.name].invoke }.not_to raise_error
          end.to output(/Baseline saved/).to_stdout
        end
      end
    end
  end
end
