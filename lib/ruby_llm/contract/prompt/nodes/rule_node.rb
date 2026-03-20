# frozen_string_literal: true

module RubyLLM
  module Contract
    module Prompt
      module Nodes
        class RuleNode < Node
          def initialize(content)
            super(type: :rule, content: content)
          end
        end
      end
    end
  end
end
