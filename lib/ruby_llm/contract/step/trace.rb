# frozen_string_literal: true

module RubyLLM
  module Contract
    module Step
      class Trace
        include Concerns::TraceEquality
        include Concerns::DeepFreeze

        attr_reader :messages, :model, :latency_ms, :usage, :attempts, :cost,
                    :usage_complete, :cost_complete, :finish_reason, :error_class, :error_type

        # Marks `cost:` as not given, as distinct from an explicit nil. Only an
        # omitted cost is priced from the registry; nil from an adapter that
        # reports its own cost means "unknown" and must stay unknown.
        COST_UNSET = Object.new.freeze

        # usage_complete / cost_complete are nil for traces that carry no
        # accounting state (Test adapter, older adapters, hand-built traces);
        # those keep the token-count rule in `unpriced?`.
        # error_class names the exception behind an :adapter_error and is part
        # of to_h; error_type is the class itself, kept in memory only so
        # `retry_on SomeError` can match subclasses. A trace rebuilt from a
        # hash has the name but not the class.
        def initialize(messages: nil, model: nil, latency_ms: nil, usage: nil, attempts: nil, cost: COST_UNSET,
                       usage_complete: nil, cost_complete: nil, finish_reason: nil, error_class: nil, error_type: nil)
          @messages = deep_dup_freeze(messages)
          @model = model.frozen? ? model : model&.dup&.freeze
          @latency_ms = latency_ms
          @usage = deep_dup_freeze(usage)
          @attempts = deep_dup_freeze(attempts)
          @usage_complete = usage_complete
          @cost_complete = cost_complete
          @finish_reason = finish_reason
          @error_class = error_class
          @error_type = error_type
          @cost = resolve_cost(cost)
          @keep_nil_cost = keep_nil_cost?(cost)
          freeze
        end

        KNOWN_KEYS = %i[messages model latency_ms usage attempts cost
                        usage_complete cost_complete finish_reason error_class].freeze

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

        # Never re-prices: a retry merges a subtotal and an aggregate usage that
        # no single model's pricing describes.
        def merge(**overrides)
          self.class.new(**KNOWN_KEYS.to_h { |key| [key, overrides.fetch(key) { public_send(key) }] },
                         error_type: overrides.fetch(:error_type, @error_type))
        end

        # True when a total built from this trace undercounts: the adapter said
        # its cost does not cover the call, or (no accounting state) a call ran
        # on a named model, used tokens, and still got no cost. A zero-token call
        # (Test adapter, sample_response) costs 0 whatever the pricing. A retried
        # step is judged per attempt: a priced subtotal must not hide an unpriced
        # attempt.
        def cost_unknown?
          return true if @cost_complete == false

          if @attempts.is_a?(Array) && !@attempts.empty?
            @attempts.any? do |attempt|
              attempt[:cost_unknown] || self.class.unpriced?(attempt[:model], attempt[:usage], attempt[:cost])
            end
          else
            @cost_complete.nil? && self.class.unpriced?(@model, @usage, @cost)
          end
        end

        def self.unpriced?(model, usage, cost)
          return false unless model && cost.nil? && usage.is_a?(Hash)

          ((usage[:input_tokens] || 0) + (usage[:output_tokens] || 0)).positive?
        end

        def to_h
          hash = { messages: @messages, model: @model, latency_ms: @latency_ms,
                   usage: @usage, attempts: @attempts, cost: @cost, usage_complete: @usage_complete,
                   cost_complete: @cost_complete, finish_reason: @finish_reason, error_class: @error_class }.compact
          hash[:cost] = nil if @keep_nil_cost
          hash
        end

        def to_s
          build_summary_parts.join(" ")
        end

        private

        # A given nil cost that the registry would price must stay `cost: nil` in
        # to_h, or `Trace.new(**to_h)` would come back priced. Otherwise it is
        # left out, so a merged trace compares equal to the one it came from.
        def keep_nil_cost?(cost)
          return false unless cost.nil? && @cost_complete.nil?

          !CostCalculator.calculate(model_name: @model, usage: @usage).nil?
        end

        def resolve_cost(cost)
          return cost unless cost.equal?(COST_UNSET)
          return nil unless @cost_complete.nil?

          CostCalculator.calculate(model_name: @model, usage: @usage)
        end

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
