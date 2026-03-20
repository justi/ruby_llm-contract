# frozen_string_literal: true

module RubyLLM
  module Contract
    module Eval
      module Evaluator
        class Exact
          def call(output:, expected:, input: nil) # rubocop:disable Lint/UnusedMethodArgument
            if output == expected
              EvaluationResult.new(score: 1.0, passed: true, details: "exact match")
            else
              EvaluationResult.new(score: 0.0, passed: false,
                                   details: "expected #{expected.inspect}, got #{output.inspect}")
            end
          end
        end
      end
    end
  end
end
