# frozen_string_literal: true

module RubyLLM
  module Contract
    module Concerns
      # Deep-duplicate and freeze a value. Creates an independent frozen copy
      # without mutating the original. Handles Hash, Array, String recursively.
      module DeepFreeze
        private

        IMMUTABLE_TYPES = [NilClass, Integer, Float, Symbol, TrueClass, FalseClass].freeze

        def deep_dup_freeze(object)
          case object
          when *IMMUTABLE_TYPES then object
          when Hash then object.transform_values { |value| deep_dup_freeze(value) }.freeze
          when Array then object.map { |value| deep_dup_freeze(value) }.freeze
          else
            frozen_copy(object)
          end
        end

        def frozen_copy(object)
          object.frozen? ? object : object.dup.freeze
        end
      end
    end
  end
end
