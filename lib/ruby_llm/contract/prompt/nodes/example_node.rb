# frozen_string_literal: true

module RubyLLM
  module Contract
    module Prompt
      module Nodes
        class ExampleNode < Node
          attr_reader :input, :output

          def initialize(input:, output:)
            @input = input.freeze
            @output = output.freeze
            super(type: :example, content: nil)
          end

          def ==(other)
            other.is_a?(self.class) && type == other.type && input == other.input && output == other.output
          end

          def to_h
            { type: :example, input: @input, output: @output }
          end
        end
      end
    end
  end
end
