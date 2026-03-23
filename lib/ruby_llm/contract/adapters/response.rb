# frozen_string_literal: true

module RubyLLM
  module Contract
    module Adapters
      class Response
        attr_reader :content, :usage

        def initialize(content:, usage: {})
          @content = content.frozen? ? content : content.dup.freeze
          @usage = usage.frozen? ? usage : usage.dup.freeze
          freeze
        end
      end
    end
  end
end
