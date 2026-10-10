# frozen_string_literal: true

module RubyLLM
  module Contract
    # Pricing lookup for `max_cost` budget gating + retry usage aggregation.
    #
    # **What this module does (public surface):**
    #
    # 1. **Fine-tune / custom-model pricing registry** — `register_model`
    #    fills a gap RubyLLM still has in 2.x: there is no simple
    #    upstream API to price a model its registry lacks, so fine-tuned
    #    models (e.g. `ft:gpt-4o-custom`) need their pricing supplied
    #    locally. A registered price also overrides RubyLLM's for that id.
    # 2. **Lookup with fallback chain** — `calculate(model_name:, usage:)`
    #    checks the custom registry first, falls back to
    #    `RubyLLM.models.find(model_name)`, returns `nil` on miss.
    #
    # **What this module is NOT:**
    #
    # - Not a substitute for RubyLLM's pricing — for any model in
    #   `RubyLLM.models`, RubyLLM's own `Model#cost_for` does the math.
    # - Not the source of a finished call's cost: the RubyLLM adapter takes
    #   that from the response (`response.cost`), which also covers what
    #   the provider reported and RubyLLM's own retries. This module prices
    #   pre-flight estimates and calls from adapters that report no cost.
    #
    # The reason this module exists at all is the registry + retry usage
    # aggregation across attempts (the latter sits in `Step::RetryExecutor`,
    # which calls `calculate` per attempt and sums; not in this module).
    module CostCalculator
      # Simple struct for custom-registered model pricing
      RegisteredModel = Struct.new(:input_price_per_million, :output_price_per_million, keyword_init: true)

      @custom_models = {}

      # Register pricing for custom or fine-tuned models not in the RubyLLM registry.
      # This is the gem's primary value-add for cost computation; everything
      # else falls back to RubyLLM's own model registry.
      #
      #   CostCalculator.register_model("ft:gpt-4o-custom",
      #     input_per_1m: 3.0, output_per_1m: 6.0)
      #
      def self.register_model(model_name, input_per_1m:, output_per_1m:)
        validate_price!(:input_per_1m, input_per_1m)
        validate_price!(:output_per_1m, output_per_1m)

        @custom_models[model_name] = RegisteredModel.new(
          input_price_per_million: input_per_1m,
          output_price_per_million: output_per_1m
        )
      end

      # Remove a previously registered custom model. Mainly useful in tests.
      def self.unregister_model(model_name)
        @custom_models.delete(model_name)
      end

      # Reset all custom model registrations. Mainly useful in tests.
      def self.reset_custom_models!
        @custom_models.clear
      end

      # Look up cost for a single model + usage hash.
      # Returns nil if model is unknown (custom registry miss + RubyLLM miss),
      # or if any used token category has no price, so callers can decide
      # whether to refuse the call or proceed (see `on_unknown_pricing:` step
      # option for the budget-gating policy).
      #
      #   CostCalculator.calculate(
      #     model_name: "gpt-4o-mini",
      #     usage: { input_tokens: 1_500, output_tokens: 800 }
      #   )
      #   # => 0.00069 (or nil if model not registered)
      #
      # `usage[:input_tokens]` is the whole prompt; `:cache_read_tokens` and
      # `:cache_write_tokens`, when present, are the parts of it served from or
      # written to the provider's prompt cache. `provider:` picks the provider's
      # price for a model id several providers list at different prices.
      #
      # Aggregating across retry attempts is done in `Step::RetryExecutor`,
      # not here.
      def self.calculate(model_name:, usage:, provider: nil)
        return nil unless model_name && usage.is_a?(Hash)

        model_info = find_model(model_name, provider: provider)
        return nil unless model_info

        compute_cost(model_info, usage)
      rescue StandardError
        nil
      end

      def self.registered?(model_name)
        @custom_models.key?(model_name)
      end

      # Two shapes reach here. `RegisteredModel` (our own struct, from
      # `register_model`) exposes flat `*_price_per_million` readers and is
      # priced here. A RubyLLM model is priced by RubyLLM itself
      # (`Model#cost_for`), which knows cache, long-context and per-provider
      # prices and returns nil when a used category has no price.
      #
      # nil means "unknown pricing". `calculate` rescues StandardError, so a
      # future shape neither branch can read also degrades to nil: `max_cost`
      # then refuses the call citing "no pricing data" rather than the real
      # cause, and paths that floor unknown cost to 0.0 (eval cost estimates,
      # report totals) undercount.
      def self.compute_cost(model_info, usage)
        if model_info.respond_to?(:input_price_per_million)
          registered_cost(model_info, usage)
        elsif model_info.respond_to?(:cost_for)
          model_info.cost_for(tokens_for(usage)).total&.round(6)
        end
      end

      # Our registry knows input and output prices only. Cache reads are
      # charged at the input price, which assumes they cost no more than
      # uncached input (true of every provider in RubyLLM's registry, not
      # guaranteed for a custom one). Cache writes can cost more than input
      # (Anthropic charges 1.25x-2x), so a call that wrote to the cache has
      # no price here rather than an undercount.
      def self.registered_cost(model_info, usage)
        return nil if (usage[:cache_write_tokens] || 0).positive?

        input_cost = token_cost(usage[:input_tokens], model_info.input_price_per_million)
        output_cost = token_cost(usage[:output_tokens], model_info.output_price_per_million)
        (input_cost + output_cost).round(6)
      end

      # RubyLLM counts uncached input apart from cache reads and writes; our
      # usage counts them all in input_tokens.
      def self.tokens_for(usage)
        cache_read = usage[:cache_read_tokens] || 0
        cache_write = usage[:cache_write_tokens] || 0
        ::RubyLLM::Tokens.new(
          input: [(usage[:input_tokens] || 0) - cache_read - cache_write, 0].max,
          output: usage[:output_tokens] || 0,
          cache_read: cache_read.positive? ? cache_read : nil,
          cache_write: cache_write.positive? ? cache_write : nil,
          # Priced by RubyLLM only for models with a separate reasoning price.
          thinking: usage[:thinking_tokens]
        )
      end

      # Provider pricing is denominated per 1M tokens; divide here to get
      # the dollar cost for the actual usage count. Named constant for
      # consistency with how RubyLLM and provider docs express prices.
      TOKENS_PER_MILLION = 1_000_000.0

      # `register_model` validates both prices, so neither is nil here.
      def self.token_cost(tokens, price_per_million)
        (tokens || 0) * price_per_million / TOKENS_PER_MILLION
      end

      def self.find_model(model_name, provider: nil)
        # Check custom registry first
        custom = @custom_models[model_name]
        return custom if custom

        return nil unless defined?(RubyLLM)

        provider ? RubyLLM.models.find(model_name, provider: provider) : RubyLLM.models.find(model_name)
      rescue StandardError
        nil
      end

      def self.validate_price!(name, value)
        unless value.is_a?(Numeric) && value.finite? && !value.negative?
          raise ArgumentError, "#{name} must be a finite non-negative number, got #{value.inspect}"
        end
      end

      # `find_model` is intentionally public: `Step::Base#estimate_cost` needs
      # to inspect model pricing before invoking `calculate` (e.g., to short-
      # circuit estimate when the model is unknown). Exposing it removes
      # `CostCalculator.send(:find_model)` workarounds at call sites.
      private_class_method :compute_cost, :registered_cost, :tokens_for, :token_cost, :validate_price!
    end
  end
end
