# frozen_string_literal: true

require "ruby_llm"

module RubyLLM
  module Contract
    module Adapters
      class RubyLLM < Base
        def call(messages:, **options)
          system_contents, conversation = partition_messages(messages)
          conversation = fallback_conversation(system_contents, conversation)

          chat = build_chat(options, system_contents)
          add_history(chat, conversation[0..-2])

          response = chat.ask(conversation.last&.fetch(:content, ""))
          build_response(response)
        end

        # Maps option keys to the RubyLLM chat method and argument form.
        CHAT_OPTION_METHODS = {
          temperature: :with_temperature,
          schema: :with_schema
        }.freeze

        private

        # When prompt has only system/section/rule nodes and no user message,
        # pop the last system message and use it as the user ask.
        def fallback_conversation(system_contents, conversation)
          return conversation unless conversation.empty?

          content = system_contents.any? ? system_contents.pop : ""
          [{ role: :user, content: content }]
        end

        def build_chat(options, system_contents)
          chat = ::RubyLLM.chat(**chat_constructor_options(options))
          chat.with_instructions(system_contents.join("\n\n")) if system_contents.any?
          apply_chat_options(chat, options)
          chat
        end

        def chat_constructor_options(options)
          opts = { model: options[:model] }
          opts[:provider] = options[:provider] if options[:provider]
          opts[:assume_model_exists] = options[:assume_model_exists] if options[:assume_model_exists]
          opts
        end

        def apply_chat_options(chat, options)
          CHAT_OPTION_METHODS.each do |key, method_name|
            chat.public_send(method_name, options[key]) if options[key]
          end
          chat.with_params(max_tokens: options[:max_tokens]) if options[:max_tokens]
        end

        def build_response(response)
          content = response.content
          content = content.to_s unless content.is_a?(Hash) || content.is_a?(Array)

          Response.new(
            content: content,
            usage: {
              input_tokens: response.input_tokens || 0,
              output_tokens: response.output_tokens || 0
            }
          )
        end

        def partition_messages(messages)
          system_contents = []
          conversation = []

          messages.each do |msg|
            if msg[:role] == :system
              system_contents << msg[:content]
            else
              conversation << msg
            end
          end

          [system_contents, conversation]
        end

        def add_history(chat, messages)
          messages&.each do |msg|
            chat.add_message(role: msg[:role], content: msg[:content])
          end
        end
      end
    end
  end
end
