# frozen_string_literal: true

module RubyLLM
  module Contract
    class RakeTask < ::Rake::TaskLib
      # Gate ordering (preserved from pre-refactor behaviour):
      #   1. cost gate runs FIRST — if `maximum_cost` set and exceeded, or any
      #      case has unknown cost under on_unknown_pricing :refuse, the suite
      #      aborts before any score check; passed_reports is empty.
      #   2. score gate runs per-report; a report passes if
      #      `report_meets_score?` AND `!check_regression`.
      #   3. overall passed = ALL reports passed AND cost gate not tripped.
      class SuiteGate
        Verdict = Data.define(:passed, :abort_reason, :passed_reports, :suite_cost) do
          def passed?
            passed
          end
        end

        def self.evaluate(host_reports:, minimum_score:, maximum_cost:, fail_on_regression:,
                          on_unknown_pricing: :refuse)
          new(host_reports: host_reports,
              minimum_score: minimum_score,
              maximum_cost: maximum_cost,
              fail_on_regression: fail_on_regression,
              on_unknown_pricing: on_unknown_pricing).verdict
        end

        attr_reader :verdict

        def initialize(host_reports:, minimum_score:, maximum_cost:, fail_on_regression:,
                       on_unknown_pricing: :refuse)
          @host_reports = host_reports
          @minimum_score = minimum_score
          @maximum_cost = maximum_cost
          @fail_on_regression = fail_on_regression
          @on_unknown_pricing = Eval::UnknownCostGate.validate!(on_unknown_pricing)
          @verdict = build_verdict
        end

        private

        def build_verdict
          suite_cost = compute_suite_cost
          cost_failure = cost_failure_message(suite_cost)

          if cost_failure
            return Verdict.new(
              passed: false,
              abort_reason: cost_failure,
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

        def cost_failure_message(suite_cost)
          return nil unless @maximum_cost
          return cost_abort_message(suite_cost) if suite_cost > @maximum_cost

          Eval::UnknownCostGate.check(@host_reports.map(&:last), mode: @on_unknown_pricing)
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
