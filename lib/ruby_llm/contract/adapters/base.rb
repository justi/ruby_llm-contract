# frozen_string_literal: true

module RubyLLM
  module Contract
    module Adapters
      class Base
        def call(messages:, **_options)
          raise NotImplementedError, "Subclasses must implement #call"
        end

        # Override in stateful adapters to provide a fully independent copy
        # for concurrent eval execution. Default: self (stateless adapters).
        def clone_for_concurrency
          self
        end
      end
    end
  end
end
