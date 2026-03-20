# frozen_string_literal: true

module RubyLLM
  module Contract
    class Error < StandardError
      attr_reader :details

      def initialize(message = nil, details: nil)
        @details = details
        super(message)
      end
    end

    class InputError < Error; end
    class ParseError < Error; end
    class ContractError < Error; end
    class AdapterError < Error; end
  end
end
