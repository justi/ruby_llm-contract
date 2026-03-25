# frozen_string_literal: true

module RubyLLM
  module Contract
    class SchemaValidator
      # Validates enum membership for a node when enum values are declared.
      class EnumRule
        def initialize(errors)
          @errors = errors
        end

        def validate(node)
          allowed_values = node.schema[:enum]
          value = node.value
          return unless allowed_values
          return if allowed_values.include?(value)

          @errors << "#{node.path}: #{value.inspect} is not in enum #{allowed_values.inspect}"
        end
      end
    end
  end
end
