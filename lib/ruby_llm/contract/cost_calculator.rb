# frozen_string_literal: true

module RubyLLM
  module Contract
    module CostCalculator
      # Simple struct for custom-registered model pricing
      RegisteredModel = Struct.new(:input_price_per_million, :output_price_per_million, keyword_init: true)

      @custom_models = {}

      # Register pricing for custom or fine-tuned models not in the RubyLLM registry.
      #
      #   CostCalculator.register_model("ft:gpt-4o-custom",
      #     input_per_1m: 3.0, output_per_1m: 6.0)
      #
      def self.register_model(model_name, input_per_1m:, output_per_1m:)
        raise ArgumentError, "input_per_1m must be non-negative, got #{input_per_1m}" if input_per_1m.negative?
        raise ArgumentError, "output_per_1m must be non-negative, got #{output_per_1m}" if output_per_1m.negative?

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

      private_class_method :compute_cost, :token_cost, :find_model
    end
  end
end
