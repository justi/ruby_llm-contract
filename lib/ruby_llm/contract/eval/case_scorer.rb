# frozen_string_literal: true

module RubyLLM
  module Contract
    module Eval
      class CaseScorer
        include TraitEvaluator
        include ContractDetailBuilder

        def initialize(step:, expectation_evaluator: ExpectationEvaluator.new)
          @step = step
          @expectation_evaluator = expectation_evaluator
        end

        def call(test_case:, step_result:)
          return contract_failure(step_result) unless step_result.ok?

          if test_case.evaluator
            evaluate_with_custom(test_case, step_result)
          elsif test_case.expected_traits
            evaluate_traits(step_result, test_case)
          elsif !test_case.expected.nil?
            evaluate_expected(test_case, step_result)
          else
            evaluate_contract_only
          end
        end

        private

        def evaluate_expected(test_case, step_result)
          @expectation_evaluator.call(
            output: step_result.parsed_output,
            expected: test_case.expected,
            input: test_case.input
          )
        end

        def evaluate_with_custom(test_case, step_result)
          wrapped_custom_evaluator(test_case).call(
            output: step_result.parsed_output,
            expected: test_case.expected,
            input: test_case.input
          )
        end

        def wrapped_custom_evaluator(test_case)
          evaluator = test_case.evaluator
          evaluator.is_a?(::Proc) ? Evaluator::ProcEvaluator.new(evaluator) : evaluator
        end

        def evaluate_contract_only
          EvaluationResult.new(score: 1.0, passed: true, details: build_contract_details)
        end

        def contract_failure(step_result)
          EvaluationResult.new(
            score: 0.0,
            passed: false,
            details: "step failed: #{step_result.status} — #{step_result.validation_errors.join(", ")}"
          )
        end
      end
    end
  end
end
