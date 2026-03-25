# frozen_string_literal: true

module RubyLLM
  module Contract
    module Step
      # Extracted from Base to reduce class length.
      # Handles retry logic: run_with_retry, build_retry_result, aggregate usage, build attempt entries.
      module RetryExecutor
        private

        def run_with_retry(input, adapter:, default_model:, policy:, context_temperature: nil, extra_options: {})
          all_attempts = []

          policy.max_attempts.times do |attempt_index|
            model = policy.model_for_attempt(attempt_index, default_model)
            result = run_once(input, adapter: adapter, model: model,
                              context_temperature: context_temperature, extra_options: extra_options)
            all_attempts << { attempt: attempt_index + 1, model: model, result: result }
            break unless policy.retryable?(result)
          end

          build_retry_result(all_attempts)
        end

        def build_retry_result(all_attempts)
          last = all_attempts.last[:result]
          attempt_log = all_attempts.map { |attempt| build_attempt_entry(attempt) }
          aggregated_usage = aggregate_retry_usage(all_attempts)
          total_cost = sum_attempt_costs(all_attempts)
          total_latency = sum_attempt_latency(all_attempts)

          Result.new(
            status: last.status, raw_output: last.raw_output,
            parsed_output: last.parsed_output, validation_errors: last.validation_errors,
            observations: last.observations,
            trace: last.trace.merge(
              attempts: attempt_log, usage: aggregated_usage,
              cost: total_cost, latency_ms: total_latency
            )
          )
        end

        def build_attempt_entry(attempt)
          trace = attempt[:result].trace
          entry = { attempt: attempt[:attempt], model: attempt[:model], status: attempt[:result].status }
          append_trace_fields(entry, trace)
        end

        def append_trace_fields(entry, trace)
          entry[:usage] = trace.usage if trace.respond_to?(:usage) && trace.usage
          entry[:latency_ms] = trace.latency_ms if trace.respond_to?(:latency_ms) && trace.latency_ms
          entry[:cost] = trace.cost if trace.respond_to?(:cost) && trace.cost
          entry
        end

        def sum_attempt_costs(all_attempts)
          costs = extract_trace_values(all_attempts, :cost)
          return nil if costs.empty?

          costs.sum.round(6)
        end

        def sum_attempt_latency(all_attempts)
          latencies = extract_trace_values(all_attempts, :latency_ms)
          return nil if latencies.empty?

          latencies.sum
        end

        def extract_trace_values(all_attempts, method)
          all_attempts.filter_map do |a|
            trace = a[:result].trace
            trace.respond_to?(method) && trace.public_send(method)
          end
        end

        def aggregate_retry_usage(all_attempts)
          totals = { input_tokens: 0, output_tokens: 0 }
          all_attempts.each do |attempt|
            usage = attempt[:result].trace
            usage = usage.respond_to?(:usage) ? usage.usage : nil
            next unless usage.is_a?(Hash)

            totals[:input_tokens] += usage[:input_tokens] || 0
            totals[:output_tokens] += usage[:output_tokens] || 0
          end
          totals
        end
      end
    end
  end
end
