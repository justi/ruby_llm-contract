# frozen_string_literal: true

module RubyLLM
  module Contract
    # Configuration for ruby_llm-contract.
    #
    # API keys should be configured directly via RubyLLM:
    #   RubyLLM.configure { |c| c.openai_api_key = ENV["OPENAI_API_KEY"] }
    #
    # Then configure contract-specific options:
    #   RubyLLM::Contract.configure { |c| c.default_model = "gpt-4.1-mini" }
    class Configuration
      attr_accessor :default_adapter, :default_model, :logger

      def initialize
        @default_adapter = nil
        @default_model = nil
        @logger = nil
      end
    end
  end
end
