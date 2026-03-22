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
        rescue RubyLLM::Contract::Error => e
          # No adapter configured — skip this case (offline mode without sample_response)
          skipped_result(test_case, e.message)
        end

        def build_case_result(test_case, step_result, eval_result)
          trace = step_result.respond_to?(:trace) ? step_result.trace : nil
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
            duration_ms: extract_latency(trace),
            cost: extract_cost(trace)
          )
        end

        def extract_latency(trace)
          return nil unless trace

          # Pipeline::Trace uses total_latency_ms, Step::Trace uses latency_ms
          trace.respond_to?(:total_latency_ms) ? trace.total_latency_ms : trace[:latency_ms]
        end

        def extract_cost(trace)
          return nil unless trace

          # Pipeline::Trace uses total_cost, Step::Trace uses cost
          trace.respond_to?(:total_cost) && trace.total_cost ? trace.total_cost : trace[:cost]
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
          pipeline_trace = result.respond_to?(:trace) ? result.trace : nil

          PipelineResultAdapter.new(
            status: result.status,
            ok_flag: is_ok,
            parsed_output: is_ok ? result.outputs_by_step.values.last : nil,
            validation_errors: last_result.respond_to?(:validation_errors) ? last_result.validation_errors : [],
            trace: pipeline_trace || (last_result.respond_to?(:trace) ? last_result.trace : {})
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
