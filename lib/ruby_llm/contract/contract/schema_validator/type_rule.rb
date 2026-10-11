# frozen_string_literal: true

module RubyLLM
  module Contract
    class SchemaValidator
      class TypeRule
        def initialize(errors)
          @errors = errors
        end

        def validate(node)
          expected_types = Array(node.schema[:type]).map(&:to_s)
          value = node.value
          return if expected_types.empty?
          return if expected_types.any? { |type| type_valid?(type, value) }

          @errors << "#{node.path}: expected #{expected_types.join(" or ")}, got #{value.class}"
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
