# frozen_string_literal: true

module RubyLLM
  module Contract
    module Adapters
      class Response
        include Concerns::DeepFreeze

        attr_reader :content, :usage

        def initialize(content:, usage: {})
          @content = deep_dup_freeze(content)
          @usage = deep_dup_freeze(usage)
          freeze
        end
      end
    end
  end
end
