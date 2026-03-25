# frozen_string_literal: true

module RubyLLM
  module Contract
    module Eval
      module Evaluator
        # Adapts custom Ruby callables to the EvaluationResult contract.
        class ProcEvaluator
          def initialize(callable)
            @callable = callable
          end

          def call(output:, expected: nil, input: nil) # rubocop:disable Lint/UnusedMethodArgument,Metrics
            result = invoke_callable(output, input)
            warn_nil_result if result.nil?
            build_evaluation_result(result)
          end

          private

          def invoke_callable(output, input)
            callable_accepts_input? ? @callable.call(output, input) : @callable.call(output)
          end

          def callable_accepts_input?
            arity = @callable.arity
            arity == 2 || (arity.negative? && @callable.parameters.length >= 2)
          end

          def warn_nil_result
            warn "[ruby_llm-contract] verify/evaluator proc returned nil. " \
                 "This usually means a key mismatch (string vs symbol). " \
                 "Output keys are always symbols."
          end

          def build_evaluation_result(result)
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
