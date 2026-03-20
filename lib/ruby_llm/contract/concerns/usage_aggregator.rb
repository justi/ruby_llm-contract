# frozen_string_literal: true

module RubyLLM
  module Contract
    module Concerns
      module UsageAggregator
        private

        def extract_usage(trace_entry)
          if trace_entry.respond_to?(:usage)
            trace_entry.usage
          elsif trace_entry.respond_to?(:[])
            trace_entry[:usage]
          end
        end

        def sum_tokens(traces)
          traces.sum do |trace_entry|
            usage = extract_usage(trace_entry)
            next 0 unless usage.is_a?(Hash)

            (usage[:input_tokens] || 0) + (usage[:output_tokens] || 0)
          end
        end

        def aggregate_usage(traces)
          input_total = 0
          output_total = 0

          traces.each do |trace_entry|
            usage = extract_usage(trace_entry)
            next unless usage.is_a?(Hash)

            input_total += usage[:input_tokens] || 0
            output_total += usage[:output_tokens] || 0
          end

          { input_tokens: input_total, output_tokens: output_total }
        end
      end
    end
  end
end
