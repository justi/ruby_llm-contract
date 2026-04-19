# frozen_string_literal: true

RSpec.describe "production_mode: cost measurement" do
  before { RubyLLM::Contract.reset_configuration! }

  def build_result(passed:, cost:, duration_ms:, attempts: nil)
    RubyLLM::Contract::Eval::CaseResult.new(
      name: "c", input: "x", output: {}, expected: {}, step_status: :ok,
      score: passed ? 1.0 : 0.0, passed: passed,
      cost: cost, duration_ms: duration_ms, attempts: attempts
    )
  end

  describe "ReportStats production-mode metrics" do
    it "returns nil when no result has attempts (classic mode)" do
      results = [build_result(passed: true, cost: 0.001, duration_ms: 100)]
      report = RubyLLM::Contract::Eval::Report.new(dataset_name: "e", results: results)

      expect(report.production_mode?).to eq(false)
      expect(report.escalation_rate).to be_nil
      expect(report.single_shot_cost).to be_nil
    end

    it "computes escalation_rate, single_shot_cost, effective_cost from attempts" do
      results = [
        build_result(passed: true, cost: 0.001, duration_ms: 120,
                     attempts: [{ attempt: 1, cost: 0.001, latency_ms: 120 }]),
        build_result(passed: true, cost: 0.001, duration_ms: 120,
                     attempts: [{ attempt: 1, cost: 0.001, latency_ms: 120 }]),
        build_result(passed: true, cost: 0.001, duration_ms: 120,
                     attempts: [{ attempt: 1, cost: 0.001, latency_ms: 120 }]),
        build_result(passed: true, cost: 0.004, duration_ms: 340,
                     attempts: [{ attempt: 1, cost: 0.001, latency_ms: 120 },
                                { attempt: 2, cost: 0.003, latency_ms: 220 }]),
        build_result(passed: true, cost: 0.004, duration_ms: 340,
                     attempts: [{ attempt: 1, cost: 0.001, latency_ms: 120 },
                                { attempt: 2, cost: 0.003, latency_ms: 220 }])
      ]
      report = RubyLLM::Contract::Eval::Report.new(dataset_name: "e", results: results)

      expect(report.production_mode?).to eq(true)
      expect(report.escalation_rate).to be_within(1e-9).of(0.4)
      expect(report.single_shot_cost).to be_within(1e-9).of(0.005)
      expect(report.effective_cost).to be_within(1e-9).of(0.011)
      expect(report.single_shot_latency_ms).to be_within(1e-6).of(120.0)
    end
  end

  describe "AggregatedReport averages across runs" do
    it "means escalation_rate across runs" do
      make_run = lambda do |n_escalated|
        results = Array.new(5) do |i|
          escalated = i < n_escalated
          attempts = if escalated
                       [{ cost: 0.001, latency_ms: 120 }, { cost: 0.003, latency_ms: 220 }]
                     else
                       [{ cost: 0.001, latency_ms: 120 }]
                     end
          build_result(passed: true, cost: escalated ? 0.004 : 0.001,
                       duration_ms: escalated ? 340 : 120, attempts: attempts)
        end
        RubyLLM::Contract::Eval::Report.new(dataset_name: "e", results: results)
      end

      agg = RubyLLM::Contract::Eval::AggregatedReport.new([make_run.call(1), make_run.call(2), make_run.call(3)])

      expect(agg.production_mode?).to eq(true)
      expect(agg.escalation_rate).to be_within(1e-9).of(0.4) # (0.2 + 0.4 + 0.6) / 3
      expect(agg.effective_cost).to be > agg.single_shot_cost
    end
  end

  describe "compare_models with production_mode integration" do
    let(:step) do
      Class.new(RubyLLM::Contract::Step::Base) do
        prompt { user "{input}" }
        output_type RubyLLM::Contract::Types::Hash
        contract do
          parse :json
          validate "has name" do |output|
            output.is_a?(Hash) && output[:name]
          end
        end

        define_eval "basic" do
          add_case "case1", input: "x", expected: { name: "Alice" }
          verify "name present", input: "x", expect: ->(o) { o.is_a?(Hash) && o[:name] }
        end
      end
    end

    it "injects retry_policy via context and reports production-mode metrics" do
      adapter = RubyLLM::Contract::Adapters::Test.new(
        responses: [{ "name" => "Alice" }] # candidate succeeds; no escalation needed
      )

      comparison = step.compare_models(
        "basic",
        candidates: [{ model: "gpt-5-nano" }],
        context: { adapter: adapter },
        production_mode: { fallback: "gpt-5-mini" }
      )

      report = comparison.reports["gpt-5-nano"]
      expect(report.production_mode?).to eq(true)
      expect(report.escalation_rate).to eq(0.0)
      expect(comparison.production_mode?).to eq(true)
      expect(comparison.fallback).to eq({ model: "gpt-5-mini" })
    end

    it "skips retry_policy injection when candidate equals fallback (em-dash edge)" do
      adapter = RubyLLM::Contract::Adapters::Test.new(responses: [{ "name" => "Alice" }])

      comparison = step.compare_models(
        "basic",
        candidates: [{ model: "gpt-5-mini" }],
        context: { adapter: adapter },
        production_mode: { fallback: "gpt-5-mini" }
      )

      report = comparison.reports["gpt-5-mini"]
      # When candidate == fallback we bypass retry_policy injection; report has no attempts
      expect(report.production_mode?).to eq(false)
      expect(comparison.table).to include("—")
      expect(comparison.table).not_to include("→")
    end

    it "renders arrow chain for distinct candidate/fallback" do
      adapter = RubyLLM::Contract::Adapters::Test.new(responses: [{ "name" => "Alice" }])

      comparison = step.compare_models(
        "basic",
        candidates: [{ model: "gpt-5-nano" }],
        context: { adapter: adapter },
        production_mode: { fallback: "gpt-5-mini" }
      )

      expect(comparison.table).to include("gpt-5-nano → gpt-5-mini")
    end

    it "rejects production_mode: without :fallback" do
      expect do
        step.compare_models("basic", candidates: [{ model: "gpt-5-nano" }],
                                     production_mode: true)
      end.to raise_error(ArgumentError, /fallback/)
    end

    it "leaves step class-level retry_policy untouched across runs" do
      step.retry_policy { escalate "gpt-5-nano", "gpt-5-mini" }
      original = step.retry_policy
      adapter = RubyLLM::Contract::Adapters::Test.new(responses: [{ "name" => "Alice" }])

      step.compare_models(
        "basic",
        candidates: [{ model: "gpt-5-nano" }],
        context: { adapter: adapter },
        production_mode: { fallback: "gpt-5-mini" }
      )

      expect(step.retry_policy).to equal(original)
    end
  end
end
