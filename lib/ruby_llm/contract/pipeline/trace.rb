# frozen_string_literal: true

module RubyLLM
  module Contract
    module Pipeline
      class Trace
        include Concerns::TraceEquality

        attr_reader :trace_id, :total_latency_ms, :total_usage, :step_traces, :total_cost

        def initialize(trace_id: nil, total_latency_ms: nil, total_usage: nil, step_traces: nil)
          @trace_id = trace_id
          @total_latency_ms = total_latency_ms
          @total_usage = total_usage
          @step_traces = step_traces
          @total_cost = calculate_total_cost
          freeze
        end

        KNOWN_KEYS = %i[trace_id total_latency_ms total_usage step_traces total_cost].freeze

        def [](key)
          return nil unless KNOWN_KEYS.include?(key.to_sym)

          public_send(key)
        end

        def dig(key, *rest)
          value = self[key]
          return value if rest.empty? || value.nil?

          value.dig(*rest)
        end

        def to_h
          { trace_id: @trace_id, total_latency_ms: @total_latency_ms,
            total_usage: @total_usage, step_traces: @step_traces,
            total_cost: @total_cost }.compact
        end

        def to_s
          build_summary_parts.join(" ")
        end

        private

        def build_summary_parts
          parts = ["trace=#{@trace_id&.slice(0, 8)}"]
          parts << "#{@total_latency_ms}ms" if @total_latency_ms
          parts << format_token_usage if @total_usage.is_a?(Hash)
          parts << "$#{format("%.6f", @total_cost)}" if @total_cost
          parts << "(#{step_count} steps)"
          parts
        end

        def format_token_usage
          "#{@total_usage[:input_tokens] || 0}+#{@total_usage[:output_tokens] || 0} tokens"
        end

        def step_count
          @step_traces.is_a?(Array) ? @step_traces.size : 0
        end

        def calculate_total_cost
          return nil unless @step_traces.is_a?(Array)

          costs = collect_step_costs
          return nil if costs.empty?

          costs.sum.round(6)
        end

        def collect_step_costs
          @step_traces.filter_map { |step_trace| step_trace.respond_to?(:cost) ? step_trace.cost : nil }
        end
      end
    end
  end
end
