# frozen_string_literal: true

module RubyLLM
  module Contract
    module Eval
      module Evaluator
        # Matches a regex against the flattened textual representation of output.
        class Regex
          def initialize(pattern)
            @pattern = pattern.is_a?(::Regexp) ? pattern : ::Regexp.new(pattern)
          end

          def call(output:, expected: nil, input: nil) # rubocop:disable Lint/UnusedMethodArgument
            pattern = @pattern.inspect
            details = text_for(output).match?(@pattern) ? "matches #{pattern}" : "does not match #{pattern}"
            passed = details.start_with?("matches")

            EvaluationResult.new(score: passed ? 1.0 : 0.0, passed: passed, details: details)
          end

          private

          def text_for(output)
            output.is_a?(Hash) ? output.values.join(" ") : output.to_s
          end
        end
      end
    end
  end
end
