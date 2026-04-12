# frozen_string_literal: true

RSpec.describe RubyLLM::Contract::Eval::Recommender do
  before { RubyLLM::Contract.reset_configuration! }

  def build_report(cases)
    results = cases.each_with_index.map do |c, i|
      RubyLLM::Contract::Eval::CaseResult.new(
        name: c[:name] || "case_#{i}",
        input: "test",
        output: {},
        expected: {},
        step_status: :ok,
        score: c[:passed] ? 1.0 : 0.0,
        passed: c[:passed],
        cost: c[:cost] || 0.001,
        duration_ms: c[:duration_ms] || 100
      )
    end
    RubyLLM::Contract::Eval::Report.new(dataset_name: "eval", results: results)
  end

  def build_comparison(candidates)
    reports = {}
    configs = {}

    candidates.each do |c|
      label = RubyLLM::Contract::Eval::ModelComparison.candidate_label(c[:config])
      reports[label] = build_report(c[:cases])
      configs[label] = c[:config]
    end

    RubyLLM::Contract::Eval::ModelComparison.new(
      eval_name: "test_eval",
      reports: reports,
      configs: configs
    )
  end

  describe "#select_best" do
    it "picks the cheapest candidate meeting min_score" do
      comparison = build_comparison([
        { config: { model: "gpt-4.1-nano" },
          cases: [{ passed: true, cost: 0.001 }, { passed: true, cost: 0.001 }] },
        { config: { model: "gpt-4.1-mini" },
          cases: [{ passed: true, cost: 0.01 }, { passed: true, cost: 0.01 }] },
        { config: { model: "gpt-4.1" },
          cases: [{ passed: true, cost: 0.05 }, { passed: true, cost: 0.05 }] }
      ])

      rec = described_class.new(comparison: comparison, min_score: 0.95).recommend

      expect(rec.best[:model]).to eq("gpt-4.1-nano")
    end

    it "uses tiebreaker: equal cost -> lower latency wins" do
      comparison = build_comparison([
        { config: { model: "gpt-4.1-beta" },
          cases: [{ passed: true, cost: 0.001, duration_ms: 300 }] },
        { config: { model: "gpt-4.1-alpha" },
          cases: [{ passed: true, cost: 0.001, duration_ms: 100 }] }
      ])

      rec = described_class.new(comparison: comparison, min_score: 0.95).recommend

      expect(rec.best[:model]).to eq("gpt-4.1-alpha")
    end

    it "uses tiebreaker: equal cost, equal latency -> lexicographic" do
      comparison = build_comparison([
        { config: { model: "gpt-4.1-beta" },
          cases: [{ passed: true, cost: 0.001, duration_ms: 200 }] },
        { config: { model: "gpt-4.1-alpha" },
          cases: [{ passed: true, cost: 0.001, duration_ms: 200 }] }
      ])

      rec = described_class.new(comparison: comparison, min_score: 0.95).recommend

      expect(rec.best[:model]).to eq("gpt-4.1-alpha")
    end

    it "does not favor candidates with unknown latency in tiebreaking" do
      comparison = build_comparison([
        { config: { model: "gpt-4.1-fast" },
          cases: [{ passed: true, cost: 0.001, duration_ms: 100 }] },
        { config: { model: "gpt-4.1-unknown" },
          cases: [{ passed: true, cost: 0.001, duration_ms: nil }] }
      ])

      rec = described_class.new(comparison: comparison, min_score: 0.95).recommend

      # Unknown latency should NOT win over known 100ms
      expect(rec.best[:model]).to eq("gpt-4.1-fast")
    end

    it "excludes candidates with nil/zero cost, flags in warnings" do
      comparison = build_comparison([
        { config: { model: "gpt-4.1-nano" },
          cases: [{ passed: true, cost: 0.0 }] },
        { config: { model: "gpt-4.1-mini" },
          cases: [{ passed: true, cost: 0.01 }] }
      ])

      rec = described_class.new(comparison: comparison, min_score: 0.95).recommend

      expect(rec.best[:model]).to eq("gpt-4.1-mini")
      expect(rec.warnings).to include(match(/gpt-4.1-nano.*unknown pricing/))
    end

    it "shows 'unknown pricing' instead of $0.0000 in rationale for zero-cost candidates" do
      comparison = build_comparison([
        { config: { model: "gpt-4.1-nano" },
          cases: [{ passed: true, cost: 0.0 }] },
        { config: { model: "gpt-4.1-mini" },
          cases: [{ passed: true, cost: 0.01 }] }
      ])

      rec = described_class.new(comparison: comparison, min_score: 0.95).recommend

      nano_line = rec.rationale.find { |r| r.include?("gpt-4.1-nano") }
      expect(nano_line).to include("unknown pricing")
      expect(nano_line).not_to include("$0.0000")
    end

    it "returns nil best and empty chain when no candidate meets min_score" do
      comparison = build_comparison([
        { config: { model: "gpt-4.1-nano" },
          cases: [{ passed: true, cost: 0.001 }, { passed: false, cost: 0.001 }] },
        { config: { model: "gpt-4.1-mini" },
          cases: [{ passed: true, cost: 0.01 }, { passed: false, cost: 0.01 }] }
      ])

      rec = described_class.new(comparison: comparison, min_score: 0.99).recommend

      expect(rec.best).to be_nil
      expect(rec.retry_chain).to be_empty
    end
  end

  describe "#retry_chain" do
    it "returns single element when best has good pass_rate" do
      comparison = build_comparison([
        { config: { model: "gpt-4.1-mini" },
          cases: [{ passed: true, cost: 0.01 }, { passed: true, cost: 0.01 }] }
      ])

      rec = described_class.new(comparison: comparison, min_score: 0.95).recommend

      expect(rec.retry_chain.length).to eq(1)
      expect(rec.retry_chain.first[:model]).to eq("gpt-4.1-mini")
    end

    it "returns two elements when cheap first-try has high pass_rate but low score for best" do
      # nano: cheap, high pass rate, meets score
      # big model: expensive, high score, meets score
      comparison = build_comparison([
        { config: { model: "gpt-4.1-nano" },
          cases: [
            { passed: true, cost: 0.001 },
            { passed: true, cost: 0.001 },
            { passed: true, cost: 0.001 },
            { passed: true, cost: 0.001 },
            { passed: true, cost: 0.001 }
          ] },
        { config: { model: "gpt-4.1" },
          cases: [
            { passed: true, cost: 0.05 },
            { passed: true, cost: 0.05 },
            { passed: true, cost: 0.05 },
            { passed: true, cost: 0.05 },
            { passed: true, cost: 0.05 }
          ] }
      ])

      rec = described_class.new(
        comparison: comparison,
        min_score: 0.95,
        min_first_try_pass_rate: 0.8
      ).recommend

      # Both meet min_score. nano is cheapest => best.
      # nano also meets min_first_try_pass_rate => single element chain (first_try == best)
      expect(rec.retry_chain.length).to eq(1)
      expect(rec.retry_chain.first[:model]).to eq("gpt-4.1-nano")
    end

    it "builds two-element chain when first-try differs from best" do
      # nano: cheap, HIGH pass rate (5/5), but low score (0.6) -- does NOT meet min_score
      # mini: medium cost, HIGH pass rate (4/5), high score (1.0) -- meets min_score but more expensive
      # big: expensive, high score (1.0) -- cheapest meeting min_score is mini
      comparison = build_comparison([
        { config: { model: "gpt-4.1-nano" },
          cases: [
            { passed: true, cost: 0.001 },
            { passed: true, cost: 0.001 },
            { passed: true, cost: 0.001 },
            { passed: false, cost: 0.001 },
            { passed: false, cost: 0.001 }
          ] },
        { config: { model: "gpt-4.1-mini" },
          cases: [
            { passed: true, cost: 0.005 },
            { passed: true, cost: 0.005 },
            { passed: true, cost: 0.005 },
            { passed: true, cost: 0.005 },
            { passed: false, cost: 0.005 }
          ] },
        { config: { model: "gpt-4.1" },
          cases: [
            { passed: true, cost: 0.05 },
            { passed: true, cost: 0.05 },
            { passed: true, cost: 0.05 },
            { passed: true, cost: 0.05 },
            { passed: true, cost: 0.05 }
          ] }
      ])

      rec = described_class.new(
        comparison: comparison,
        min_score: 0.95,
        min_first_try_pass_rate: 0.5
      ).recommend

      # best = cheapest meeting min_score=0.95 is gpt-4.1-mini (score 0.8) -- no
      # Actually: nano score=0.6, mini score=0.8, big score=1.0
      # Only gpt-4.1 meets min_score 0.95 => best = gpt-4.1
      # first_try = cheapest with pass_rate >= 0.5 and cost > 0 => nano (pass_rate=0.6)
      # nano != gpt-4.1 => chain = [nano, gpt-4.1]
      expect(rec.best[:model]).to eq("gpt-4.1")
      expect(rec.retry_chain.length).to eq(2)
      expect(rec.retry_chain.first[:model]).to eq("gpt-4.1-nano")
      expect(rec.retry_chain.last[:model]).to eq("gpt-4.1")
    end

    it "does not duplicate when first-try IS best" do
      comparison = build_comparison([
        { config: { model: "gpt-4.1-mini" },
          cases: [
            { passed: true, cost: 0.01 },
            { passed: true, cost: 0.01 },
            { passed: true, cost: 0.01 },
            { passed: true, cost: 0.01 },
            { passed: true, cost: 0.01 }
          ] }
      ])

      rec = described_class.new(
        comparison: comparison,
        min_score: 0.95,
        min_first_try_pass_rate: 0.8
      ).recommend

      expect(rec.retry_chain.length).to eq(1)
      expect(rec.retry_chain.first[:model]).to eq("gpt-4.1-mini")
    end
  end

  describe "#savings" do
    it "calculates exact savings vs current_config" do
      comparison = build_comparison([
        { config: { model: "gpt-4.1-nano" },
          cases: [{ passed: true, cost: 0.001 }] },
        { config: { model: "gpt-4.1" },
          cases: [{ passed: true, cost: 0.05 }] }
      ])

      rec = described_class.new(
        comparison: comparison,
        min_score: 0.95,
        current_config: { model: "gpt-4.1" }
      ).recommend

      # nano cost_per_call=0.001, gpt-4.1 cost_per_call=0.05, diff=0.049
      expect(rec.savings[:per_call]).to eq(0.049)
      expect(rec.savings[:monthly_at]).to eq({ 10_000 => 490.0 })
    end

    it "returns empty savings when no current_config" do
      comparison = build_comparison([
        { config: { model: "gpt-4.1-nano" },
          cases: [{ passed: true, cost: 0.001 }] }
      ])

      rec = described_class.new(comparison: comparison, min_score: 0.95).recommend

      expect(rec.savings).to eq({})
    end
  end
end
