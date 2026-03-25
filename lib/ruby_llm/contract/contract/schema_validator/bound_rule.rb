# frozen_string_literal: true

module RubyLLM
  module Contract
    class SchemaValidator
      # Validates numeric and collection size bounds for a node.
      class BoundRule
        NUMERIC_LIMITS = [
          { key: :minimum, label: "minimum", relation: "below", invalid: ->(actual, limit) { actual < limit } },
          { key: :maximum, label: "maximum", relation: "above", invalid: ->(actual, limit) { actual > limit } }
        ].freeze
        SIZE_LIMITS = [
          { bound: :min_key, relation: "below", invalid: ->(actual, limit) { actual < limit } },
          { bound: :max_key, relation: "above", invalid: ->(actual, limit) { actual > limit } }
        ].freeze

        def initialize(errors)
          @errors = errors
        end

        def validate(node)
          value = node.value
          schema = node.schema
          path = node.path

          append_numeric_bound_errors(path, value, schema) if value.is_a?(Numeric)
          append_size_bound_errors(path, value, schema)
        end

        private

        def append_numeric_bound_errors(path, value, schema)
          NUMERIC_LIMITS.each do |limit_config|
            append_bound_error(
              path: path,
              actual: value,
              limit: schema[limit_config[:key]],
              label: limit_config[:label],
              relation: limit_config[:relation],
              invalid: limit_config[:invalid]
            )
          end
        end

        def append_size_bound_errors(path, value, schema)
          bounds = size_bounds_for(value)
          return unless bounds

          actual_size = value.length
          metric = bounds[:metric]

          SIZE_LIMITS.each do |limit_config|
            label = bounds[limit_config[:bound]]
            append_bound_error(
              path: path,
              actual: actual_size,
              limit: schema[label],
              label: label,
              relation: limit_config[:relation],
              metric: metric,
              invalid: limit_config[:invalid]
            )
          end
        end

        def append_bound_error(path:, actual:, limit:, label:, relation:, invalid:, metric: nil)
          return unless limit
          return unless invalid.call(actual, limit)

          subject = metric ? "#{metric} #{actual}" : actual
          @errors << "#{path}: #{subject} is #{relation} #{label} #{limit}"
        end

        def size_bounds_for(value)
          case value
          when String
            SchemaValidator::SIZE_BOUNDS[:string]
          when Array
            SchemaValidator::SIZE_BOUNDS[:array]
          end
        end
      end
    end
  end
end
