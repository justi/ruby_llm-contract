# frozen_string_literal: true

module RubyLLM
  module Contract
    # Pre-flight token estimation for `max_input` / `max_cost` budget gating.
    #
    # IMPORTANT — heuristic only. This is NOT an accurate tokenizer.
    # The estimate uses a fixed `length / CHARS_PER_TOKEN` ratio:
    #
    #   - Accurate to ±30% for English prose with mainstream OpenAI / Anthropic models
    #   - Worse for non-English text, code, structured data, and unusual scripts
    #   - Useless for models with very different tokenizers (e.g. some open-source models)
    #
    # RubyLLM 1.14 ships no pre-flight tokenizer either; once the API call
    # returns, `RubyLLM::Tokens` provides accurate counts from provider usage
    # data. This estimator is for the *pre-flight refusal* path only — its job
    # is to answer "is this call almost certainly within budget?" with enough
    # accuracy that runaway prompts get caught, while accepting that the
    # boundary cases will be wrong.
    #
    # Refusal messages from `LimitChecker` carry an "(heuristic)" suffix so
    # adopters know the number is estimated, not measured.
    module TokenEstimator
      CHARS_PER_TOKEN = 4

      # Heuristic estimate. Returns an integer token count.
      # See module docstring for accuracy caveats.
      def self.estimate(messages)
        return 0 unless messages.is_a?(Array)

        total_chars = messages.sum { |m| m[:content].to_s.length }
        (total_chars.to_f / CHARS_PER_TOKEN).ceil
      end
    end
  end
end
