# frozen_string_literal: true

module RubyLLM
  module Contract
    module Eval
      module Evaluator
        class Regex
          def initialize(pattern)
            @pattern = pattern.is_a?(::Regexp) ? pattern : ::Regexp.new(pattern)
          end

          def call(output:, expected: nil, input: nil) # rubocop:disable Lint/UnusedMethodArgument
            text = output.is_a?(Hash) ? output.values.join(" ") : output.to_s

            if text.match?(@pattern)
              EvaluationResult.new(score: 1.0, passed: true,
                                   details: "matches #{@pattern.inspect}")
            else
              EvaluationResult.new(score: 0.0, passed: false,
                                   details: "does not match #{@pattern.inspect}")
            end
          end
        end
      end
    end
  end
end
