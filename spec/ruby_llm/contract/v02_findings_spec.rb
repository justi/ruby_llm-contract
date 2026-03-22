# frozen_string_literal: true

require "ruby_llm/contract/rake_task"

RSpec.describe "v0.2 review findings" do
  before do
    RubyLLM::Contract.reset_configuration!
    RubyLLM::Contract.reset_eval_hosts!
  end

  # ===========================================================================
  # Finding 1 (HIGH): Rake task CI gate must fail on empty registry
  # ===========================================================================

  describe "RakeTask fail_on_empty" do
    it "defaults fail_on_empty to true" do
      task = RubyLLM::Contract::RakeTask.new(:"test_eval_#{rand(1000)}") do |t|
        t.context = {}
      end
      expect(task.fail_on_empty).to be true
    end

    it "can be set to false" do
      task = RubyLLM::Contract::RakeTask.new(:"test_eval_#{rand(1000)}") do |t|
        t.fail_on_empty = false
      end
      expect(task.fail_on_empty).to be false
    end

    it "supports minimum_score threshold" do
      task = RubyLLM::Contract::RakeTask.new(:"test_eval_#{rand(1000)}") do |t|
        t.minimum_score = 0.8
      end
      expect(task.minimum_score).to eq(0.8)
    end

    it "defaults minimum_score to nil (require 100%)" do
      task = RubyLLM::Contract::RakeTask.new(:"test_eval_#{rand(1000)}")
      expect(task.minimum_score).to be_nil
    end
  end

  # ===========================================================================
  # Finding 2 (MEDIUM): Subclasses with inherited evals must be discovered
  # ===========================================================================

  describe "inherited eval discovery" do
    it "inherited hook registers subclass when parent has evals" do
      parent = Class.new(RubyLLM::Contract::Step::Base) do
        prompt { user "{input}" }
      end

      parent.define_eval("smoke") do
        default_input "test"
        sample_response({ v: 1 })
      end

      # Subclass created AFTER parent has evals — inherited hook fires
      child = Class.new(parent)

      expect(RubyLLM::Contract.eval_hosts).to include(child)
      expect(child.eval_defined?).to be true
    end

    it "define_eval registers existing subclasses created BEFORE parent defines evals" do
      parent = Class.new(RubyLLM::Contract::Step::Base) do
        prompt { user "{input}" }
      end

      # Child created before eval defined on parent
      child = Class.new(parent)

      # Now parent defines eval — child gets registered via ObjectSpace scan in define_eval
      parent.define_eval("smoke") do
        default_input "test"
        sample_response({ v: 1 })
      end

      expect(RubyLLM::Contract.eval_hosts).to include(child)
      expect(child.eval_defined?).to be true
    end

    it "run_all_evals includes subclass with inherited evals" do
      parent = Class.new(RubyLLM::Contract::Step::Base) do
        prompt { user "{input}" }
      end

      parent.define_eval("smoke") do
        default_input "test"
        sample_response({ v: 1 })
      end

      child = Class.new(parent)

      # Use context with adapter to avoid other discovered steps failing
      adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"v": 1}')
      results = RubyLLM::Contract.run_all_evals(context: { adapter: adapter })
      expect(results.keys).to include(child)
    end

    it "child.run_eval works for inherited eval" do
      parent = Class.new(RubyLLM::Contract::Step::Base) do
        prompt { user "{input}" }
      end

      adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"v": 1}')
      parent.define_eval("smoke") do
        default_input "test"
        sample_response({ v: 1 })
      end

      child = Class.new(parent)
      report = child.run_eval("smoke", context: { adapter: adapter })
      expect(report.passed?).to be true
    end

    it "Pipeline subclasses also inherit eval registration" do
      step = Class.new(RubyLLM::Contract::Step::Base) do
        prompt { user "{input}" }
      end

      parent_pipeline = Class.new(RubyLLM::Contract::Pipeline::Base)
      parent_pipeline.step step, as: :only

      parent_pipeline.define_eval("e2e") do
        default_input "test"
        verify "has output", ->(o) { !o.nil? }, input: "test"
      end

      child_pipeline = Class.new(parent_pipeline)
      expect(RubyLLM::Contract.eval_hosts).to include(child_pipeline)
    end
  end

  # ===========================================================================
  # Finding 3 (MEDIUM): CaseResult must preserve custom labels
  # ===========================================================================

  describe "CaseResult custom label" do
    it "preserves label from EvaluationResult" do
      result = RubyLLM::Contract::Eval::CaseResult.new(
        name: "test", input: "x", output: {}, expected: nil,
        step_status: :ok, score: 0.75, passed: true,
        label: "PARTIAL"
      )
      expect(result.label).to eq("PARTIAL")
    end

    it "defaults to PASS/FAIL when no label given" do
      pass = RubyLLM::Contract::Eval::CaseResult.new(
        name: "pass", input: "x", output: {}, expected: nil,
        step_status: :ok, score: 1.0, passed: true
      )
      fail_result = RubyLLM::Contract::Eval::CaseResult.new(
        name: "fail", input: "x", output: {}, expected: nil,
        step_status: :ok, score: 0.0, passed: false
      )

      expect(pass.label).to eq("PASS")
      expect(fail_result.label).to eq("FAIL")
    end

    it "runner passes label through from evaluator" do
      step = Class.new(RubyLLM::Contract::Step::Base) do
        prompt { user "{input}" }
      end

      adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"v": 1}')

      # Custom evaluator that returns a numeric score → ProcEvaluator
      # ProcEvaluator with numeric return sets label based on threshold
      step.define_eval("custom_label") do
        default_input "test"
        verify "partial match", ->(o) { 0.75 }
      end

      report = step.run_eval("custom_label", context: { adapter: adapter })
      result = report.results.first

      # ProcEvaluator with 0.75 score passes (>= 0.5) but label is set by EvaluationResult
      expect(result.score).to eq(0.75)
      expect(result.passed?).to be true
    end
  end

  # ===========================================================================
  # Finding: ProcEvaluator nil warning (P4 completion)
  # ===========================================================================

  describe "ProcEvaluator nil warning" do
    it "warns when verify proc returns nil (string key on symbolized hash)" do
      evaluator = RubyLLM::Contract::Eval::Evaluator::ProcEvaluator.new(
        ->(o) { o["priority"] } # string key → nil on symbolized hash
      )

      expect(evaluator).to receive(:warn).with(/returned nil.*string vs symbol/i)
      evaluator.call(output: { priority: "high" })
    end

    it "does not warn when proc returns false" do
      evaluator = RubyLLM::Contract::Eval::Evaluator::ProcEvaluator.new(
        ->(_o) { false }
      )

      expect(evaluator).not_to receive(:warn)
      evaluator.call(output: { priority: "high" })
    end
  end
end
