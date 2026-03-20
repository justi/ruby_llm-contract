# frozen_string_literal: true

module RubyLLM
  module Contract
    module Prompt
      module Nodes
        class SectionNode < Node
          attr_reader :name

          def initialize(name, content)
            @name = name.freeze
            super(type: :section, content: content)
          end

          def ==(other)
            other.is_a?(self.class) && type == other.type && name == other.name && content == other.content
          end

          def to_h
            { type: :section, name: @name, content: @content }
          end
        end
      end
    end
  end
end
