# frozen_string_literal: true

module RubyLLM
  module Contract
    module Eval
      module Evaluator
        class JsonIncludes
          def call(output:, expected:, input: nil) # rubocop:disable Lint/UnusedMethodArgument
            return type_error(output, expected) unless output.is_a?(Hash) && expected.is_a?(Hash)

            errors = check_keys(output, expected)
            build_result(errors, expected.length)
          end

          private

          def check_keys(output, expected)
            expected.each_with_object([]) do |(key, value), errors|
              actual = output[key]
              error = check_single_key(key, value, actual)
              errors << error if error
            end
          end

          def check_single_key(key, expected_value, actual)
            if actual.nil?
              "missing key: #{key}"
            elsif expected_value.is_a?(::Regexp)
              mismatch_message(key, expected_value, actual) unless actual.to_s.match?(expected_value)
            elsif actual != expected_value
              mismatch_message(key, expected_value, actual)
            end
          end

          def mismatch_message(key, expected_value, actual)
            "#{key}: expected #{expected_value.inspect}, got #{actual.inspect}"
          end

          def build_result(errors, total)
            if errors.empty?
              return EvaluationResult.new(score: 1.0, passed: true,
                                          details: "all expected keys present and matching")
            end

            matched = total - errors.length
            score = total.zero? ? 0.0 : matched.to_f / total
            EvaluationResult.new(score: score, passed: false, details: errors.join("; "))
          end

          def type_error(output, expected)
            EvaluationResult.new(score: 0.0, passed: false,
                                 details: "expected Hash, got #{output.class} and #{expected.class}")
          end
        end
      end
    end
  end
end
