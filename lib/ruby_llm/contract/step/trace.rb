# frozen_string_literal: true

module RubyLLM
  module Contract
    module Step
      class Trace
        include Concerns::TraceEquality
        include Concerns::DeepFreeze

        attr_reader :messages, :model, :latency_ms, :usage, :attempts, :cost

        def initialize(messages: nil, model: nil, latency_ms: nil, usage: nil, attempts: nil, cost: nil)
          @messages = deep_dup_freeze(messages)
          @model = model.frozen? ? model : model&.dup&.freeze
          @latency_ms = latency_ms
          @usage = deep_dup_freeze(usage)
          @attempts = deep_dup_freeze(attempts)
          @cost = cost || CostCalculator.calculate(model_name: model, usage: usage)
          freeze
        end

        KNOWN_KEYS = %i[messages model latency_ms usage attempts cost].freeze

        def [](key)
          return nil unless KNOWN_KEYS.include?(key.to_sym)

          public_send(key)
        end

        def dig(key, *rest)
          value = self[key]
          return value if rest.empty? || value.nil?

          value.dig(*rest)
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

        # True when a call ran on a named model, used tokens, and still got no
        # cost, so any total built from this trace undercounts. A zero-token call
        # (Test adapter, sample_response) costs 0 whatever the pricing. A retried
        # step is judged per attempt: a priced subtotal must not hide an unpriced
        # attempt, and the merged trace may have re-priced on the last model.
        def cost_unknown?
          if @attempts.is_a?(Array) && !@attempts.empty?
            @attempts.any? { |attempt| self.class.unpriced?(attempt[:model], attempt[:usage], attempt[:cost]) }
          else
            self.class.unpriced?(@model, @usage, @cost)
          end
        end

        def self.unpriced?(model, usage, cost)
          return false unless model && cost.nil? && usage.is_a?(Hash)

          ((usage[:input_tokens] || 0) + (usage[:output_tokens] || 0)).positive?
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
