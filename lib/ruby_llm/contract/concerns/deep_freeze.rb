# frozen_string_literal: true

module RubyLLM
  module Contract
    module Concerns
      # Deep-duplicate and freeze a value. Creates an independent frozen copy
      # without mutating the original. Handles Hash, Array, String recursively.
      module DeepFreeze
        private

        def deep_dup_freeze(obj)
          case obj
          when NilClass, Integer, Float, Symbol, TrueClass, FalseClass then obj
          when Hash then obj.transform_values { |v| deep_dup_freeze(v) }.freeze
          when Array then obj.map { |v| deep_dup_freeze(v) }.freeze
          when String then obj.frozen? ? obj : obj.dup.freeze
          else obj.frozen? ? obj : obj.dup.freeze
          end
        end
      end
    end
  end
end
