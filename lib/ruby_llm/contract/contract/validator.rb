# frozen_string_literal: true

module RubyLLM
  module Contract
    class Validator
      def validate(raw_output:, definition:, output_type:, input: nil, schema: nil)
        effective_definition = schema ? with_json_strategy(definition) : definition
        parsed_output = parse_output(raw_output, effective_definition)
        return parsed_output if parse_error?(parsed_output)

        effective_output = coerce_and_freeze(parsed_output, output_type, schema)
        errors = collect_errors(effective_output, schema, definition, input)

        { parsed_output: effective_output[:value], errors: errors, status: errors.empty? ? :ok : :validation_failed }
      end

      def self.validate(raw_output:, definition:, output_type:, input: nil, schema: nil)
        new.validate(raw_output: raw_output, definition: definition, output_type: output_type,
                     input: input, schema: schema)
      end

      private

      def parse_error?(parsed_output)
        parsed_output.is_a?(Hash) && parsed_output[:status] == :parse_error
      end

      def coerce_and_freeze(parsed_output, output_type, schema)
        coerced_output, type_errors = validate_type(parsed_output, output_type, !schema.nil?)
        effective = type_errors.empty? ? coerced_output : parsed_output
        deep_freeze(effective)
        { value: effective, type_errors: type_errors }
      end

      def collect_errors(effective_output, schema, definition, input)
        effective_output[:type_errors] +
          validate_schema(effective_output[:value], schema) +
          validate_invariants(effective_output[:value], definition, input)
      end

      def validate_type(parsed_output, output_type, has_schema)
        return [parsed_output, []] if has_schema

        if output_type.is_a?(Class) && !output_type.respond_to?(:[])
          raise TypeError, "expected #{output_type}, got #{parsed_output.class}" unless parsed_output.is_a?(output_type)

          [parsed_output, []]
        else
          coerced = output_type[parsed_output]
          [coerced, []]
        end
      rescue Dry::Types::CoercionError, TypeError, ArgumentError => e
        [parsed_output, [e.message]]
      end

      def validate_schema(parsed_output, schema)
        return [] unless schema

        SchemaValidator.validate(parsed_output, schema)
      end

      def validate_invariants(parsed_output, definition, input)
        definition.invariants.each_with_object([]) do |inv, errors|
          passed = inv.call(parsed_output, input: input)
          if passed.nil?
            warn "[ruby_llm-contract] validate(\"#{inv.description}\") returned nil. " \
                 "This usually means a key mismatch (string vs symbol). " \
                 "Output keys are always symbols."
          end
          errors << inv.description unless passed
        rescue StandardError => e
          errors << "#{inv.description} (raised #{e.class}: #{e.message})"
        end
      end

      def parse_output(raw_output, definition)
        Parser.parse(raw_output, strategy: definition.parse_strategy)
      rescue RubyLLM::Contract::ParseError => e
        { parsed_output: nil, errors: [e.message], status: :parse_error }
      end

      def with_json_strategy(definition)
        return definition if definition.parse_strategy == :json

        Definition.new { parse :json }
      end

      def deep_freeze(obj)
        case obj
        when Hash
          obj.each_value { |element| deep_freeze(element) }
          obj.freeze
        when Array
          obj.each { |element| deep_freeze(element) }
          obj.freeze
        when String
          obj.freeze
        else
          obj
        end
      end
    end
  end
end
