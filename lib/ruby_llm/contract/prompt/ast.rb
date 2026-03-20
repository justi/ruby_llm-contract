# frozen_string_literal: true

module RubyLLM
  module Contract
    module Prompt
      class AST
        include Enumerable

        attr_reader :nodes

        def initialize(nodes)
          @nodes = nodes.dup.freeze
          freeze
        end

        def each(&)
          @nodes.each(&)
        end

        def size
          @nodes.size
        end

        def [](index)
          @nodes[index]
        end

        def ==(other)
          other.is_a?(self.class) && nodes == other.nodes
        end

        def to_a
          @nodes.map(&:to_h)
        end
      end
    end
  end
end
