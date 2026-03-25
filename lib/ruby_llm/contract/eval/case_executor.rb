# frozen_string_literal: true

module RubyLLM
  module Contract
    module Eval
      class CaseExecutor
        def initialize(step:, scorer: nil, normalizer: StepResultNormalizer.new,
                       result_builder: CaseResultBuilder.new,
                       step_expectation_applier: StepExpectationApplier.new)
          @step = step
          @scorer = scorer || CaseScorer.new(step: step)
          @normalizer = normalizer
          @result_builder = result_builder
          @step_expectation_applier = step_expectation_applier
        end

        def call(test_case:, context:)
          run_result = @step.run(test_case.input, context: context)
          step_result = @normalizer.call(run_result)
          evaluation = @scorer.call(test_case: test_case, step_result: step_result)
          result = @result_builder.call(test_case: test_case, step_result: step_result, evaluation: evaluation)

          @step_expectation_applier.call(result: result, run_result: run_result, test_case: test_case)
        rescue RubyLLM::Contract::Error => error
          raise unless missing_adapter?(error)

          skipped_result(test_case, error.message)
        end

        private

        def missing_adapter?(error)
          error.message.include?("No adapter configured")
        end

        def skipped_result(test_case, reason)
          CaseResult.new(
            name: test_case.name,
            input: test_case.input,
            output: nil,
            expected: test_case.expected,
            step_status: :skipped,
            score: 0.0,
            passed: false,
            label: "SKIP",
            details: "skipped: #{reason}"
          )
        end
      end
    end
  end
end
