# frozen_string_literal: true

require "ruby_llm/contract"

RSpec.describe RubyLLM::Contract::Eval::AggregatedReport do
  def fake_report(score:, cost: 0.001, latency: 100.0, passed: false, pass_ratio: score, results: [])
    instance_double(
      RubyLLM::Contract::Eval::Report,
      dataset_name: "ds", step_name: "Step",
      score: score, total_cost: cost, avg_latency_ms: latency,
      pass_rate_ratio: pass_ratio, passed?: passed, failures: [],
      results: results, summary: "summary-stub", print_summary: nil
    )
  end

  it "computes mean score across runs" do
    agg = described_class.new([fake_report(score: 0.0), fake_report(score: 0.5), fake_report(score: 1.0)])
    expect(agg.score).to eq(0.5)
  end

  it "reports score min/max spread" do
    agg = described_class.new([fake_report(score: 0.0), fake_report(score: 1.0), fake_report(score: 0.5)])
    expect(agg.score_min).to eq(0.0)
    expect(agg.score_max).to eq(1.0)
  end

  it "reports mean cost per run (not total)" do
    agg = described_class.new([fake_report(score: 1.0, cost: 0.001), fake_report(score: 1.0, cost: 0.003)])
    expect(agg.total_cost).to eq(0.002)
  end

  it "reports mean latency" do
    agg = described_class.new([fake_report(score: 1.0, latency: 100.0), fake_report(score: 1.0, latency: 200.0)])
    expect(agg.avg_latency_ms).to eq(150.0)
  end

  it "pass_rate shows clean-pass count vs total runs" do
    agg = described_class.new([
                                fake_report(score: 1.0, passed: true),
                                fake_report(score: 0.5, passed: false),
                                fake_report(score: 1.0, passed: true)
                              ])
    expect(agg.pass_rate).to eq("2/3")
    expect(agg.clean_passes).to eq(2)
  end

  it "passed? only when every run passed cleanly" do
    all_pass = described_class.new([fake_report(score: 1.0, passed: true), fake_report(score: 1.0, passed: true)])
    one_fail = described_class.new([fake_report(score: 1.0, passed: true), fake_report(score: 0.5, passed: false)])
    expect(all_pass.passed?).to be(true)
    expect(one_fail.passed?).to be(false)
  end

  it "rejects empty runs" do
    expect { described_class.new([]) }.to raise_error(ArgumentError)
  end

  describe "pass_rate_ratio consistency with pass_rate" do
    it "equals clean_passes / runs.length (run-level reliability)" do
      agg = described_class.new([
                                  fake_report(score: 1.0, passed: true),
                                  fake_report(score: 0.5, passed: false),
                                  fake_report(score: 1.0, passed: true)
                                ])
      expect(agg.pass_rate_ratio).to be_within(0.0001).of(2.0 / 3)
      expect(agg.pass_rate).to eq("2/3")
    end

    it "is 1.0 when every run passed" do
      agg = described_class.new([fake_report(score: 1.0, passed: true), fake_report(score: 1.0, passed: true)])
      expect(agg.pass_rate_ratio).to eq(1.0)
    end

    it "is 0.0 when no run passed" do
      agg = described_class.new([fake_report(score: 0.5, passed: false), fake_report(score: 0.5, passed: false)])
      expect(agg.pass_rate_ratio).to eq(0.0)
    end
  end

  describe "Report duck-type (results/each/summary)" do
    it "concatenates results from all runs (eager, survives freeze)" do
      r1 = fake_report(score: 1.0, passed: true, results: [:a, :b])
      r2 = fake_report(score: 0.5, passed: false, results: [:c])
      agg = described_class.new([r1, r2])
      expect(agg.results).to eq([:a, :b, :c])
      expect(agg.results).to be_frozen
    end

    it "each iterates over concatenated results" do
      r1 = fake_report(score: 1.0, passed: true, results: [:a])
      r2 = fake_report(score: 1.0, passed: true, results: [:b, :c])
      agg = described_class.new([r1, r2])
      collected = []
      agg.each { |x| collected << x }
      expect(collected).to eq([:a, :b, :c])
    end

    it "summary delegates to first run (minimum viable presenter)" do
      r1 = fake_report(score: 1.0, passed: true)
      agg = described_class.new([r1, fake_report(score: 0.5, passed: false)])
      expect(agg.summary).to eq("summary-stub")
    end

    it "print_summary delegates to first run" do
      r1 = fake_report(score: 1.0, passed: true)
      agg = described_class.new([r1])
      io = StringIO.new
      expect(r1).to receive(:print_summary).with(io)
      agg.print_summary(io)
    end

    it "is compatible with Recommender consumers (report.results usable)" do
      # Recommender does: report.results.count { |r| r.step_status != :skipped }
      result_double = double(step_status: :ok)
      agg = described_class.new([fake_report(score: 1.0, passed: true, results: [result_double])])
      expect(agg.results.count { |r| r.step_status != :skipped }).to eq(1)
    end
  end
end
