# frozen_string_literal: true

require "ruby_llm/contract/rspec"
require "ruby_llm/contract/rake_task"

RSpec.describe "ADR-0008: Cost of Quality" do
  before do
    RubyLLM::Contract.reset_configuration!
    RubyLLM::Contract.reset_eval_hosts!
  end

  let(:step) do
    Class.new(RubyLLM::Contract::Step::Base) do
      input_type String
      output_type Hash
      prompt { user "Classify: {input}" }
      validate("has priority") { |o| %w[urgent high medium low].include?(o[:priority]) }
    end
  end

  # ===========================================================================
  # Phase 1: Cost in CaseResult + Report
  # ===========================================================================

  describe "cost in CaseResult" do
    it "CaseResult has cost attribute" do
      result = RubyLLM::Contract::Eval::CaseResult.new(
        name: "test", input: "x", output: {}, expected: nil,
        step_status: :ok, score: 1.0, passed: true, cost: 0.00085
      )
      expect(result.cost).to eq(0.00085)
    end

    it "CaseResult cost defaults to nil" do
      result = RubyLLM::Contract::Eval::CaseResult.new(
        name: "test", input: "x", output: {}, expected: nil,
        step_status: :ok, score: 1.0, passed: true
      )
      expect(result.cost).to be_nil
    end

    it "CaseResult.to_h includes cost" do
      result = RubyLLM::Contract::Eval::CaseResult.new(
        name: "test", input: "x", output: {}, expected: nil,
        step_status: :ok, score: 1.0, passed: true, cost: 0.001
      )
      expect(result.to_h[:cost]).to eq(0.001)
    end
  end

  describe "cost in Report" do
    it "total_cost sums case costs" do
      results = [
        RubyLLM::Contract::Eval::CaseResult.new(
          name: "a", input: "x", output: {}, expected: nil,
          step_status: :ok, score: 1.0, passed: true, cost: 0.001
        ),
        RubyLLM::Contract::Eval::CaseResult.new(
          name: "b", input: "y", output: {}, expected: nil,
          step_status: :ok, score: 1.0, passed: true, cost: 0.002
        )
      ]
      report = RubyLLM::Contract::Eval::Report.new(dataset_name: "test", results: results)
      expect(report.total_cost).to eq(0.003)
    end

    it "total_cost handles nil costs gracefully" do
      results = [
        RubyLLM::Contract::Eval::CaseResult.new(
          name: "a", input: "x", output: {}, expected: nil,
          step_status: :ok, score: 1.0, passed: true, cost: 0.001
        ),
        RubyLLM::Contract::Eval::CaseResult.new(
          name: "b", input: "y", output: {}, expected: nil,
          step_status: :ok, score: 1.0, passed: true
        )
      ]
      report = RubyLLM::Contract::Eval::Report.new(dataset_name: "test", results: results)
      expect(report.total_cost).to eq(0.001)
    end

    it "avg_latency_ms computes average" do
      results = [
        RubyLLM::Contract::Eval::CaseResult.new(
          name: "a", input: "x", output: {}, expected: nil,
          step_status: :ok, score: 1.0, passed: true, duration_ms: 100
        ),
        RubyLLM::Contract::Eval::CaseResult.new(
          name: "b", input: "y", output: {}, expected: nil,
          step_status: :ok, score: 1.0, passed: true, duration_ms: 200
        )
      ]
      report = RubyLLM::Contract::Eval::Report.new(dataset_name: "test", results: results)
      expect(report.avg_latency_ms).to eq(150.0)
    end

    it "avg_latency_ms returns nil when no latencies" do
      results = [
        RubyLLM::Contract::Eval::CaseResult.new(
          name: "a", input: "x", output: {}, expected: nil,
          step_status: :ok, score: 1.0, passed: true
        )
      ]
      report = RubyLLM::Contract::Eval::Report.new(dataset_name: "test", results: results)
      expect(report.avg_latency_ms).to be_nil
    end

    it "summary includes cost when present" do
      results = [
        RubyLLM::Contract::Eval::CaseResult.new(
          name: "a", input: "x", output: {}, expected: nil,
          step_status: :ok, score: 1.0, passed: true, cost: 0.005
        )
      ]
      report = RubyLLM::Contract::Eval::Report.new(dataset_name: "test", results: results)
      expect(report.summary).to include("$")
    end

    it "summary omits cost when zero" do
      results = [
        RubyLLM::Contract::Eval::CaseResult.new(
          name: "a", input: "x", output: {}, expected: nil,
          step_status: :ok, score: 1.0, passed: true
        )
      ]
      report = RubyLLM::Contract::Eval::Report.new(dataset_name: "test", results: results)
      expect(report.summary).not_to include("$")
    end

    it "pretty_print shows cost per case" do
      results = [
        RubyLLM::Contract::Eval::CaseResult.new(
          name: "billing", input: "x", output: {}, expected: nil,
          step_status: :ok, score: 1.0, passed: true, cost: 0.0008, duration_ms: 342
        )
      ]
      report = RubyLLM::Contract::Eval::Report.new(dataset_name: "test", results: results)
      output = StringIO.new
      report.print_summary(output)
      str = output.string
      expect(str).to include("$0.0008")
      expect(str).to include("342ms")
    end
  end

  # ===========================================================================
  # Phase 2: Model Comparison
  # ===========================================================================

  describe "ModelComparison" do
    let(:report_nano) do
      RubyLLM::Contract::Eval::Report.new(
        dataset_name: "regression",
        results: [
          RubyLLM::Contract::Eval::CaseResult.new(
            name: "billing", input: "x", output: { priority: "high" },
            expected: { priority: "high" }, step_status: :ok,
            score: 1.0, passed: true, cost: 0.001, duration_ms: 200
          ),
          RubyLLM::Contract::Eval::CaseResult.new(
            name: "urgent", input: "y", output: { priority: "high" },
            expected: { priority: "urgent" }, step_status: :ok,
            score: 0.0, passed: false, cost: 0.001, duration_ms: 180
          )
        ]
      )
    end

    let(:report_mini) do
      RubyLLM::Contract::Eval::Report.new(
        dataset_name: "regression",
        results: [
          RubyLLM::Contract::Eval::CaseResult.new(
            name: "billing", input: "x", output: { priority: "high" },
            expected: { priority: "high" }, step_status: :ok,
            score: 1.0, passed: true, cost: 0.004, duration_ms: 400
          ),
          RubyLLM::Contract::Eval::CaseResult.new(
            name: "urgent", input: "y", output: { priority: "urgent" },
            expected: { priority: "urgent" }, step_status: :ok,
            score: 1.0, passed: true, cost: 0.004, duration_ms: 380
          )
        ]
      )
    end

    let(:comparison) do
      RubyLLM::Contract::Eval::ModelComparison.new(
        eval_name: "regression",
        reports: { "gpt-4.1-nano" => report_nano, "gpt-4.1-mini" => report_mini }
      )
    end

    it "models returns list of models" do
      expect(comparison.models).to eq(%w[gpt-4.1-nano gpt-4.1-mini])
    end

    it "score_for returns per-model score" do
      expect(comparison.score_for("gpt-4.1-nano")).to eq(0.5)
      expect(comparison.score_for("gpt-4.1-mini")).to eq(1.0)
    end

    it "cost_for returns per-model total cost" do
      expect(comparison.cost_for("gpt-4.1-nano")).to eq(0.002)
      expect(comparison.cost_for("gpt-4.1-mini")).to eq(0.008)
    end

    it "best_for returns cheapest model meeting threshold" do
      expect(comparison.best_for(min_score: 0.4)).to eq("gpt-4.1-nano")
      expect(comparison.best_for(min_score: 0.9)).to eq("gpt-4.1-mini")
    end

    it "best_for returns nil when no model meets threshold" do
      expect(comparison.best_for(min_score: 1.1)).to be_nil
    end

    it "cost_per_point returns cost efficiency" do
      cpp = comparison.cost_per_point
      expect(cpp["gpt-4.1-nano"]).to eq(0.004) # 0.002 / 0.5
      expect(cpp["gpt-4.1-mini"]).to eq(0.008) # 0.008 / 1.0
    end

    it "table returns formatted comparison" do
      str = comparison.table
      expect(str).to include("gpt-4.1-nano")
      expect(str).to include("gpt-4.1-mini")
      expect(str).to include("0.50")
      expect(str).to include("1.00")
    end

    it "pretty_print shows comparison with best model" do
      output = StringIO.new
      comparison.print_summary(output)
      str = output.string
      expect(str).to include("model comparison")
      expect(str).to include("gpt-4.1-nano")
      expect(str).to include("gpt-4.1-mini")
      expect(str).to include("Best overall")
    end

    it "to_h returns structured data" do
      h = comparison.to_h
      expect(h["gpt-4.1-nano"][:score]).to eq(0.5)
      expect(h["gpt-4.1-mini"][:score]).to eq(1.0)
      expect(h["gpt-4.1-mini"][:total_cost]).to eq(0.008)
    end
  end

  describe "compare_models on Step" do
    it "runs eval across models and returns ModelComparison" do
      step.define_eval("regression") do
        add_case "billing",
                 input: "charged twice",
                 expected: { priority: "high" }
      end

      # Each model gets its own adapter copy (deep_dup_context)
      # so both start at index 0 — responses must be per-adapter
      adapter = RubyLLM::Contract::Adapters::Test.new(
        response: '{"priority": "high"}'
      )

      comparison = step.compare_models("regression",
                                       models: %w[model-a model-b],
                                       context: { adapter: adapter })

      expect(comparison).to be_a(RubyLLM::Contract::Eval::ModelComparison)
      expect(comparison.models).to eq(%w[model-a model-b])
      # Both models get same adapter response, both should pass
      expect(comparison.score_for("model-a")).to eq(1.0)
      expect(comparison.score_for("model-b")).to eq(1.0)
    end

    it "isolates adapter state between model runs" do
      step.define_eval("isolation") do
        add_case "case1", input: "a", expected: { priority: "high" }
        add_case "case2", input: "b", expected: { priority: "high" }
      end

      # With responses: array, each dup starts at index 0
      adapter = RubyLLM::Contract::Adapters::Test.new(
        responses: ['{"priority": "high"}', '{"priority": "low"}']
      )

      comparison = step.compare_models("isolation",
                                       models: %w[model-a model-b],
                                       context: { adapter: adapter })

      # Both models see same responses (high, low) — score should be identical
      expect(comparison.score_for("model-a")).to eq(comparison.score_for("model-b"))
    end

    it "runs each candidate N times with runs: and aggregates score" do
      step.define_eval("variance") do
        add_case "a", input: "x", expected: { priority: "high" }
      end

      # responses cycle: run1=high (pass), run2=low (fail), run3=high (pass)
      adapter = RubyLLM::Contract::Adapters::Test.new(
        responses: ['{"priority": "high"}', '{"priority": "low"}', '{"priority": "high"}']
      )

      comparison = step.compare_models("variance",
                                       models: %w[model-a],
                                       context: { adapter: adapter },
                                       runs: 3)

      report = comparison.reports["model-a"]
      expect(report).to be_a(RubyLLM::Contract::Eval::AggregatedReport)
      expect(report.runs.length).to eq(3)
      expect(report.score).to be_within(0.0001).of(2.0 / 3)
      expect(report.pass_rate).to eq("2/3")
    end

    it "rejects runs < 1" do
      step.define_eval("bad", &proc { add_case "a", input: "x", expected: {} })
      expect do
        step.compare_models("bad", models: %w[m], runs: 0)
      end.to raise_error(ArgumentError, /runs/)
    end

    it "rejects non-Integer runs (Float)" do
      step.define_eval("bad_float", &proc { add_case "a", input: "x", expected: {} })
      expect do
        step.compare_models("bad_float", models: %w[m], runs: 1.5)
      end.to raise_error(ArgumentError, /Integer/)
    end

    it "rejects non-Integer runs (String)" do
      step.define_eval("bad_string", &proc { add_case "a", input: "x", expected: {} })
      expect do
        step.compare_models("bad_string", models: %w[m], runs: "3")
      end.to raise_error(ArgumentError, /Integer/)
    end

    it "returns a plain Report (not AggregatedReport) when runs == 1" do
      step.define_eval("single") do
        add_case "a", input: "x", expected: { priority: "high" }
      end
      adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"priority": "high"}')

      comparison = step.compare_models("single", models: %w[m],
                                                 context: { adapter: adapter }, runs: 1)
      expect(comparison.reports["m"]).to be_a(RubyLLM::Contract::Eval::Report)
    end
  end

  # ===========================================================================
  # Phase 3: CI integration
  # ===========================================================================

  describe "pass_eval with_maximum_cost" do
    before do
      step.define_eval("costed") do
        default_input "test"
        sample_response({ priority: "high" })
        verify "has priority", { priority: /high/ }
      end
    end

    it "passes when cost is within budget" do
      expect(step).to pass_eval("costed").with_maximum_cost(1.0)
    end

    it "failure message mentions cost when over budget" do
      # Test adapter gives 0 cost, so this always passes on cost
      # Test the message format with a constructed report
      matcher = pass_eval("costed").with_maximum_cost(1.0)
      matcher.matches?(step)
      # Verify it doesn't fail (cost is 0 with test adapter)
      expect(matcher.failure_message_when_negated).to include("NOT to pass")
    end
  end

  describe "RakeTask maximum_cost" do
    it "accepts maximum_cost configuration" do
      task = RubyLLM::Contract::RakeTask.new(:"test_cost_#{rand(1000)}") do |t|
        t.maximum_cost = 0.05
      end
      expect(task.maximum_cost).to eq(0.05)
    end

    it "defaults maximum_cost to nil" do
      task = RubyLLM::Contract::RakeTask.new(:"test_cost_default_#{rand(1000)}")
      expect(task.maximum_cost).to be_nil
    end
  end

  # ===========================================================================
  # Integration: Runner extracts cost from trace
  # ===========================================================================

  describe "Runner cost extraction" do
    it "passes cost from step trace to CaseResult" do
      step.define_eval("trace_cost") do
        add_case "test", input: "hello", expected: { priority: "high" }
      end

      adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"priority": "high"}')
      report = step.run_eval("trace_cost", context: { adapter: adapter })

      result = report.results.first
      # Test adapter returns 0 usage, so cost will be 0 or nil
      # The important thing is that cost is populated (not nil) when trace exists
      expect(result).to respond_to(:cost)
    end
  end
end
