# frozen_string_literal: true

require "securerandom"

module RubyLLM
  module Contract
    module Pipeline
      class Runner
        include Concerns::UsageAggregator

        def initialize(steps:, context:, timeout_ms: nil, token_budget: nil)
          raise ArgumentError, "timeout_ms must be positive (got #{timeout_ms})" if timeout_ms && timeout_ms <= 0
          raise ArgumentError, "Pipeline has no steps defined" if steps.empty?

          @steps = steps
          @context = context || {}
          @timeout_ms = timeout_ms
          @token_budget = token_budget
        end

        def call(input)
          execution = ExecutionState.new(input)
          start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          run_steps(execution, start_time)
          finalize_result(execution, start_time)
        end

        def run_steps(execution, start_time)
          @steps.each_with_index do |step_def, index|
            execute_step(step_def, execution)
            break if execution.failed?
            break if check_limits(index, step_def, execution, start_time)
          end
        end

        private

        def execute_step(step_def, execution)
          step_context = build_step_context(step_def)
          result = step_def[:step_class].run(execution.current_input, context: step_context)

          execution.record_step(step_def[:alias], result)
        end

        def build_step_context(step_def)
          model = step_def[:model]
          model ? @context.merge(model: model) : @context
        end

        def check_limits(index, step_def, execution, start_time)
          limit_status = detect_limit_violation(execution, start_time)
          return unless limit_status

          failing_alias = next_step_alias(index, step_def)
          execution.mark_limit_failure(limit_status, failing_alias)
          true
        end

        # NOTE: This is a cooperative timeout, not a hard deadline. The timeout is
        # checked between steps, after each step completes. A slow step (e.g. long
        # LLM call or multi-attempt retry) can exceed the deadline before the check
        # runs. This is a known architectural limitation -- safely interrupting a
        # running HTTP call in Ruby requires threads/fibers, which adds significant
        # complexity. For most pipelines this cooperative approach is sufficient;
        # set timeout_ms with enough headroom for your slowest expected step.
        def detect_limit_violation(execution, start_time)
          if @timeout_ms && elapsed_ms(start_time) >= @timeout_ms
            :timeout
          elsif @token_budget && sum_tokens(execution.step_traces) > @token_budget
            :budget_exceeded
          end
        end

        def next_step_alias(index, step_def)
          @steps[index + 1]&.dig(:alias) || step_def[:alias]
        end

        def finalize_result(execution, start_time)
          traces = execution.step_traces
          trace = Trace.new(
            trace_id: execution.trace_id,
            total_latency_ms: elapsed_ms(start_time),
            total_usage: aggregate_usage(traces),
            step_traces: traces
          )

          Result.new(
            status: execution.status, step_results: execution.step_results,
            outputs_by_step: execution.outputs_by_step, failed_step: execution.failed_step,
            trace: trace
          )
        end

        def elapsed_ms(start_time)
          ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time) * 1000).round
        end

        # Encapsulates mutable state during pipeline execution
        class ExecutionState
          attr_reader :trace_id, :step_results, :step_traces, :outputs_by_step,
                      :current_input, :status, :failed_step

          def initialize(input)
            @trace_id = SecureRandom.uuid
            @step_results = []
            @step_traces = []
            @outputs_by_step = {}
            @current_input = input
            @status = :ok
            @failed_step = nil
          end

          def record_step(step_alias, result)
            @step_results << { alias: step_alias, result: result }
            @step_traces << result.trace

            if result.ok?
              output = result.parsed_output
              @outputs_by_step[step_alias] = output
              @current_input = output
            else
              @status = result.status
              @failed_step = step_alias
            end
          end

          def mark_limit_failure(status, failed_alias)
            @status = status
            @failed_step = failed_alias
          end

          def failed?
            @status != :ok
          end
        end
      end
    end
  end
end
