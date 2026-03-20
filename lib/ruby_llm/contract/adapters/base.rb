# frozen_string_literal: true

module RubyLLM
  module Contract
    module Adapters
      class Base
        def call(messages:, **_options)
          raise NotImplementedError, "Subclasses must implement #call"
        end
      end
    end
  end
end
