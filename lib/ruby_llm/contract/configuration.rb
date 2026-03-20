# frozen_string_literal: true

module RubyLLM
  module Contract
    class Configuration
      attr_accessor :default_adapter, :default_model

      API_KEY_METHODS = %i[openai_api_key anthropic_api_key gemini_api_key
                           deepseek_api_key mistral_api_key xai_api_key].freeze

      def initialize
        @default_adapter = nil
        @default_model = nil
        @api_key_set = false
      end

      # Forward API key setters to RubyLLM configuration
      API_KEY_METHODS.each do |method_name|
        define_method(:"#{method_name}=") do |value|
          require "ruby_llm"
          RubyLLM.configure { |c| c.public_send(:"#{method_name}=", value) }
          @api_key_set = true
        end
      end

      def api_key_set?
        @api_key_set
      end
    end
  end
end
