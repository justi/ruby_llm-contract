# frozen_string_literal: true

module RubyLLM
  module Contract
    module Eval
      class EvalDefinition
        attr_reader :name, :cases

        def initialize(name, step_class: nil, &)
          @name = name
          @step_class = step_class
          @default_input = nil
          @sample_response = nil
          @cases = []
          instance_eval(&)
        end

        def default_input(input)
          @default_input = input
        end

        def sample_response(response)
          @sample_response = response
          pre_validate_sample! if @step_class
        end

        def build_adapter
          return nil unless @sample_response

          Adapters::Test.new(response: @sample_response.is_a?(String) ? @sample_response : @sample_response.to_json)
        end

        def add_case(description, input: nil, expected: nil, expected_traits: nil, evaluator: nil)
          case_input = input || @default_input
          raise ArgumentError, "add_case requires input (set default_input or pass input:)" unless case_input

          @cases << {
            name: description,
            input: case_input,
            expected: expected,
            expected_traits: expected_traits,
            evaluator: evaluator
          }
        end

        def verify(description, expected_or_proc = nil, input: nil, expect: nil)
          if expected_or_proc && expect
            raise ArgumentError, "verify accepts either a positional argument or expect: keyword, not both"
          end

          expected_or_proc = expect if expect
          case_input = input || @default_input
          validate_verify_args!(expected_or_proc, case_input)

          evaluator = expected_or_proc.is_a?(::Proc) ? expected_or_proc : nil

          @cases << {
            name: description,
            input: case_input,
            expected: evaluator ? nil : expected_or_proc,
            evaluator: evaluator
          }
        end

        def build_dataset
          eval_cases = effective_cases
          eval_name = @name
          Dataset.define(eval_name) do
            eval_cases.each do |eval_case|
              add_case(eval_case[:name], input: eval_case[:input], expected: eval_case[:expected],
                                         expected_traits: eval_case[:expected_traits],
                                         evaluator: eval_case[:evaluator])
            end
          end
        end

        private

        def effective_cases
          return @cases if @cases.any?
          return [] unless @default_input

          # Zero-verify: auto-add a contract check case
          [{ name: "contract check", input: @default_input, expected: nil, evaluator: nil }]
        end

        def validate_verify_args!(expected_or_proc, case_input)
          raise ArgumentError, "verify requires either a positional argument or expect: keyword" unless expected_or_proc
          raise ArgumentError, "verify requires input (set default_input or pass input:)" unless case_input
        end

        def pre_validate_sample!
          schema = @step_class.respond_to?(:output_schema) ? @step_class.output_schema : nil
          return unless schema

          errors = validate_sample_against_schema(schema)
          return if errors.empty?

          raise ArgumentError, "sample_response does not satisfy step schema: #{errors.join(", ")}"
        rescue JSON::ParserError
          # Not JSON -- skip pre-validation
        end

        def validate_sample_against_schema(schema)
          response_hash = @sample_response.is_a?(Hash) ? @sample_response : JSON.parse(@sample_response.to_s)
          symbolized = Parser.symbolize_keys(response_hash)
          SchemaValidator.validate(symbolized, schema)
        end
      end
    end
  end
end
