# frozen_string_literal: true

module RubyLLM
  module Contract
    module Eval
      class CaseResultBuilder
        def call(test_case:, step_result:, evaluation:)
          trace = step_result.respond_to?(:trace) ? step_result.trace : nil

          CaseResult.new(
            name: test_case.name,
            input: test_case.input,
            output: step_result.parsed_output,
            expected: test_case.expected,
            step_status: step_result.status,
            score: evaluation.score,
            passed: evaluation.passed,
            label: evaluation.label,
            details: evaluation.details,
            duration_ms: trace_metric(trace, :total_latency_ms, :latency_ms),
            cost: trace_metric(trace, :total_cost, :cost),
            attempts: trace_attempts(trace)
          )
        end

        private

        def trace_metric(trace, pipeline_key, step_key)
          return nil unless trace

          trace.respond_to?(pipeline_key) ? trace.public_send(pipeline_key) : trace[step_key]
        end

        def trace_attempts(trace)
          return nil unless trace

          trace.respond_to?(:attempts) ? trace.attempts : nil
        end
      end
    end
  end
end
