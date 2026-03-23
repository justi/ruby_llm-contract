# frozen_string_literal: true

module RubyLLM
  module Contract
    module Prompt
      class Node
        attr_reader :type, :content

        def initialize(type:, content:)
          @type = type
          @content = content.frozen? ? content : content.dup.freeze
          freeze
        end

        def ==(other)
          other.is_a?(self.class) && type == other.type && content == other.content
        end

        def to_h
          { type: @type, content: @content }
        end
      end
    end
  end
end
