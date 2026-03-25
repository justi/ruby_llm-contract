# frozen_string_literal: true

module RubyLLM
  module Contract
    module Eval
      module Evaluator
        # Compares output to expected using Ruby equality semantics.
        class Exact
          def call(output:, expected:, input: nil) # rubocop:disable Lint/UnusedMethodArgument
            return EvaluationResult.new(score: 1.0, passed: true, details: "exact match") if output == expected

            EvaluationResult.new(
              score: 0.0,
              passed: false,
              details: "expected #{expected.inspect}, got #{output.inspect}"
            )
          end
        end
      end
    end
  end
end
