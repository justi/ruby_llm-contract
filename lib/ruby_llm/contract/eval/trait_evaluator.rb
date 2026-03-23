# frozen_string_literal: true

module RubyLLM
  module Contract
    module Eval
      # Extracted from Runner to reduce class length.
      # Evaluates expected_traits against parsed output.
      module TraitEvaluator
        private

        def evaluate_traits(step_result, test_case)
          output = step_result.parsed_output
          traits = test_case.expected_traits
          errors = traits.each_with_object([]) do |(key, expectation), errs|
            check_trait(output, key, expectation, errs)
          end

          build_trait_result(errors, traits.length)
        end

        def check_trait(output, key, expectation, errors)
          value = output.is_a?(Hash) ? output[key] : nil
          error_msg = trait_error(key, value, expectation)
          errors << error_msg if error_msg
        end

        def trait_error(key, value, expectation)
          case expectation
          when ::Proc
            trait_proc_error(key, value, expectation)
          when ::Regexp
            trait_regexp_error(key, value, expectation)
          when Range
            trait_range_error(key, value, expectation)
          when true
            trait_truthy_error(key, value)
          when false
            trait_falsy_error(key, value)
          else
            trait_equality_error(key, value, expectation)
          end
        end

        def trait_regexp_error(key, value, expectation)
          "#{key}: does not match #{expectation.inspect}" unless value.to_s.match?(expectation)
        end

        def trait_range_error(key, value, expectation)
          comparable = value.is_a?(Numeric) ? value : value.to_s.length
          "#{key}: #{value.inspect} not in #{expectation}" unless expectation.include?(comparable)
        end

        def trait_truthy_error(key, value)
          "#{key}: expected truthy, got #{value.inspect}" unless value
        end

        def trait_falsy_error(key, value)
          "#{key}: expected falsy, got #{value.inspect}" if value
        end

        def trait_proc_error(key, value, expectation)
          "#{key}: trait check failed, got #{value.inspect}" unless expectation.call(value)
        end

        def trait_equality_error(key, value, expectation)
          "#{key}: expected #{expectation.inspect}, got #{value.inspect}" unless value == expectation
        end

        def build_trait_result(errors, trait_count)
          if errors.empty?
            EvaluationResult.new(score: 1.0, passed: true, details: "all traits match")
          else
            matched = trait_count - errors.length
            score = trait_count.zero? ? 0.0 : matched.to_f / trait_count
            EvaluationResult.new(score: score, passed: false, details: errors.join("; "))
          end
        end
      end
    end
  end
end
