# frozen_string_literal: true

module RubyLLM
  module Contract
    module Concerns
      # Shared helpers for context hash manipulation.
      # Used by EvalHost, Runner, Step::Base.
      module ContextHelpers
        private

        def safe_context(context)
          (context || {}).transform_keys { |key| key.respond_to?(:to_sym) ? key.to_sym : key }
        end

        def isolate_context(context)
          context.transform_values do |value|
            duplicate_context_value(value)
          rescue TypeError
            value
          end
        end

        def duplicate_context_value(value)
          return value.clone_for_concurrency if value.respond_to?(:clone_for_concurrency)
          return value.dup if value.respond_to?(:dup)

          value
        end
      end
    end
  end
end
