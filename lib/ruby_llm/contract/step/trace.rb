# frozen_string_literal: true

module RubyLLM
  module Contract
    module Step
      class Trace
        include Concerns::TraceEquality

        attr_reader :messages, :model, :latency_ms, :usage, :attempts, :cost

        def initialize(messages: nil, model: nil, latency_ms: nil, usage: nil, attempts: nil, cost: nil)
          @messages = messages
          @model = model
          @latency_ms = latency_ms
          @usage = usage
          @attempts = attempts
          @cost = cost || CostCalculator.calculate(model_name: model, usage: usage)
          freeze
        end

        KNOWN_KEYS = %i[messages model latency_ms usage attempts cost].freeze

        def [](key)
          return nil unless KNOWN_KEYS.include?(key.to_sym)

          public_send(key)
        end

        def key?(key)
          KNOWN_KEYS.include?(key.to_sym) && !public_send(key).nil?
        end
        alias has_key? key?

        def merge(**overrides)
          self.class.new(
            messages: overrides.fetch(:messages, @messages),
            model: overrides.fetch(:model, @model),
            latency_ms: overrides.fetch(:latency_ms, @latency_ms),
            usage: overrides.fetch(:usage, @usage),
            attempts: overrides.fetch(:attempts, @attempts),
            cost: overrides.fetch(:cost, @cost)
          )
        end

        def to_h
          { messages: @messages, model: @model, latency_ms: @latency_ms,
            usage: @usage, attempts: @attempts, cost: @cost }.compact
        end

        def to_s
          build_summary_parts.join(" ")
        end

        private

        def build_summary_parts
          parts = [@model || "no-model"]
          parts << "#{@latency_ms}ms" if @latency_ms
          parts << format_token_usage if @usage.is_a?(Hash)
          parts << "$#{format("%.6f", @cost)}" if @cost
          parts
        end

        def format_token_usage
          "#{@usage[:input_tokens] || 0}+#{@usage[:output_tokens] || 0} tokens"
        end
      end
    end
  end
end
