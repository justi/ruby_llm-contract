# frozen_string_literal: true

module RubyLLM
  module Contract
    class Invariant
      attr_reader :description

      def initialize(description, block)
        @description = description
        @block = block
        freeze
      end

      def call(parsed_output, input: nil)
        if @block.arity >= 2
          @block.call(parsed_output, input)
        else
          @block.call(parsed_output)
        end
      end
    end
  end
end
