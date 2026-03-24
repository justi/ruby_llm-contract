# frozen_string_literal: true

module RubyLLM
  module Contract
    module Concerns
      # Shared helpers for context hash manipulation.
      # Used by EvalHost, Runner, Step::Base.
      module ContextHelpers
        private

        def safe_context(context)
          (context || {}).transform_keys { |k| k.respond_to?(:to_sym) ? k.to_sym : k }
        end

        def isolate_context(context)
          context.transform_values do |v|
            if v.respond_to?(:clone_for_concurrency)
              v.clone_for_concurrency
            elsif v.respond_to?(:dup)
              v.dup
            else
              v
            end
          rescue TypeError
            v
          end
        end
      end
    end
  end
end
