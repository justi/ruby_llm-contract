# frozen_string_literal: true

module RubyLLM
  module Contract
    module Eval
      class Runner
        include TraitEvaluator
        include ContractDetailBuilder

        def self.run(step:, dataset:, context: {})
          new(step: step, dataset: dataset, context: context).run
        end

        def initialize(step:, dataset:, context: {})
          @step = step
          @dataset = dataset
          @context = context
        end

        def run
          results = @dataset.cases.map { |test_case| evaluate_case(test_case) }
          Report.new(dataset_name: @dataset.name, results: results)
        end

        private

        def evaluate_case(test_case)
          run_result = @step.run(test_case.input, context: @context)
          step_result = normalize_result(run_result)
          eval_result = dispatch_evaluation(step_result, test_case)

          build_case_result(test_case, step_result, eval_result)
        end

        def build_case_result(test_case, step_result, eval_result)
          CaseResult.new(
            name: test_case.name,
            input: test_case.input,
            output: step_result.parsed_output,
            expected: test_case.expected,
            step_status: step_result.status,
            score: eval_result.score,
            passed: eval_result.passed,
            label: eval_result.label,
            details: eval_result.details,
            duration_ms: step_result.respond_to?(:trace) ? step_result.trace[:latency_ms] : nil
          )
        end

        def dispatch_evaluation(step_result, test_case)
          return contract_failure(step_result) unless step_result.ok?

          if test_case.evaluator
            evaluate_with_custom(step_result, test_case)
          elsif test_case.expected_traits
            evaluate_traits(step_result, test_case)
          elsif test_case.expected
            evaluate_expected(step_result, test_case)
          else
            evaluate_contract_only
          end
        end

        def normalize_result(result)
          return result if result.respond_to?(:parsed_output)

          normalize_pipeline_result(result)
        end

        def normalize_pipeline_result(result)
          last_result = result.step_results&.last&.dig(:result)
          is_ok = result.ok?

          PipelineResultAdapter.new(
            status: result.status,
            ok_flag: is_ok,
            parsed_output: is_ok ? result.outputs_by_step.values.last : nil,
            validation_errors: last_result.respond_to?(:validation_errors) ? last_result.validation_errors : [],
            trace: last_result.respond_to?(:trace) ? last_result.trace : {}
          )
        end

        def evaluate_expected(step_result, test_case)
          dispatch_expected_evaluator(
            output: step_result.parsed_output,
            expected: test_case.expected,
            input: test_case.input
          )
        end

        def dispatch_expected_evaluator(output:, expected:, input:)
          if expected.is_a?(Hash)
            Evaluator::JsonIncludes.new.call(output: output, expected: expected, input: input)
          elsif expected.is_a?(::Regexp)
            Evaluator::Regex.new(expected).call(output: output, input: input)
          else
            Evaluator::Exact.new.call(output: output, expected: expected, input: input)
          end
        end

        def evaluate_with_custom(step_result, test_case)
          evaluator = test_case.evaluator
          evaluator = Evaluator::ProcEvaluator.new(evaluator) if evaluator.is_a?(::Proc)
          evaluator.call(output: step_result.parsed_output, expected: test_case.expected, input: test_case.input)
        end

        def evaluate_contract_only
          EvaluationResult.new(score: 1.0, passed: true, details: build_contract_details)
        end

        def contract_failure(step_result)
          EvaluationResult.new(
            score: 0.0, passed: false,
            details: "step failed: #{step_result.status} — #{step_result.validation_errors.join(", ")}"
          )
        end
      end
    end
  end
end
