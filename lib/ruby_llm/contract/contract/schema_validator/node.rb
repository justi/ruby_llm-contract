# frozen_string_literal: true

module RubyLLM
  module Contract
    class SchemaValidator
      # Immutable validation context for one schema node and its current path.
      class Node < Data.define(:value, :schema, :path)
        def expected_type
          schema[:type]&.to_s
        end

        def object_schema?
          expected_type == "object" || schema.key?(:properties)
        end

        def hash?
          value.is_a?(Hash)
        end

        def array?
          value.is_a?(Array)
        end

        def numeric?
          value.is_a?(Numeric)
        end

        def properties
          schema[:properties] || {}
        end

        def required_fields
          Array(schema[:required]).map(&:to_s)
        end

        def items_schema
          schema[:items]
        end

        def key_present?(field)
          symbolized = field.to_sym
          value.key?(symbolized) || value.key?(field.to_s)
        end

        def field_value(field)
          symbolized = field.to_sym
          return value[symbolized] if value.key?(symbolized)

          value[field.to_s]
        end

        def extra_keys
          value.keys.map(&:to_s)
        end

        def qualify(field)
          path ? "#{path}.#{field}" : field.to_s
        end

        def child(field, child_value, child_schema)
          self.class.new(value: child_value, schema: child_schema, path: qualify(field))
        end

        def array_item(index, item, item_schema)
          self.class.new(value: item, schema: item_schema, path: "#{path}[#{index}]")
        end
      end
    end
  end
end
