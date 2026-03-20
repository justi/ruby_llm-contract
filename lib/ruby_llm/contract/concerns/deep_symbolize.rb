# frozen_string_literal: true

module RubyLLM
  module Contract
    module Concerns
      module DeepSymbolize
        def deep_symbolize(obj)
          case obj
          when Hash then obj.transform_keys(&:to_sym).transform_values { |val| deep_symbolize(val) }
          when Array then obj.map { |val| deep_symbolize(val) }
          else obj
          end
        end
      end
    end
  end
end
