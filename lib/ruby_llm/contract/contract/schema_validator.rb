# frozen_string_literal: true

module RubyLLM
  module Contract
    # Client-side validation of parsed output against an output_schema.
    # Checks required fields, enum constraints, number ranges, and nested objects.
    # This complements provider-side enforcement (with_schema) and catches
    # violations when using Test adapter or providers that ignore schemas.
    class SchemaValidator # rubocop:disable Metrics/ClassLength
      include Concerns::DeepSymbolize

      # Bundles field path, value, and constraints to reduce parameter passing
      FieldCheck = Struct.new(:qualified, :value, :constraints)

      SIZE_BOUNDS = {
        string: { min_key: :minLength, max_key: :maxLength, metric: "length" },
        array: { min_key: :minItems, max_key: :maxItems, metric: "array length" }
      }.freeze

      def self.validate(parsed_output, schema)
        new(parsed_output, schema).validate
      end

      def initialize(parsed_output, schema)
        @output = parsed_output
        @json_schema = extract_schema(schema)
        @errors = []
      end

      def validate
        return [] unless @json_schema.is_a?(Hash)

        return validate_non_hash_output unless @output.is_a?(Hash)

        validate_object(@output, @json_schema, prefix: nil)
        @errors
      end

      private

      def validate_non_hash_output
        expected_type = @json_schema[:type]&.to_s

        if expected_type == "object" || @json_schema.key?(:properties)
          return ["expected object, got #{@output.class}"]
        end

        errors = []
        validate_type_match(errors, @output, expected_type, "root") if expected_type
        validate_constraints(errors, @output, @json_schema, "root")

        if expected_type == "array" && @output.is_a?(Array) && @json_schema[:items]
          validate_array_items(errors, @output, @json_schema[:items], "")
        end

        errors
      end

      def validate_array_items(errors, array, items_schema, prefix)
        array.each_with_index do |item, i|
          item_prefix = "#{prefix}[#{i}]"
          validate_value(errors, item, items_schema, item_prefix)
        end
      end

      def validate_value(errors, value, schema, prefix)
        value_type = schema[:type]&.to_s

        validate_type_match(errors, value, value_type, prefix) if value_type
        validate_constraints(errors, value, schema, prefix)

        if value.is_a?(Hash) && (schema.key?(:properties) || value_type == "object")
          validate_object(value, schema, prefix: prefix)
          errors.concat(@errors)
          @errors = []
        elsif value.is_a?(Array) && schema[:items]
          validate_array_items(errors, value, schema[:items], prefix)
        end
      end

      def validate_type_match(errors, value, expected_type, prefix)
        valid = case expected_type
                when "string" then value.is_a?(String)
                when "integer" then value.is_a?(Integer)
                when "number" then value.is_a?(Numeric)
                when "boolean" then value.is_a?(TrueClass) || value.is_a?(FalseClass)
                when "array" then value.is_a?(Array)
                else true
                end
        errors << "#{prefix}: expected #{expected_type}, got #{value.class}" unless valid
      end

      def validate_constraints(errors, value, schema, prefix)
        if schema[:minimum] && value.is_a?(Numeric) && value < schema[:minimum]
          errors << "#{prefix}: #{value} is less than minimum #{schema[:minimum]}"
        end
        if schema[:maximum] && value.is_a?(Numeric) && value > schema[:maximum]
          errors << "#{prefix}: #{value} is greater than maximum #{schema[:maximum]}"
        end
        if schema[:enum] && !schema[:enum].include?(value)
          errors << "#{prefix}: #{value.inspect} is not in enum #{schema[:enum].inspect}"
        end
        if schema[:minItems] && value.is_a?(Array) && value.length < schema[:minItems]
          errors << "#{prefix}: array has #{value.length} items, minimum #{schema[:minItems]}"
        end
        if schema[:maxItems] && value.is_a?(Array) && value.length > schema[:maxItems]
          errors << "#{prefix}: array has #{value.length} items, maximum #{schema[:maxItems]}"
        end
        if schema[:minLength] && value.is_a?(String) && value.length < schema[:minLength]
          errors << "#{prefix}: string length #{value.length} is less than minLength #{schema[:minLength]}"
        end
        if schema[:maxLength] && value.is_a?(String) && value.length > schema[:maxLength]
          errors << "#{prefix}: string length #{value.length} is greater than maxLength #{schema[:maxLength]}"
        end
      end

      def extract_schema(schema)
        instance = schema.is_a?(Class) ? schema.new : schema
        json = if instance.respond_to?(:to_json_schema)
                 schema_data = instance.to_json_schema
                 schema_data[:schema] || schema_data["schema"] || schema_data
               else
                 schema
               end
        deep_symbolize(json)
      end

      def validate_object(output, schema, prefix:)
        return unless output.is_a?(Hash) && schema.is_a?(Hash)

        properties = schema[:properties] || {}
        required = schema[:required] || []

        check_required(required, output, prefix: prefix)
        check_properties(properties, output, prefix: prefix, required_fields: required)
        check_additional_properties(output, schema, prefix: prefix)
      end

      def check_required(required, output, prefix:)
        required.each do |field|
          key = field.to_s.to_sym
          qualified = qualify(prefix, field)
          @errors << "missing required field: #{qualified}" unless output.key?(key)
        end
      end

      def check_properties(properties, output, prefix:, required_fields: [])
        required_syms = required_fields.map { |field| field.to_s.to_sym }

        properties.each do |field, constraints|
          key = field.to_sym
          value = output[key]
          qualified = qualify(prefix, field)

          if value.nil?
            check_nil_required(qualified, key, constraints, required_syms, output)
            next
          end

          validate_field(FieldCheck.new(qualified: qualified, value: value, constraints: constraints))
        end
      end

      def check_nil_required(qualified, key, constraints, required_syms, output)
        return unless required_syms.include?(key) && output.key?(key)

        expected = constraints[:type] || "non-null"
        @errors << "#{qualified}: expected #{expected}, got nil"
      end

      def check_additional_properties(output, schema, prefix:)
        return unless schema[:additionalProperties] == false

        allowed_keys = (schema[:properties] || {}).keys.map { |prop_key| prop_key.to_s.to_sym }
        extra_keys = output.keys - allowed_keys

        extra_keys.each do |extra_key|
          @errors << "#{qualify(prefix, extra_key)}: additional property not allowed"
        end
      end

      def validate_field(field_check)
        check_enum(field_check)
        check_number_range(field_check)
        check_type_constraint(field_check)
        check_string_length(field_check)
        check_nested(field_check)
      end

      def check_enum(field_check)
        qualified, value, constraints = field_check.to_a
        enum = constraints[:enum]
        return unless enum

        @errors << "#{qualified}: #{value.inspect} is not in enum #{enum.inspect}" unless enum.include?(value)
      end

      def check_number_range(field_check)
        qualified, value, constraints = field_check.to_a
        return unless value.is_a?(Numeric)

        check_minimum(qualified, value, constraints[:minimum])
        check_maximum(qualified, value, constraints[:maximum])
      end

      def check_type_constraint(field_check)
        qualified, value, constraints = field_check.to_a
        expected_type = constraints[:type]&.to_s
        return unless expected_type

        @errors << "#{qualified}: expected #{expected_type}, got #{value.class}" unless type_valid?(expected_type,
                                                                                                    value)
      end

      def type_valid?(expected_type, value)
        case expected_type
        when "string" then value.is_a?(String)
        when "number" then value.is_a?(Numeric)
        when "integer" then value.is_a?(Integer)
        when "boolean" then [true, false].include?(value)
        when "array" then value.is_a?(Array)
        when "object" then value.is_a?(Hash)
        else true
        end
      end

      def check_nested(field_check)
        qualified, value, constraints = field_check.to_a
        nested_type = constraints[:type]&.to_s

        case nested_type
        when "object"
          validate_object(value, constraints, prefix: qualified) if value.is_a?(Hash)
        when "array"
          check_array_items(qualified, value, constraints) if value.is_a?(Array)
        end
      end

      def check_string_length(field_check)
        qualified, value, constraints = field_check.to_a
        check_size_bounds(qualified, value.length, constraints, :string) if value.is_a?(String)
      end

      def check_array_length(qualified, value, constraints)
        check_size_bounds(qualified, value.length, constraints, :array) if value.is_a?(Array)
      end

      def check_size_bounds(qualified, actual, constraints, kind)
        bounds = SIZE_BOUNDS[kind]
        check_size_minimum(qualified, actual, constraints[bounds[:min_key]], bounds)
        check_size_maximum(qualified, actual, constraints[bounds[:max_key]], bounds)
      end

      def check_array_items(qualified, value, constraints)
        check_array_length(qualified, value, constraints)

        items_schema = constraints[:items]
        return unless items_schema.is_a?(Hash)

        value.each_with_index do |item, idx|
          validate_array_item("#{qualified}[#{idx}]", item, items_schema)
        end
      end

      def validate_array_item(item_key, item, items_schema)
        item_type = items_schema[:type]&.to_s

        if item_type == "object" && item.is_a?(Hash)
          validate_object(item, items_schema, prefix: item_key)
        elsif item_type == "array" && item.is_a?(Array)
          check_array_items(item_key, item, items_schema)
        else
          validate_field(FieldCheck.new(qualified: item_key, value: item, constraints: items_schema))
        end
      end

      def check_minimum(qualified, actual, limit)
        return unless limit && actual < limit

        @errors << "#{qualified}: #{actual} is below minimum #{limit}"
      end

      def check_maximum(qualified, actual, limit)
        return unless limit && actual > limit

        @errors << "#{qualified}: #{actual} is above maximum #{limit}"
      end

      def check_size_minimum(qualified, actual, limit, bounds)
        return unless limit && actual < limit

        @errors << "#{qualified}: #{bounds[:metric]} #{actual} is below #{bounds[:min_key]} #{limit}"
      end

      def check_size_maximum(qualified, actual, limit, bounds)
        return unless limit && actual > limit

        @errors << "#{qualified}: #{bounds[:metric]} #{actual} is above #{bounds[:max_key]} #{limit}"
      end

      def qualify(prefix, field)
        prefix ? "#{prefix}.#{field}" : field.to_s
      end
    end
  end
end
