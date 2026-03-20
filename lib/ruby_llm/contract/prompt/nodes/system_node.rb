# frozen_string_literal: true

module RubyLLM
  module Contract
    module Prompt
      module Nodes
        class SystemNode < Node
          def initialize(content)
            super(type: :system, content: content)
          end
        end
      end
    end
  end
end
