# frozen_string_literal: true

module RubyLLM
  module Contract
    class SchemaValidator
      # Applies object-only validation rules to a schema node.
      class ObjectRules
        def initialize(errors)
          @errors = errors
        end

        def validate(node)
          validate_required_fields(node)
          validate_properties(node) { |child| yield child }
          validate_additional_properties(node)
        end

        private

        def validate_required_fields(node)
          node.required_fields.each do |field|
            next if node.key_present?(field)

            @errors << "missing required field: #{node.qualify(field)}"
          end
        end

        def validate_properties(node)
          required = node.required_fields

          node.properties.each do |field, field_schema|
            next unless node.key_present?(field)

            value = node.field_value(field)
            qualified = node.qualify(field)

            if value.nil?
              validate_nil_field(qualified, field_schema, required.include?(field.to_s))
              next
            end

            yield node.child(field, value, field_schema)
          end
        end

        def validate_nil_field(path, field_schema, required)
          return unless required
          return if nullable_schema?(field_schema)

          expected_type = field_schema[:type] || "non-null"
          @errors << "#{path}: expected #{expected_type}, got nil"
        end

        # JSON Schema permits nil when the field schema explicitly accepts
        # null. Three idiomatic forms are recognised:
        #   - `type: ["string", "null"]`     (array form)
        #   - `type: "null"`                 (degenerate scalar form)
        #   - `anyOf` / `oneOf` containing a branch with `type: "null"`
        # Without this gate the validator wrongly rejected legal nulls on
        # required-but-nullable fields, forcing adopters into `required: false`
        # + `strict: false` workarounds. Fixed in 0.10.3.
        def nullable_schema?(field_schema)
          return false unless field_schema.is_a?(Hash)

          type = field_schema[:type] || field_schema["type"]
          return true if type.is_a?(Array) && type.any? { |t| t.to_s == "null" }
          return true if type.to_s == "null"

          %i[anyOf oneOf].any? do |key|
            branches = field_schema[key] || field_schema[key.to_s]
            branches.is_a?(Array) && branches.any? do |branch|
              branch.is_a?(Hash) && (branch[:type] || branch["type"]).to_s == "null"
            end
          end
        end

        def validate_additional_properties(node)
          return unless node.schema[:additionalProperties] == false

          allowed_keys = node.properties.keys.map(&:to_s)
          extra_keys = node.extra_keys.reject { |key| allowed_keys.include?(key) }

          extra_keys.each do |extra_key|
            @errors << "#{node.qualify(extra_key)}: additional property not allowed"
          end
        end
      end
    end
  end
end
