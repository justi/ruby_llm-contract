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

          # `with: nil` adds no attachment. The text is never nil (`fetch(:content, "")`),
          # and RubyLLM raises only when both text and attachments are nil.
          response = chat.ask(
            conversation.last&.fetch(:content, ""),
            with: options[:attachment]
          )
          build_response(response, options[:model])
        end

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
          opts[:provider] = options[:provider] if options.key?(:provider)
          opts[:assume_model_exists] = options[:assume_model_exists] if options.key?(:assume_model_exists)
          opts
        end

        def apply_chat_options(chat, options)
          CHAT_OPTION_METHODS.each do |key, method_name|
            chat.public_send(method_name, options[key]) if options[key]
          end

          # Resolve thinking config from BOTH sources, with `:reasoning_effort`
          # taking precedence over `:thinking[:effort]`. This is the per-attempt
          # override path used by `retry_policy { escalate({model:, reasoning_effort:}) }`
          # — the attempt-specific effort must win over the class-level default.
          # Forwarded provider-agnostically via `chat.with_thinking(**)`.
          thinking_config = resolve_thinking_config(options)
          chat.with_thinking(**thinking_config) if thinking_config

          # RubyLLM 2.0 removed `with_params`; `with_max_output_tokens` is the
          # replacement for this one passthrough. `reasoning_effort` is not
          # forwarded here — it goes through `with_thinking` above.
          chat.with_max_output_tokens(options[:max_tokens]) if options[:max_tokens]
        end

        # Returns merged `{ effort:, budget: }` or nil. `options[:reasoning_effort]`
        # overrides any inherited `options[:thinking][:effort]`; budget is
        # taken from `options[:thinking][:budget]` only.
        def resolve_thinking_config(options)
          base = options[:thinking].is_a?(Hash) ? options[:thinking].dup : {}
          base[:effort] = options[:reasoning_effort] if options[:reasoning_effort]
          base.empty? ? nil : base
        end

        def build_response(response, model)
          content = response.content
          content = content.to_s unless content.is_a?(Hash) || content.is_a?(Array)

          # This is the ONLY place upstream token counts are read. The
          # `{ input_tokens:, output_tokens: }` shape is this gem's public
          # contract (Step::Trace#usage, README) and does not change; RubyLLM's
          # own counts go into it as described in `usage_from`.
          tokens = response.tokens
          usage_complete = every_attempt_counted?(response, tokens)
          reported = tokens&.reported_cost
          usage = usage_from(tokens)
          cost = call_cost(response, model, usage, reported)

          Response.new(
            content: content,
            usage: usage,
            cost: cost,
            usage_complete: usage_complete,
            # A cost RubyLLM priced from partial counts covers part of the call;
            # one the provider reported covers all of it.
            cost_complete: !cost.nil? && (usage_complete || !reported.nil?),
            finish_reason: response.finish_reason
          )
        end

        # `response.tokens` sums RubyLLM's attempts at the request, skipping
        # counts an attempt never got, so the sum alone can look complete.
        # RubyLLM records each attempt; one that failed after the provider may
        # have billed it keeps nil counts, one never sent or refused gets zeros.
        def every_attempt_counted?(response, tokens)
          entries = response.respond_to?(:ruby_llm_usage_entries) ? Array(response.ruby_llm_usage_entries) : []
          return entries.all? { |entry| reported_both_counts?(entry.tokens) } if entries.any?

          reported_both_counts?(tokens)
        end

        # Zero is a reported count (a full cache hit leaves uncached input at 0);
        # nil is a count the provider did not send.
        def reported_both_counts?(tokens)
          !tokens.nil? && !tokens.input.nil? && !tokens.output.nil?
        end

        # RubyLLM 2.x counts `input` without the prompt-cache tokens, which it
        # reports apart as `cache_read` / `cache_write`. Our input_tokens is the
        # whole prompt, so they are added back and also kept as a breakdown.
        # `output` already includes thinking tokens when the provider bills them
        # as output, so `thinking_tokens` is a breakdown, never added. A count
        # the provider did not report is 0 here; `usage_complete` says so.
        def usage_from(tokens)
          return { input_tokens: 0, output_tokens: 0 } unless tokens

          cache_read = tokens.cache_read.to_i
          cache_write = tokens.cache_write.to_i
          usage = { input_tokens: tokens.input.to_i + cache_read + cache_write, output_tokens: tokens.output.to_i }
          usage[:cache_read_tokens] = cache_read if cache_read.positive?
          usage[:cache_write_tokens] = cache_write if cache_write.positive?
          usage[:thinking_tokens] = tokens.thinking.to_i if tokens.thinking.to_i.positive?
          usage
        end

        # RubyLLM prices the response itself: per provider, with cache and
        # long-context prices, the amount the provider reported when it did,
        # and its own retries of the request. It returns nil when it cannot
        # price every attempt. A price set with `register_model` still wins
        # for its id, unless the provider reported what it billed; it prices
        # the summed counts, so it is complete only when every attempt was
        # counted (`cost_complete` in build_response).
        def call_cost(response, model, usage, reported)
          if reported.nil? && CostCalculator.registered?(model)
            CostCalculator.calculate(model_name: model, usage: usage)
          else
            response.cost.total&.round(6)
          end
        rescue StandardError
          nil
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
