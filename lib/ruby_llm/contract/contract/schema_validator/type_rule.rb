# frozen_string_literal: true

module RubyLLM
  module Contract
    class SchemaValidator
      # Validates the declared JSON schema type for a node.
      class TypeRule
        def initialize(errors)
          @errors = errors
        end

        def validate(node)
          expected_type = node.expected_type
          value = node.value
          return unless expected_type
          return if type_valid?(expected_type, value)

          @errors << "#{node.path}: expected #{expected_type}, got #{value.class}"
        end

        private

        def type_valid?(expected_type, value)
          checker = SchemaValidator::TYPE_CHECKS[expected_type]
          checker ? checker.call(value) : true
        end
      end
    end
  end
end
