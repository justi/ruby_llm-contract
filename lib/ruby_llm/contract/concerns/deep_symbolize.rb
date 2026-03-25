# frozen_string_literal: true

module RubyLLM
  module Contract
    module Concerns
      # Recursively converts Hash keys to symbols while preserving array shape.
      module DeepSymbolize
        def deep_symbolize(object)
          case object
          when Hash then symbolize_hash(object)
          when Array then object.map { |value| deep_symbolize(value) }
          else
            object
          end
        end

        private

        def symbolize_hash(hash)
          hash.each_with_object({}) do |(key, value), symbolized|
            symbolized[key.to_sym] = deep_symbolize(value)
          end
        end
      end
    end
  end
end
