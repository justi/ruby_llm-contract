# frozen_string_literal: true

module RubyLLM
  module Contract
    module Step
      module RetryExecutor
        include Concerns::UsageAggregator

        # Copied from each attempt's trace into its attempts entry when present.
        ATTEMPT_TRACE_FIELDS = %i[usage latency_ms cost finish_reason error_class].freeze

        private

        def run_with_retry(input, adapter:, default_model:, policy:, context_temperature: nil, extra_options: {})
          all_attempts = []
          default_config = { model: default_model }.merge(extra_options.slice(:reasoning_effort).compact)

          policy.max_attempts.times do |attempt_index|
            config = policy.config_for_attempt(attempt_index, default_config)
            model = config[:model]
            attempt_extra = RubyLLM::Contract.without_default_effort(extra_options.merge(config.except(:model)))

            result = run_once(input, adapter: adapter, model: model,
                              context_temperature: context_temperature, extra_options: attempt_extra)
            all_attempts << { attempt: attempt_index + 1, model: model, config: sent_config(model, attempt_extra),
                              result: result }
            break unless policy.retryable?(result)
          end

          build_retry_result(all_attempts)
        end

        def build_retry_result(all_attempts)
          last = all_attempts.last[:result]
          attempt_log = all_attempts.map { |attempt| build_attempt_entry(attempt) }
          aggregated_usage = aggregate_usage(all_attempts.map { |a| a[:result].trace })
          total_cost = sum_attempt_costs(all_attempts)
          total_latency = sum_attempt_latency(all_attempts)

          Result.new(
            status: last.status, raw_output: last.raw_output,
            parsed_output: last.parsed_output, validation_errors: last.validation_errors,
            observations: last.observations,
            trace: last.trace.merge(
              attempts: attempt_log, usage: aggregated_usage,
              cost: total_cost, latency_ms: total_latency,
              usage_complete: aggregate_flag(all_attempts, :usage_complete),
              cost_complete: aggregate_cost_complete(all_attempts)
            )
          )
        end

        # What the attempt was sent, not the chain element it came from: an
        # element without an effort still gets the class or context one
        # (runtime_settings copies the class effort into :reasoning_effort).
        def sent_config(model, options)
          effort = options[:reasoning_effort]
          effort ? { model: model, reasoning_effort: effort } : { model: model }
        end

        def build_attempt_entry(attempt)
          trace = attempt[:result].trace
          entry = { attempt: attempt[:attempt], model: attempt[:model], status: attempt[:result].status }
          config = attempt[:config]
          entry[:config] = config if config && config.keys != [:model]
          append_trace_fields(entry, trace)
        end

        def append_trace_fields(entry, trace)
          ATTEMPT_TRACE_FIELDS.each do |field|
            value = trace_value(trace, field)
            entry[field] = value if value
          end
          entry[:cost_unknown] = true if trace_value(trace, :cost_unknown?)
          entry[:usage_complete] = false if trace_value(trace, :usage_complete) == false
          entry
        end

        def trace_value(trace, method)
          trace.public_send(method) if trace.respond_to?(method)
        end

        # The subtotal is complete only if every attempt was; the last attempt's
        # flag must not speak for it. nil when no attempt reported accounting
        # state, so a retried Test-adapter step serializes exactly as before.
        def aggregate_cost_complete(all_attempts)
          traces = all_attempts.map { |a| a[:result].trace }
          return false if traces.any? { |trace| trace.respond_to?(:cost_unknown?) && trace.cost_unknown? }

          aggregate_flag(all_attempts, :cost_complete)
        end

        def aggregate_flag(all_attempts, flag)
          flags = all_attempts.map { |a| a[:result].trace }
                              .select { |trace| trace.respond_to?(flag) }
                              .map { |trace| trace.public_send(flag) }.compact
          return nil if flags.empty?

          flags.all?
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

        # `aggregate_usage(traces)` provided by Concerns::UsageAggregator —
        # replaces the prior `aggregate_retry_usage` private helper which
        # duplicated the same per-trace input/output token sum.
      end
    end
  end
end
