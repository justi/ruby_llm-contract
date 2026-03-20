# frozen_string_literal: true

module RubyLLM
  module Contract
    module TokenEstimator
      # Heuristic: ~4 characters per token for English text.
      # This is a rough estimate — actual tokenization varies by model and content.
      # Intentionally conservative (overestimates slightly) to avoid surprise costs.
      CHARS_PER_TOKEN = 4

      def self.estimate(messages)
        return 0 unless messages.is_a?(Array)

        total_chars = messages.sum { |m| m[:content].to_s.length }
        (total_chars.to_f / CHARS_PER_TOKEN).ceil
      end
    end
  end
end
