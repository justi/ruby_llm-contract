# frozen_string_literal: true

module RubyLLM
  module Contract
    # Pricing lookup for `max_cost` budget gating + retry usage aggregation.
    #
    # **What this module does (public surface):**
    #
    # 1. **Fine-tune / custom-model pricing registry** — `register_model`
    #    fills the gap left by RubyLLM 1.14's models.json: there is no
    #    upstream `RubyLLM::Models.register` API, so fine-tuned models
    #    (e.g. `ft:gpt-4o-custom`) need their pricing supplied locally.
    # 2. **Lookup with fallback chain** — `calculate(model_name:, usage:)`
    #    checks the custom registry first, falls back to
    #    `RubyLLM.models.find(model_name)`, returns `nil` on miss.
    #
    # **What this module is NOT:**
    #
    # - Not a "cost calculator" feature — the math itself
    #   (`tokens × price_per_million / 1_000_000`) is trivial and lives
    #   in `private_class_method :compute_cost` for internal use only.
    # - Not a substitute for RubyLLM's pricing data — for any model in
    #   `RubyLLM.models`, this module simply queries it.
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
      # so callers can decide whether to refuse the call or proceed (see
      # `on_unknown_pricing:` step option for the budget-gating policy).
      #
      #   CostCalculator.calculate(
      #     model_name: "gpt-4o-mini",
      #     usage: { input_tokens: 1_500, output_tokens: 800 }
      #   )
      #   # => 0.00069 (or nil if model not registered)
      #
      # Math is intentionally simple and private — this method is the
      # primary public entry point. Aggregating across retry attempts is
      # done in `Step::RetryExecutor`, not here.
      def self.calculate(model_name:, usage:)
        return nil unless model_name && usage.is_a?(Hash)

        model_info = find_model(model_name)
        return nil unless model_info

        compute_cost(model_info, usage)
      rescue StandardError
        nil
      end

      def self.compute_cost(model_info, usage)
        input_cost = token_cost(usage[:input_tokens], model_info.input_price_per_million)
        output_cost = token_cost(usage[:output_tokens], model_info.output_price_per_million)
        (input_cost + output_cost).round(6)
      end

      def self.token_cost(tokens, price_per_million)
        (tokens || 0) * (price_per_million || 0) / 1_000_000.0
      end

      def self.find_model(model_name)
        # Check custom registry first
        custom = @custom_models[model_name]
        return custom if custom

        return nil unless defined?(RubyLLM)

        RubyLLM.models.find(model_name)
      rescue StandardError
        nil
      end

      def self.validate_price!(name, value)
        unless value.is_a?(Numeric) && value.finite? && !value.negative?
          raise ArgumentError, "#{name} must be a finite non-negative number, got #{value.inspect}"
        end
      end

      private_class_method :compute_cost, :token_cost, :find_model, :validate_price!
    end
  end
end
