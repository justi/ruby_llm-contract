# frozen_string_literal: true

module RubyLLM
  module Contract
    module Eval
      class ExpectationEvaluator
        def call(output:, expected:, input:)
          evaluator_for(expected).call(output: output, expected: expected, input: input)
        end

        private

        def evaluator_for(expected)
          case expected
          when Hash
            Evaluator::JsonIncludes.new
          when ::Regexp
            Evaluator::Regex.new(expected)
          else
            Evaluator::Exact.new
          end
        end
      end
    end
  end
end
