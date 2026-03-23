# frozen_string_literal: true

module RubyLLM
  module Contract
    module Adapters
      class Response
        attr_reader :content, :usage

        def initialize(content:, usage: {})
          @content = deep_dup_freeze(content)
          @usage = deep_dup_freeze(usage)
          freeze
        end

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
