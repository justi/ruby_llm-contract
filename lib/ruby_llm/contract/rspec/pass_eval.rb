# frozen_string_literal: true

module RubyLLM
  module Contract
    module RSpec
      # Helper methods for the pass_eval matcher to keep the block short.
      module PassEvalHelpers
        def format_failure_message(eval_name, error, report, minimum_score)
          return format_error_message(eval_name, error) if error

          format_report_message(eval_name, report, minimum_score)
        end

        def format_error_message(eval_name, error)
          "expected #{eval_name} eval to pass, but it raised an error:\n  #{error.class}: #{error.message}"
        end

        def format_report_message(eval_name, report, minimum_score)
          lines = if minimum_score
                    ["expected #{eval_name} eval score >= #{minimum_score}, but got: #{report.score.round(2)} (#{report.pass_rate})"]
                  else
                    ["expected #{eval_name} eval to pass, but got score: #{report.score.round(2)} (#{report.pass_rate})"]
                  end
          lines << ""

          report.results.each do |result|
            lines << "  #{result.label}  #{result.name} (score: #{result.score})"
            lines << "        #{result.details}" if result.details && result.failed?
          end

          lines.join("\n")
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

  match do |step_or_pipeline|
    @eval_name = eval_name
    @context ||= {}
    @minimum_score ||= nil
    @error = nil
    @report = step_or_pipeline.run_eval(eval_name, context: @context)

    if @minimum_score
      @report.score >= @minimum_score
    else
      @report.passed?
    end
  rescue StandardError => e
    @error = e
    false
  end

  failure_message do
    format_failure_message(@eval_name, @error, @report, @minimum_score)
  end

  failure_message_when_negated do
    "expected #{@eval_name} eval NOT to pass, but it passed with score: #{@report.score.round(2)}"
  end
end
