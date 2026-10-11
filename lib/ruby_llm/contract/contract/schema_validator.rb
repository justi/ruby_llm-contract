# frozen_string_literal: true

require_relative "schema_validator/node"
require_relative "schema_validator/schema_extractor"
require_relative "schema_validator/type_rule"
require_relative "schema_validator/enum_rule"
require_relative "schema_validator/bound_rule"
require_relative "schema_validator/scalar_rules"
require_relative "schema_validator/object_rules"

module RubyLLM
  module Contract
    # Client-side validation of parsed output against an output_schema.
    # Checks required fields, enum constraints, number ranges, and nested objects.
    # This complements provider-side enforcement (with_schema) and catches
    # violations when using Test adapter or providers that ignore schemas.
    class SchemaValidator
      SIZE_BOUNDS = {
        string: { min_key: :minLength, max_key: :maxLength, metric: "length" },
        array: { min_key: :minItems, max_key: :maxItems, metric: "array length" }
      }.freeze
      TYPE_CHECKS = {
        "string" => ->(value) { value.is_a?(String) },
        "integer" => ->(value) { value.is_a?(Integer) },
        "number" => ->(value) { value.is_a?(Numeric) },
        "boolean" => ->(value) { value.is_a?(TrueClass) || value.is_a?(FalseClass) },
        "array" => ->(value) { value.is_a?(Array) },
        "object" => ->(value) { value.is_a?(Hash) },
        "null" => lambda(&:nil?)
      }.freeze
      COMPOSITION_KEYWORDS = %i[anyOf oneOf].freeze

      def self.validate(parsed_output, schema)
        new(parsed_output, schema).validate
      end

      def initialize(parsed_output, schema)
        @errors = []
        json_schema = SchemaExtractor.new.call(schema)
        path = root_object_schema?(json_schema) ? nil : "root"
        @root_node = Node.new(value: parsed_output, schema: json_schema, path: path)
        @scalar_rules = ScalarRules.new(@errors)
        @object_rules = ObjectRules.new(@errors)
      end

      def validate
        return [] unless @root_node.schema.is_a?(Hash)

        if @root_node.object_schema? && !@root_node.hash?
          ["expected object, got #{@root_node.value.class}"]
        else
          validate_root
          @errors
        end
      end

      private

      def validate_root
        validate_node(@root_node)
      end

      def validate_node(node)
        return validate_composition(node) if node.composition

        @scalar_rules.validate(node)
        @object_rules.validate(node) { |child| validate_node(child) } if node.hash? && node.object_schema?
        validate_array(node) if node.array?
      end

      # anyOf passes when at least one branch validates, oneOf when exactly one
      # does. When none does, the errors of the one branch whose type fits the
      # value are the useful ones; otherwise the value matches no branch type.
      def validate_composition(node)
        keyword, branches = node.composition
        branch_errors = branches.map { |branch| errors_for(node.with_schema(branch)) }
        passing = branch_errors.count(&:empty?)
        return if keyword == :anyOf ? passing.positive? : passing == 1

        if passing > 1
          @errors << "#{node.label}: matches #{passing} oneOf branches, expected exactly 1"
        else
          report_no_matching_branch(node, branches, branch_errors)
        end
      end

      def report_no_matching_branch(node, branches, branch_errors)
        fitting = branches.each_index.select { |i| branch_type_fits?(branches[i], node.value) }
        return @errors.concat(branch_errors[fitting.first]) if fitting.size == 1

        types = branches.flat_map { |branch| branch_types(branch) }.uniq
        @errors << "#{node.label}: expected one of #{types.join(", ")}, got #{node.value.class}"
      end

      def errors_for(node)
        before = @errors.size
        validate_node(node)
        @errors.slice!(before..)
      end

      def branch_type_fits?(branch, value)
        branch_types(branch).any? { |type| TYPE_CHECKS.fetch(type, ->(_) { true }).call(value) }
      end

      def branch_types(branch)
        types = Array(branch[:type]).map(&:to_s)
        types.empty? && branch.key?(:properties) ? ["object"] : types
      end

      def validate_array(node)
        items_schema = node.items_schema
        return unless items_schema.is_a?(Hash)

        node.value.each_with_index do |item, index|
          validate_node(node.array_item(index, item, items_schema))
        end
      end

      def root_object_schema?(schema)
        schema[:type]&.to_s == "object" || schema.key?(:properties)
      end
    end
  end
end
