# frozen_string_literal: true

module RubyLLM
  module Contract
    class RakeTask < ::Rake::TaskLib
      # Encapsulates the pass/fail gate that runs after `RakeTask#define_task`
      # has collected eval reports. Extracted from the prior `define_task`
      # god-method so each gating dimension (cost, score, regression) is
      # testable in isolation.
      #
      # Returns a `Verdict` value object with:
      #   - `passed?`         — overall gate verdict
      #   - `abort_reason`    — String for `abort` when `passed? == false`, nil otherwise
      #   - `passed_reports`  — [[host, report], ...] of reports that individually passed
      #                         (used to decide which baselines to save)
      #   - `suite_cost`      — total cost across all reports
      #
      # Gate ordering (preserved from pre-refactor behaviour):
      #   1. cost gate runs FIRST — if `maximum_cost` set and exceeded, the
      #      suite aborts before any score check; passed_reports is empty.
      #   2. score gate runs per-report; a report passes if
      #      `report_meets_score?` AND `!check_regression`.
      #   3. overall passed = ALL reports passed AND cost gate not tripped.
      class SuiteGate
        Verdict = Data.define(:passed, :abort_reason, :passed_reports, :suite_cost) do
          def passed?
            passed
          end
        end

        def self.evaluate(host_reports:, minimum_score:, maximum_cost:, fail_on_regression:)
          new(host_reports: host_reports,
              minimum_score: minimum_score,
              maximum_cost: maximum_cost,
              fail_on_regression: fail_on_regression).verdict
        end

        attr_reader :verdict

        def initialize(host_reports:, minimum_score:, maximum_cost:, fail_on_regression:)
          @host_reports = host_reports
          @minimum_score = minimum_score
          @maximum_cost = maximum_cost
          @fail_on_regression = fail_on_regression
          @verdict = build_verdict
        end

        private

        def build_verdict
          suite_cost = compute_suite_cost

          if cost_exceeded?(suite_cost)
            return Verdict.new(
              passed: false,
              abort_reason: cost_abort_message(suite_cost),
              passed_reports: [],
              suite_cost: suite_cost
            )
          end

          passed_reports, all_passed = score_each_report
          Verdict.new(
            passed: all_passed,
            abort_reason: all_passed ? nil : "Eval suite FAILED",
            passed_reports: passed_reports,
            suite_cost: suite_cost
          )
        end

        def compute_suite_cost
          @host_reports.sum { |_host, report| report.total_cost }
        end

        def cost_exceeded?(suite_cost)
          @maximum_cost && suite_cost > @maximum_cost
        end

        def cost_abort_message(suite_cost)
          "total cost $#{format("%.4f", suite_cost)} exceeds budget $#{format("%.4f", @maximum_cost)}"
        end

        def score_each_report
          passed_reports = []
          all_passed = true
          @host_reports.each do |host, report|
            report_ok = report_meets_score?(report) && !check_regression(report)
            all_passed = false unless report_ok
            passed_reports << [host, report] if report_ok
          end
          [passed_reports, all_passed]
        end

        def report_meets_score?(report)
          if @minimum_score
            report.score >= @minimum_score
          else
            report.passed?
          end
        end

        def check_regression(report)
          return false unless @fail_on_regression && report.baseline_exists?

          diff = report.compare_with_baseline
          if diff.regressed?
            puts "\n  REGRESSIONS DETECTED:"
            puts "  #{diff}"
            true
          else
            false
          end
        end
      end
    end
  end
end
