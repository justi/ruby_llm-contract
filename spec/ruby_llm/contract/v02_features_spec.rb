# frozen_string_literal: true

require "ruby_llm/contract/rspec"

RSpec.describe "v0.2 features (ADR-0007)" do
  before do
    RubyLLM::Contract.reset_configuration!
    RubyLLM::Contract.reset_eval_hosts!
  end

  let(:good_response) { '{"priority": "high", "category": "billing", "confidence": 0.9}' }
  let(:adapter) { RubyLLM::Contract::Adapters::Test.new(response: good_response) }

  let(:classify_step) do
    Class.new(RubyLLM::Contract::Step::Base) do
      input_type String
      output_type Hash
      prompt { user "Classify: {input}" }
      validate("has priority") { |o| %w[urgent high medium low].include?(o[:priority]) }
    end
  end

  # ===========================================================================
  # Phase 1: add_case in define_eval
  # ===========================================================================

  describe "add_case in define_eval" do
    it "defines cases with input + expected (partial match)" do
      classify_step.define_eval("regression") do
        add_case "billing ticket",
          input: "I was charged twice",
          expected: { priority: "high", category: "billing" }
      end

      report = classify_step.run_eval("regression", context: { adapter: adapter })
      expect(report.passed?).to be true
      expect(report.score).to eq(1.0)
    end

    it "partial match ignores extra keys in output" do
      classify_step.define_eval("partial") do
        add_case "check priority only",
          input: "Invoice problem",
          expected: { priority: "high" }
      end

      report = classify_step.run_eval("partial", context: { adapter: adapter })
      expect(report.passed?).to be true
    end

    it "fails when expected key mismatches" do
      classify_step.define_eval("mismatch") do
        add_case "wrong priority",
          input: "Can you add dark mode?",
          expected: { priority: "low" }
      end

      report = classify_step.run_eval("mismatch", context: { adapter: adapter })
      expect(report.passed?).to be false
    end

    it "supports multiple cases" do
      multi_adapter = RubyLLM::Contract::Adapters::Test.new(
        responses: [good_response, '{"priority": "low", "category": "feature"}']
      )

      classify_step.define_eval("multi") do
        add_case "billing",
          input: "I was charged twice",
          expected: { priority: "high", category: "billing" }

        add_case "feature request",
          input: "Can you add dark mode?",
          expected: { priority: "low", category: "feature" }
      end

      report = classify_step.run_eval("multi", context: { adapter: multi_adapter })
      expect(report.score).to eq(1.0)
      expect(report.pass_rate).to eq("2/2")
    end

    it "works alongside verify in the same eval" do
      classify_step.define_eval("mixed") do
        add_case "check billing",
          input: "Invoice problem",
          expected: { category: "billing" }

        verify "has confidence", ->(o) { o[:confidence] > 0.5 }, input: "test"
      end

      report = classify_step.run_eval("mixed", context: { adapter: adapter })
      expect(report.pass_rate).to eq("2/2")
    end

    it "uses default_input when case omits input" do
      classify_step.define_eval("defaults") do
        default_input "some query"
        add_case "check priority", expected: { priority: "high" }
      end

      report = classify_step.run_eval("defaults", context: { adapter: adapter })
      expect(report.passed?).to be true
    end

    it "raises when add_case has no input and no default_input" do
      expect {
        classify_step.define_eval("bad") do
          add_case "no input", expected: { priority: "high" }
        end
      }.to raise_error(ArgumentError, /requires input/)
    end
  end

  # ===========================================================================
  # Phase 3: CaseResult value objects + Report.failures
  # ===========================================================================

  describe "CaseResult value objects" do
    before do
      @multi_adapter = RubyLLM::Contract::Adapters::Test.new(
        responses: [good_response, '{"priority": "medium", "category": "other"}']
      )

      classify_step.define_eval("results_test") do
        add_case "billing ticket",
          input: "I was charged twice",
          expected: { priority: "high", category: "billing" }

        add_case "urgent outage",
          input: "Database is down",
          expected: { priority: "urgent", category: "infrastructure" }
      end
    end

    it "report.results returns CaseResult objects" do
      report = classify_step.run_eval("results_test", context: { adapter: @multi_adapter })
      result = report.results.first

      expect(result).to be_a(RubyLLM::Contract::Eval::CaseResult)
      expect(result.name).to eq("billing ticket")
      expect(result.input).to eq("I was charged twice")
      expect(result.output).to be_a(Hash)
      expect(result.expected).to eq({ priority: "high", category: "billing" })
      expect(result.passed?).to be true
      expect(result.score).to eq(1.0)
      expect(result.label).to eq("PASS")
      expect(result.step_status).to eq(:ok)
    end

    it "report.failures returns only failed cases" do
      report = classify_step.run_eval("results_test", context: { adapter: @multi_adapter })

      expect(report.failures.length).to eq(1)
      expect(report.failures.first.name).to eq("urgent outage")
      expect(report.failures.first.failed?).to be true
    end

    it "CaseResult.mismatches returns structured diff" do
      report = classify_step.run_eval("results_test", context: { adapter: @multi_adapter })
      failure = report.failures.first

      expect(failure.mismatches).to include(
        priority: { expected: "urgent", got: "medium" },
        category: { expected: "infrastructure", got: "other" }
      )
    end

    it "CaseResult.mismatches is empty for passing cases" do
      report = classify_step.run_eval("results_test", context: { adapter: @multi_adapter })
      passing = report.results.first

      expect(passing.mismatches).to be_empty
    end

    it "report.score returns float 0.0-1.0" do
      report = classify_step.run_eval("results_test", context: { adapter: @multi_adapter })
      expect(report.score).to be_a(Float)
      expect(report.score).to be_between(0.0, 1.0)
    end

    it "CaseResult.to_h returns backward-compatible hash" do
      report = classify_step.run_eval("results_test", context: { adapter: @multi_adapter })
      h = report.results.first.to_h

      expect(h).to include(
        name: "billing ticket",
        passed: true,
        score: 1.0,
        label: "PASS"
      )
    end
  end

  # ===========================================================================
  # Phase 4: pass_eval with_minimum_score
  # ===========================================================================

  describe "pass_eval with_minimum_score" do
    before do
      multi_adapter = RubyLLM::Contract::Adapters::Test.new(
        responses: [
          good_response,
          '{"priority": "medium", "category": "other"}',
          good_response,
          '{"priority": "medium", "category": "other"}'
        ]
      )

      classify_step.define_eval("scored") do
        add_case "billing",
          input: "I was charged twice",
          expected: { priority: "high", category: "billing" }

        add_case "wrong",
          input: "other",
          expected: { priority: "urgent" }
      end

      @adapter_for_scored = multi_adapter
    end

    it "passes when score >= minimum" do
      expect(classify_step).to pass_eval("scored")
        .with_context(adapter: @adapter_for_scored)
        .with_minimum_score(0.5)
    end

    it "fails when score < minimum" do
      expect(classify_step).not_to pass_eval("scored")
        .with_context(adapter: @adapter_for_scored)
        .with_minimum_score(1.0)
    end

    it "failure message mentions minimum score" do
      matcher = pass_eval("scored").with_context(adapter: @adapter_for_scored).with_minimum_score(1.0)
      matcher.matches?(classify_step)
      msg = matcher.failure_message

      expect(msg).to include("score >= 1.0")
    end
  end

  # ===========================================================================
  # Phase 4: Contract.run_all_evals
  # ===========================================================================

  describe "Contract.run_all_evals" do
    it "discovers and runs all evals across all steps" do
      step_a = Class.new(RubyLLM::Contract::Step::Base) do
        prompt { user "{input}" }
      end

      step_b = Class.new(RubyLLM::Contract::Step::Base) do
        prompt { user "{input}" }
      end

      step_a.define_eval("smoke_a") do
        default_input "test"
        sample_response({ v: 1 })
      end

      step_b.define_eval("smoke_b") do
        default_input "test"
        sample_response({ v: 2 })
      end

      results = RubyLLM::Contract.run_all_evals
      expect(results.keys).to contain_exactly(step_a, step_b)
      results.each_value do |reports|
        expect(reports).to be_a(Hash)
        reports.each_value do |report|
          expect(report).to be_a(RubyLLM::Contract::Eval::Report)
        end
      end
    end

    it "returns empty hash when no evals defined" do
      results = RubyLLM::Contract.run_all_evals
      expect(results).to eq({})
    end

    it "skips steps without evals" do
      step_with = Class.new(RubyLLM::Contract::Step::Base) do
        prompt { user "{input}" }
      end

      _step_without = Class.new(RubyLLM::Contract::Step::Base) do
        prompt { user "{input}" }
      end

      step_with.define_eval("has_eval") do
        default_input "test"
        sample_response({ v: 1 })
      end

      results = RubyLLM::Contract.run_all_evals
      expect(results.keys).to eq([step_with])
    end
  end

  # ===========================================================================
  # P4 fix: nil verify warning
  # ===========================================================================

  describe "nil verify warning (P4)" do
    it "warns when validate block returns nil" do
      step = Class.new(RubyLLM::Contract::Step::Base) do
        prompt { user "{input}" }
        validate("string key access") { |o| o["priority"] } # string key on symbolized hash → nil
      end

      adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"priority": "high"}')

      expect(RubyLLM::Contract::Validator).to receive(:new).and_wrap_original do |original_method|
        validator = original_method.call
        expect(validator).to receive(:warn).with(/returned nil.*string vs symbol/i)
        validator
      end

      step.run("test", context: { adapter: adapter })
    end
  end

  # ===========================================================================
  # Eval host registry
  # ===========================================================================

  describe "eval host registry" do
    it "eval_names returns list of defined eval names" do
      classify_step.define_eval("smoke") do
        default_input "test"
        sample_response({ priority: "high" })
      end

      classify_step.define_eval("full") do
        default_input "test"
        sample_response({ priority: "high" })
      end

      expect(classify_step.eval_names).to contain_exactly("smoke", "full")
    end

    it "eval_defined? returns true when evals exist" do
      classify_step.define_eval("smoke") do
        default_input "test"
        sample_response({ priority: "high" })
      end

      expect(classify_step.eval_defined?).to be true
    end

    it "eval_defined? returns false when no evals" do
      step = Class.new(RubyLLM::Contract::Step::Base) do
        prompt { user "{input}" }
      end

      expect(step.eval_defined?).to be false
    end
  end
end
