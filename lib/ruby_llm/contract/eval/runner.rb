# frozen_string_literal: true

module RubyLLM
  module Contract
    module Eval
      class Runner
        include TraitEvaluator
        include ContractDetailBuilder
        include Concerns::ContextHelpers

        def self.run(step:, dataset:, context: {}, concurrency: nil)
          new(step: step, dataset: dataset, context: context, concurrency: concurrency).run
        end

        def initialize(step:, dataset:, context: {}, concurrency: nil)
          @step = step
          @dataset = dataset
          @context = context
          @concurrency = concurrency
        end

        def run
          results = if @concurrency && @concurrency > 1
                      run_concurrent
                    else
                      @dataset.cases.map { |test_case| evaluate_case(test_case) }
                    end
          step_name = @step.respond_to?(:name) ? @step.name : @step.to_s
          Report.new(dataset_name: @dataset.name, results: results, step_name: step_name)
        end

        private

        def run_concurrent
          require "concurrent"
          pool = Concurrent::FixedThreadPool.new(@concurrency)

          # Pre-build per-case contexts: if adapter has responses:, each case
          # gets a single-response adapter with its own response (by index).
          per_case_contexts = build_per_case_contexts

          futures = @dataset.cases.each_with_index.map do |test_case, i|
            ctx = per_case_contexts[i]
            Concurrent::Future.execute(executor: pool) do
              evaluate_case_with_context(test_case, ctx)
            end
          end
          futures.map(&:value!)
        ensure
          pool&.shutdown
          pool&.wait_for_termination(5)
        end

        def build_per_case_contexts
          adapter = @context[:adapter]
          responses = adapter.respond_to?(:responses_array) ? adapter.responses_array : nil

          @dataset.cases.each_with_index.map do |_, i|
            if responses
              # Give each case its own single-response adapter
              response = responses[i] || responses.last
              per_case_adapter = Adapters::Test.new(response: response)
              @context.merge(adapter: per_case_adapter)
            else
              isolate_context(@context)
            end
          end
        end

        def evaluate_case_with_context(test_case, context)
          run_result = @step.run(test_case.input, context: context)
          step_result = normalize_result(run_result)
          eval_result = dispatch_evaluation(step_result, test_case)

          result = build_case_result(test_case, step_result, eval_result)

          if test_case.respond_to?(:step_expectations) && test_case.step_expectations &&
             run_result.respond_to?(:outputs_by_step)
            evaluate_step_expectations(result, run_result.outputs_by_step, test_case.step_expectations)
          else
            result
          end
        rescue RubyLLM::Contract::Error => e
          raise unless e.message.include?("No adapter configured")

          skipped_result(test_case, e.message)
        end

        def evaluate_case(test_case)
          run_result = @step.run(test_case.input, context: @context)
          step_result = normalize_result(run_result)
          eval_result = dispatch_evaluation(step_result, test_case)

          result = build_case_result(test_case, step_result, eval_result)

          # Pipeline per-step evaluation
          if test_case.respond_to?(:step_expectations) && test_case.step_expectations &&
             run_result.respond_to?(:outputs_by_step)
            evaluate_step_expectations(result, run_result.outputs_by_step, test_case.step_expectations)
          else
            result
          end
        rescue RubyLLM::Contract::Error => e
          raise unless e.message.include?("No adapter configured")

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
          if trace.respond_to?(:total_latency_ms)
            trace.total_latency_ms
          else
            trace[:latency_ms]
          end
        end

        def extract_cost(trace)
          return nil unless trace

          # Pipeline::Trace uses total_cost, Step::Trace uses cost
          if trace.respond_to?(:total_cost)
            trace.total_cost
          else
            trace[:cost]
          end
        end

        def dispatch_evaluation(step_result, test_case)
          return contract_failure(step_result) unless step_result.ok?

          if test_case.evaluator
            evaluate_with_custom(step_result, test_case)
          elsif test_case.expected_traits
            evaluate_traits(step_result, test_case)
          elsif !test_case.expected.nil?
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

        def evaluate_step_expectations(result, outputs_by_step, expectations)
          step_results = {}
          all_passed = true

          expectations.each do |step_alias, expected|
            output = outputs_by_step[step_alias]
            if output.nil?
              step_results[step_alias] = { passed: false, details: "step not executed" }
              all_passed = false
            else
              eval_res = dispatch_expected_evaluator(output: output, expected: expected, input: nil)
              step_results[step_alias] = { passed: eval_res.passed, score: eval_res.score, details: eval_res.details }
              all_passed = false unless eval_res.passed
            end
          end

          # Rebuild CaseResult with step_results metadata
          failed_steps = step_results.select { |_, v| !v[:passed] }
          failure_details = failed_steps.map { |k, v| "#{k}: #{v[:details]}" }.join("; ")

          CaseResult.new(
            name: result.name, input: result.input, output: result.output,
            expected: result.expected,
            step_status: all_passed ? result.step_status : :step_expectation_failed,
            score: all_passed ? result.score : 0.0,
            passed: result.passed? && all_passed,
            label: all_passed ? result.label : "FAIL",
            details: all_passed ? result.details : "step expectations failed: #{failure_details}",
            duration_ms: result.duration_ms, cost: result.cost
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
