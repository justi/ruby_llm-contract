# frozen_string_literal: true

module RubyLLM
  module Contract
    module Prompt
      module Nodes
        class UserNode < Node
          def initialize(content)
            super(type: :user, content: content)
          end
        end
      end
    end
  end
end
