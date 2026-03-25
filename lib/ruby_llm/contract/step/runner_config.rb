# frozen_string_literal: true

module RubyLLM
  module Contract
    module Step
      RunnerConfig = Data.define(
        :input_type,
        :output_type,
        :prompt_block,
        :contract_definition,
        :adapter,
        :model,
        :output_schema,
        :max_output,
        :max_input,
        :max_cost,
        :on_unknown_pricing,
        :temperature,
        :extra_options,
        :observers
      ) do
        def effective_max_output
          extra_options[:max_tokens] || max_output
        end

        def adapter_options
          { model: model }.tap do |options|
            options[:schema] = output_schema if output_schema
            options[:max_tokens] = effective_max_output if effective_max_output
            options[:temperature] = temperature if temperature
            extra_options.each { |key, value| options[key] = value unless options.key?(key) }
          end
        end
      end
    end
  end
end
