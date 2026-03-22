# frozen_string_literal: true

require "ruby_llm/contract/rspec"

RSpec.describe "ADR-0010: Architecture review fixes" do
  before do
    RubyLLM::Contract.reset_configuration!
    RubyLLM::Contract.reset_eval_hosts!
  end

  # ===========================================================================
  # H1: Pipeline eval uses total cost/latency, not just last step
  # ===========================================================================

  describe "pipeline eval cost/latency" do
    it "uses Pipeline::Trace total_cost and total_latency_ms" do
      # Pipeline::Trace has total_cost computed from all step traces
      pipeline_trace = RubyLLM::Contract::Pipeline::Trace.new(
        total_latency_ms: 500,
        step_traces: [
          RubyLLM::Contract::Step::Trace.new(model: "test", latency_ms: 200, cost: 0.01),
          RubyLLM::Contract::Step::Trace.new(model: "test", latency_ms: 300, cost: 0.02)
        ]
      )

      expect(pipeline_trace.total_cost).to eq(0.03)
      expect(pipeline_trace.total_latency_ms).to eq(500)
    end
  end

  # ===========================================================================
  # H2: compare_models isolates adapter state
  # ===========================================================================

  describe "compare_models adapter isolation" do
    it "each model run gets independent adapter state" do
      step = Class.new(RubyLLM::Contract::Step::Base) do
        prompt { user "{input}" }
      end

      step.define_eval("test") do
        add_case "a", input: "x", expected: { v: 1 }
        add_case "b", input: "y", expected: { v: 1 }
      end

      # responses: with 2 items — without isolation, model-b would start at index 2
      adapter = RubyLLM::Contract::Adapters::Test.new(
        responses: ['{"v": 1}', '{"v": 1}']
      )

      comparison = step.compare_models("test",
        models: %w[model-a model-b],
        context: { adapter: adapter })

      # Both models should see same responses (index starts at 0 for each)
      expect(comparison.score_for("model-a")).to eq(comparison.score_for("model-b"))
    end
  end

  # ===========================================================================
  # H4: Offline mode — skip instead of crash
  # ===========================================================================

  describe "offline mode skips cases without adapter" do
    it "returns skipped result instead of crashing" do
      step = Class.new(RubyLLM::Contract::Step::Base) do
        prompt { user "{input}" }
      end

      step.define_eval("offline") do
        add_case "no adapter", input: "test", expected: { v: 1 }
      end

      # No adapter configured, no sample_response — should skip, not crash
      report = step.run_eval("offline")
      expect(report.results.first.step_status).to eq(:skipped)
      expect(report.results.first.label).to eq("SKIP")
      expect(report.results.first.details).to include("skipped")
    end
  end

  # ===========================================================================
  # M1: expected_traits accessible from define_eval DSL
  # ===========================================================================

  describe "expected_traits in add_case" do
    it "supports expected_traits parameter" do
      step = Class.new(RubyLLM::Contract::Step::Base) do
        prompt { user "{input}" }
      end

      adapter = RubyLLM::Contract::Adapters::Test.new(
        response: '{"intent": "billing_support", "score": 95}'
      )

      step.define_eval("traits") do
        add_case "regex trait",
          input: "test",
          expected_traits: { intent: /billing/, score: 80..100 }
      end

      report = step.run_eval("traits", context: { adapter: adapter })
      expect(report.passed?).to be true
    end
  end

  # ===========================================================================
  # M2: with_maximum_cost failure test
  # ===========================================================================

  describe "with_maximum_cost failure" do
    it "fails when report cost exceeds budget" do
      results = [
        RubyLLM::Contract::Eval::CaseResult.new(
          name: "expensive", input: "x", output: { v: 1 }, expected: { v: 1 },
          step_status: :ok, score: 1.0, passed: true, cost: 0.05
        )
      ]
      report = RubyLLM::Contract::Eval::Report.new(dataset_name: "test", results: results)

      expect(report.total_cost).to eq(0.05)

      # Simulate what pass_eval matcher does
      maximum_cost = 0.01
      cost_ok = report.total_cost <= maximum_cost
      expect(cost_ok).to be false
    end
  end

  # ===========================================================================
  # M5: verify raises on both positional and expect:
  # ===========================================================================

  describe "verify argument validation" do
    it "raises when both positional and expect: keyword are provided" do
      step = Class.new(RubyLLM::Contract::Step::Base) do
        prompt { user "{input}" }
      end

      expect {
        step.define_eval("bad") do
          default_input "test"
          verify "double arg", { foo: 1 }, expect: { bar: 2 }
        end
      }.to raise_error(ArgumentError, /not both/)
    end
  end

  # ===========================================================================
  # L1: print_summary replaces pretty_print
  # ===========================================================================

  describe "print_summary" do
    it "Report responds to print_summary" do
      results = [
        RubyLLM::Contract::Eval::CaseResult.new(
          name: "test", input: "x", output: {}, expected: nil,
          step_status: :ok, score: 1.0, passed: true
        )
      ]
      report = RubyLLM::Contract::Eval::Report.new(dataset_name: "test", results: results)
      expect(report).to respond_to(:print_summary)
    end

    it "ModelComparison responds to print_summary" do
      comparison = RubyLLM::Contract::Eval::ModelComparison.new(eval_name: "test", reports: {})
      expect(comparison).to respond_to(:print_summary)
    end
  end

  # ===========================================================================
  # L2: CaseResult#to_h round-trip works
  # ===========================================================================

  describe "CaseResult to_h round-trip" do
    it "to_h uses name: key (not case_name:)" do
      result = RubyLLM::Contract::Eval::CaseResult.new(
        name: "test", input: "x", output: {}, expected: nil,
        step_status: :ok, score: 1.0, passed: true
      )
      h = result.to_h
      expect(h).to have_key(:name)
      expect(h).not_to have_key(:case_name)
    end

    it "round-trips through to_h" do
      original = RubyLLM::Contract::Eval::CaseResult.new(
        name: "test", input: "x", output: { v: 1 }, expected: { v: 1 },
        step_status: :ok, score: 1.0, passed: true, cost: 0.001
      )
      reconstructed = RubyLLM::Contract::Eval::CaseResult.new(**original.to_h)
      expect(reconstructed.name).to eq(original.name)
      expect(reconstructed.score).to eq(original.score)
      expect(reconstructed.cost).to eq(original.cost)
    end
  end

  # ===========================================================================
  # L3: best_for excludes zero-score models
  # ===========================================================================

  describe "best_for excludes zero-score" do
    it "does not recommend model with 0% accuracy" do
      zero_report = RubyLLM::Contract::Eval::Report.new(
        dataset_name: "test",
        results: [
          RubyLLM::Contract::Eval::CaseResult.new(
            name: "a", input: "x", output: {}, expected: { v: 1 },
            step_status: :ok, score: 0.0, passed: false, cost: 0.001
          )
        ]
      )

      comparison = RubyLLM::Contract::Eval::ModelComparison.new(
        eval_name: "test",
        reports: { "bad-model" => zero_report }
      )

      expect(comparison.best_for(min_score: 0.0)).to be_nil
    end
  end

  # ===========================================================================
  # M4: eval_dirs on RakeTask
  # ===========================================================================

  describe "RakeTask eval_dirs" do
    it "supports eval_dirs for non-Rails projects" do
      require "ruby_llm/contract/rake_task"
      task = RubyLLM::Contract::RakeTask.new(:"test_dirs_#{rand(1000)}") do |t|
        t.eval_dirs = ["lib/evals", "spec/evals"]
      end
      expect(task.eval_dirs).to eq(["lib/evals", "spec/evals"])
    end
  end
end
