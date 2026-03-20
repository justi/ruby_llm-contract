# frozen_string_literal: true

module RubyLLM
  module Contract
    module CostCalculator
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
        return nil unless defined?(RubyLLM)

        RubyLLM.models.find(model_name)
      rescue StandardError
        nil
      end

      private_class_method :compute_cost, :token_cost, :find_model
    end
  end
end
