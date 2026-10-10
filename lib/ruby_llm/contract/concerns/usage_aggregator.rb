# frozen_string_literal: true

module RubyLLM
  module Contract
    module Concerns
      module UsageAggregator
        # Breakdown keys an adapter may add next to input/output. They are parts
        # of input_tokens/output_tokens, not extra tokens, so sum_tokens skips them.
        USAGE_DETAIL_KEYS = %i[cache_read_tokens cache_write_tokens thinking_tokens].freeze

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
          totals = Hash.new(0)

          traces.each do |trace_entry|
            usage = extract_usage(trace_entry)
            next unless usage.is_a?(Hash)

            [:input_tokens, :output_tokens, *USAGE_DETAIL_KEYS].each { |key| totals[key] += usage[key] || 0 }
          end

          { input_tokens: totals[:input_tokens], output_tokens: totals[:output_tokens] }
            .merge(totals.slice(*USAGE_DETAIL_KEYS).select { |_, count| count.positive? })
        end
      end
    end
  end
end
