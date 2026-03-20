# frozen_string_literal: true

module RubyLLM
  module Contract
    # Include this module to get `Types` constant as a shortcut for RubyLLM::Contract::Types.
    # Usage: `include RubyLLM::Contract::DSL` at the top of your file or class.
    module DSL
      def self.included(base)
        base.const_set(:Types, RubyLLM::Contract::Types) unless base.const_defined?(:Types)
      end
    end
  end
end
