# frozen_string_literal: true

module RubyLLM
  module Contract
    module Concerns
      module TraceEquality
        def ==(other)
          return to_h == other if other.is_a?(Hash)

          other.is_a?(self.class) && to_h == other.to_h
        end
      end
    end
  end
end
