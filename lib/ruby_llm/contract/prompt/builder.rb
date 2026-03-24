# frozen_string_literal: true

module RubyLLM
  module Contract
    module Prompt
      class Builder
        NOT_PROVIDED = Object.new.freeze

        def initialize(block)
          @block = block
          @nodes = []
        end

        def build(input = NOT_PROVIDED)
          @nodes = []
          if input != NOT_PROVIDED && @block.arity >= 1
            instance_exec(input, &@block)
          else
            instance_eval(&@block)
          end
          AST.new(@nodes)
        end

        def system(text)
          @nodes << Nodes::SystemNode.new(text)
        end

        def rule(text)
          @nodes << Nodes::RuleNode.new(text)
        end

        def example(input:, output:)
          @nodes << Nodes::ExampleNode.new(input: input, output: output)
        end

        def user(text)
          @nodes << Nodes::UserNode.new(text)
        end

        def section(name, text)
          @nodes << Nodes::SectionNode.new(name, text)
        end

        def self.build(input: NOT_PROVIDED, &block)
          new(block).build(input)
        end
      end
    end
  end
end
