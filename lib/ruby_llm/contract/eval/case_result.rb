# frozen_string_literal: true

module RubyLLM
  module Contract
    module Eval
      class CaseResult
        # BaselineDiff#compute_score keys off this prefix to keep skipped cases
        # out of the score denominator. Both ends must read it from here.
        SKIPPED_DETAILS_PREFIX = "skipped:"
        # Not run (no adapter). Readers compare step_status, so any result object
        # exposing it works; kept out of score, pass rate and cost-per-call.
        SKIPPED_STATUS = :skipped

        def self.skipped_details(reason)
          "#{SKIPPED_DETAILS_PREFIX} #{reason}"
        end

        attr_reader :name, :input, :output, :expected, :step_status,
                    :score, :details, :duration_ms, :cost, :attempts

        def initialize(name:, input:, output:, expected:, step_status:, # rubocop:disable Metrics/ParameterLists
                       score:, passed:, label: nil, details: nil, duration_ms: nil, cost: nil, attempts: nil,
                       cost_unknown: false)
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
          @attempts = attempts
          @cost_unknown = cost_unknown
          freeze
        end

        def passed?
          @passed
        end

        def failed?
          !@passed
        end

        def cost_unknown?
          @cost_unknown
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
            name: @name,
            input: @input,
            output: @output,
            expected: @expected,
            step_status: @step_status,
            score: @score,
            passed: @passed,
            label: label,
            details: @details,
            duration_ms: @duration_ms,
            cost: @cost,
            attempts: @attempts
          }.tap { |hash| hash[:cost_unknown] = true if @cost_unknown }
        end

        private

        def match?(expected_value, actual)
          case expected_value
          when ::Regexp then actual.to_s.match?(expected_value)
          when ::Range then expected_value.include?(actual)
          else expected_value == actual
          end
        end
      end
    end
  end
end
