# frozen_string_literal: true

module RubyLLM
  module Contract
    module Eval
      class StepExpectationApplier
        def initialize(expectation_evaluator: ExpectationEvaluator.new)
          @expectation_evaluator = expectation_evaluator
        end

        def call(result:, run_result:, test_case:)
          return result unless applicable?(test_case, run_result)

          expectation_results = evaluate_expectations(run_result.outputs_by_step, test_case.step_expectations)
          return result if expectation_results.values.all? { |entry| entry[:passed] }

          rebuild_result(result, failure_details_for(expectation_results))
        end

        private

        def applicable?(test_case, run_result)
          test_case.respond_to?(:step_expectations) &&
            test_case.step_expectations &&
            run_result.respond_to?(:outputs_by_step)
        end

        def evaluate_expectations(outputs_by_step, expectations)
          expectations.each_with_object({}) do |(step_alias, expected), results|
            output = outputs_by_step[step_alias]
            results[step_alias] = evaluate_single_expectation(output, expected)
          end
        end

        def evaluate_single_expectation(output, expected)
          return { passed: false, details: "step not executed" } if output.nil?

          evaluation = @expectation_evaluator.call(output: output, expected: expected, input: nil)
          { passed: evaluation.passed, details: evaluation.details }
        end

        def failure_details_for(expectation_results)
          expectation_results
            .select { |_, entry| !entry[:passed] }
            .map { |step_alias, entry| "#{step_alias}: #{entry[:details]}" }
            .join("; ")
        end

        def rebuild_result(result, failure_details)
          CaseResult.new(
            name: result.name,
            input: result.input,
            output: result.output,
            expected: result.expected,
            step_status: :step_expectation_failed,
            score: 0.0,
            passed: false,
            label: "FAIL",
            details: "step expectations failed: #{failure_details}",
            duration_ms: result.duration_ms,
            cost: result.cost
          )
        end
      end
    end
  end
end
