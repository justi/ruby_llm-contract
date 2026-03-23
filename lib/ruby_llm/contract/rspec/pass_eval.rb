# frozen_string_literal: true

module RubyLLM
  module Contract
    module RSpec
      # Helper methods for the pass_eval matcher to keep the block short.
      module PassEvalHelpers
        def format_failure_message(eval_name, error, report, minimum_score, maximum_cost)
          return format_error_message(eval_name, error) if error

          format_report_message(eval_name, report, minimum_score, maximum_cost)
        end

        def format_error_message(eval_name, error)
          "expected #{eval_name} eval to pass, but it raised an error:\n  #{error.class}: #{error.message}"
        end

        def format_report_message(eval_name, report, minimum_score, maximum_cost)
          lines = build_header(eval_name, report, minimum_score, maximum_cost)
          lines << ""

          report.results.each do |result|
            cost_str = result.cost ? " $#{format("%.4f", result.cost)}" : ""
            lines << "  #{result.label}  #{result.name} (score: #{result.score})#{cost_str}"
            lines << "        #{result.details}" if result.details && result.failed?
          end

          lines.join("\n")
        end

        private

        def build_header(eval_name, report, minimum_score, maximum_cost)
          cost_str = report.total_cost.positive? ? ", cost: $#{format("%.4f", report.total_cost)}" : ""

          if maximum_cost && report.total_cost > maximum_cost
            ["expected #{eval_name} eval cost <= $#{format("%.4f", maximum_cost)}, " \
             "but got: $#{format("%.4f", report.total_cost)} (#{report.pass_rate})"]
          elsif minimum_score
            ["expected #{eval_name} eval score >= #{minimum_score}, " \
             "but got: #{report.score.round(2)} (#{report.pass_rate}#{cost_str})"]
          else
            ["expected #{eval_name} eval to pass, " \
             "but got score: #{report.score.round(2)} (#{report.pass_rate}#{cost_str})"]
          end
        end
      end
    end
  end
end

RSpec::Matchers.define :pass_eval do |eval_name|
  include RubyLLM::Contract::RSpec::PassEvalHelpers

  chain :with_context do |ctx|
    @context = ctx
  end

  chain :with_minimum_score do |score|
    @minimum_score = score
  end

  chain :with_maximum_cost do |cost|
    @maximum_cost = cost
  end

  chain :without_regressions do
    @check_regressions = true
  end

  match do |step_or_pipeline|
    @eval_name = eval_name
    @context ||= {}
    @minimum_score ||= nil
    @maximum_cost ||= nil
    @check_regressions ||= false
    @error = nil
    @diff = nil
    @report = step_or_pipeline.run_eval(eval_name, context: @context)

    score_ok = if @minimum_score
                 @report.score >= @minimum_score
               else
                 @report.passed?
               end

    cost_ok = @maximum_cost ? @report.total_cost <= @maximum_cost : true

    regression_ok = if @check_regressions && @report.baseline_exists?
                      @diff = @report.compare_with_baseline
                      !@diff.regressed?
                    else
                      true
                    end

    score_ok && cost_ok && regression_ok
  rescue StandardError => e
    @error = e
    false
  end

  failure_message do
    msg = format_failure_message(@eval_name, @error, @report, @minimum_score, @maximum_cost)
    if @diff&.regressed?
      msg += "\n\nRegressions from baseline:\n"
      @diff.regressions.each do |r|
        msg += "  #{r[:case]}: was PASS, now FAIL — #{r[:detail]}\n"
      end
      msg += "  Score delta: #{@diff.score_delta}"
    end
    msg
  end

  failure_message_when_negated do
    "expected #{@eval_name} eval NOT to pass, but it passed with score: #{@report.score.round(2)}"
  end
end
