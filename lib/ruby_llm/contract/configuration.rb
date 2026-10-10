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
    #
    # `workflow_instrumentation = true` wraps steps and pipelines in
    # `RubyLLM.workflow` (see WorkflowScope).
    class Configuration
      attr_accessor :default_adapter, :default_model, :logger, :workflow_instrumentation

      def initialize
        @default_adapter = nil
        @default_model = nil
        @logger = nil
        @workflow_instrumentation = false
      end
    end
  end
end
