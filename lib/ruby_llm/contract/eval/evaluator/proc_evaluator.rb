# frozen_string_literal: true

module RubyLLM
  module Contract
    module Eval
      module Evaluator
        class ProcEvaluator
          def initialize(callable)
            @callable = callable
          end

          def call(output:, expected: nil, input: nil) # rubocop:disable Lint/UnusedMethodArgument,Metrics
            result = if @callable.arity == 2 || (@callable.arity.negative? && @callable.parameters.length >= 2)
                       @callable.call(output, input)
                     else
                       @callable.call(output)
                     end

            case result
            when true
              EvaluationResult.new(score: 1.0, passed: true, details: "passed")
            when false
              EvaluationResult.new(score: 0.0, passed: false, details: "not passed")
            when Numeric
              EvaluationResult.new(score: result, passed: result >= 0.5, details: "custom score: #{result}")
            else
              EvaluationResult.new(score: result ? 1.0 : 0.0, passed: !!result, details: "custom: #{result}")
            end
          end
        end
      end
    end
  end
end
