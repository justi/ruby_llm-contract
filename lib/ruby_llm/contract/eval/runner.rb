# frozen_string_literal: true

module RubyLLM
  module Contract
    module Eval
      class Runner
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
          Report.new(
            dataset_name: @dataset.name,
            results: collected_results,
            step_name: step_name
          )
        end

        private

        def collected_results
          concurrent? ? run_concurrent : run_serial
        end

        def run_serial
          @dataset.cases.map { |test_case| case_executor.call(test_case: test_case, context: @context) }
        end

        def concurrent?
          @concurrency && @concurrency > 1
        end

        def step_name
          @step.respond_to?(:name) ? @step.name : @step.to_s
        end

        def case_executor
          @case_executor ||= CaseExecutor.new(step: @step)
        end

        def run_concurrent
          require "concurrent"
          pool = Concurrent::FixedThreadPool.new(@concurrency)

          # Pre-build per-case contexts: if adapter has responses:, each case
          # gets a single-response adapter with its own response (by index).
          per_case_contexts = build_per_case_contexts

          futures = @dataset.cases.each_with_index.map do |test_case, index|
            case_context = per_case_contexts[index]
            Concurrent::Future.execute(executor: pool) do
              case_executor.call(test_case: test_case, context: case_context)
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

          @dataset.cases.each_with_index.map do |_, index|
            if responses
              # Give each case its own single-response adapter
              response = responses[index] || responses.last
              per_case_adapter = Adapters::Test.new(response: response)
              @context.merge(adapter: per_case_adapter)
            else
              isolate_context(@context)
            end
          end
        end
      end
    end
  end
end
