# frozen_string_literal: true

module RubyLLM
  module Contract
    module Eval
      class CaseResult
        attr_reader :name, :input, :output, :expected, :step_status,
                    :score, :details, :duration_ms, :cost

        def initialize(name:, input:, output:, expected:, step_status:,
                       score:, passed:, label: nil, details: nil, duration_ms: nil, cost: nil)
          @name = name
          @input = input
          @output = output
          @expected = expected
          @step_status = step_status
          @score = score.to_f.clamp(0.0, 1.0)
          @passed = passed
          @label = label
          @details = details
          @duration_ms = duration_ms
          @cost = cost
          freeze
        end

        def passed?
          @passed
        end

        def failed?
          !@passed
        end

        def label
          @label || (@passed ? "PASS" : "FAIL")
        end

        def mismatches
          return {} unless @expected.is_a?(Hash) && @output.is_a?(Hash)

          @expected.each_with_object({}) do |(key, value), result|
            actual = @output[key]
            next if match?(value, actual)

            result[key] = { expected: value, got: actual }
          end
        end

        def to_h
          {
            case_name: @name,
            input: @input,
            output: @output,
            expected: @expected,
            step_status: @step_status,
            score: @score,
            passed: @passed,
            label: label,
            details: @details,
            duration_ms: @duration_ms,
            cost: @cost
          }
        end

        private

        def match?(expected_value, actual)
          case expected_value
          when ::Regexp then actual.to_s.match?(expected_value)
          else expected_value == actual
          end
        end
      end
    end
  end
end
