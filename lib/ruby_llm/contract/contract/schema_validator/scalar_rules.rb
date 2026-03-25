# frozen_string_literal: true

module RubyLLM
  module Contract
    class SchemaValidator
      # Applies scalar-only validation rules to a schema node.
      class ScalarRules
        def initialize(errors)
          @rules = [
            TypeRule.new(errors),
            EnumRule.new(errors),
            BoundRule.new(errors)
          ]
        end

        def validate(node)
          @rules.each { |rule| rule.validate(node) }
        end
      end
    end
  end
end
