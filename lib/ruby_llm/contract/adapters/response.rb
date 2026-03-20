# frozen_string_literal: true

module RubyLLM
  module Contract
    module Adapters
      class Response
        attr_reader :content, :usage

        def initialize(content:, usage: {})
          @content = content
          @usage = usage
          freeze
        end
      end
    end
  end
end
