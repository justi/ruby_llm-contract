# frozen_string_literal: true

require "tmpdir"
require "ruby_llm/contract/rspec"

RSpec.describe "Baseline Regression (ADR-0009)" do
  before do
    RubyLLM::Contract.reset_configuration!
    RubyLLM::Contract.reset_eval_hosts!
  end

  def build_report(name, cases)
    results = cases.map do |c|
      RubyLLM::Contract::Eval::CaseResult.new(
        name: c[:name], input: "test", output: c[:output] || {},
        expected: c[:expected] || {}, step_status: :ok,
        score: c[:passed] ? 1.0 : 0.0, passed: c[:passed],
        details: c[:details], cost: c[:cost] || 0.001
      )
    end
    RubyLLM::Contract::Eval::Report.new(dataset_name: name, results: results)
  end

  # ===========================================================================
  # save_baseline! + compare_with_baseline
  # ===========================================================================

  describe "save and compare" do
    it "saves baseline to JSON file" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "baseline.json")
        report = build_report("smoke", [
          { name: "billing", passed: true },
          { name: "feature", passed: true }
        ])

        saved_path = report.save_baseline!(path: path)
        expect(File.exist?(saved_path)).to be true

        data = JSON.parse(File.read(saved_path), symbolize_names: true)
        expect(data[:dataset_name]).to eq("smoke")
        expect(data[:cases].length).to eq(2)
        expect(data[:cases][0][:name]).to eq("billing")
        expect(data[:cases][0][:passed]).to be true
      end
    end

    it "detects regressions" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "baseline.json")

        # Baseline: both pass
        baseline = build_report("smoke", [
          { name: "billing", passed: true },
          { name: "feature", passed: true }
        ])
        baseline.save_baseline!(path: path)

        # Current: feature regressed
        current = build_report("smoke", [
          { name: "billing", passed: true },
          { name: "feature", passed: false, details: "priority mismatch" }
        ])

        diff = current.compare_with_baseline(path: path)

        expect(diff.regressed?).to be true
        expect(diff.regressions.length).to eq(1)
        expect(diff.regressions[0][:case]).to eq("feature")
        expect(diff.score_delta).to eq(-0.5)
      end
    end

    it "detects improvements" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "baseline.json")

        baseline = build_report("smoke", [
          { name: "billing", passed: false },
          { name: "feature", passed: true }
        ])
        baseline.save_baseline!(path: path)

        current = build_report("smoke", [
          { name: "billing", passed: true },
          { name: "feature", passed: true }
        ])

        diff = current.compare_with_baseline(path: path)

        expect(diff.regressed?).to be false
        expect(diff.improved?).to be true
        expect(diff.improvements[0][:case]).to eq("billing")
        expect(diff.score_delta).to eq(0.5)
      end
    end

    it "detects new and removed cases" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "baseline.json")

        baseline = build_report("smoke", [
          { name: "old_case", passed: true }
        ])
        baseline.save_baseline!(path: path)

        current = build_report("smoke", [
          { name: "new_case", passed: true }
        ])

        diff = current.compare_with_baseline(path: path)
        expect(diff.new_cases).to eq(["new_case"])
        expect(diff.removed_cases).to eq(["old_case"])
      end
    end

    it "raises when no baseline exists" do
      report = build_report("smoke", [{ name: "a", passed: true }])
      expect {
        report.compare_with_baseline(path: "/nonexistent/baseline.json")
      }.to raise_error(ArgumentError, /No baseline found/)
    end

    it "baseline_exists? returns true/false" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "baseline.json")
        report = build_report("smoke", [{ name: "a", passed: true }])

        expect(report.baseline_exists?(path: path)).to be false
        report.save_baseline!(path: path)
        expect(report.baseline_exists?(path: path)).to be true
      end
    end
  end

  # ===========================================================================
  # BaselineDiff
  # ===========================================================================

  describe "BaselineDiff" do
    it "to_s shows readable summary" do
      diff = RubyLLM::Contract::Eval::BaselineDiff.new(
        baseline_cases: [
          { name: "a", passed: true, score: 1.0 },
          { name: "b", passed: true, score: 1.0 }
        ],
        current_cases: [
          { name: "a", passed: true, score: 1.0 },
          { name: "b", passed: false, score: 0.0, details: "wrong priority" }
        ]
      )

      str = diff.to_s
      expect(str).to include("REGRESSED")
      expect(str).to include("1.0")
      expect(str).to include("0.5")
    end

    it "handles empty baseline" do
      diff = RubyLLM::Contract::Eval::BaselineDiff.new(
        baseline_cases: [],
        current_cases: [{ name: "a", passed: true, score: 1.0 }]
      )

      expect(diff.regressed?).to be false
      expect(diff.new_cases).to eq(["a"])
    end
  end

  # ===========================================================================
  # RSpec matcher: without_regressions
  # ===========================================================================

  describe "pass_eval.without_regressions" do
    it "passes when no baseline exists (first run)" do
      step = Class.new(RubyLLM::Contract::Step::Base) do
        prompt { user "{input}" }
      end

      step.define_eval("smoke") do
        default_input "test"
        sample_response({ v: 1 })
      end

      # No baseline file → without_regressions is a no-op
      expect(step).to pass_eval("smoke").without_regressions
    end
  end
end
