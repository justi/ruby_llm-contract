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
        :attachment_token_estimate,
        :on_unknown_attachment_size,
        :temperature,
        :extra_options,
        :observers,
        :on_incomplete_output,
        :token_count
      ) do
        # Factory with sensible defaults for optional fields. Lets callers
        # (Step::Base#run_once and tests) construct a RunnerConfig without
        # repeating the 11-default boilerplate, and gives `Runner.new(config:)`
        # a clean entry point for the value-object form.
        def self.build(input_type:, output_type:, prompt_block:, contract_definition:,
                       adapter:, model:,
                       output_schema: nil, max_output: nil,
                       max_input: nil, max_cost: nil, on_unknown_pricing: UnknownPolicy::DEFAULT,
                       attachment_token_estimate: nil, on_unknown_attachment_size: UnknownPolicy::DEFAULT,
                       temperature: nil, extra_options: {}, observers: [],
                       on_incomplete_output: Dsl::INCOMPLETE_OUTPUT_DEFAULT, token_count: Dsl::TOKEN_COUNT_DEFAULT)
          new(
            input_type: input_type, output_type: output_type,
            prompt_block: prompt_block, contract_definition: contract_definition,
            adapter: adapter, model: model,
            output_schema: output_schema, max_output: max_output,
            max_input: max_input, max_cost: max_cost,
            on_unknown_pricing: on_unknown_pricing,
            attachment_token_estimate: attachment_token_estimate,
            on_unknown_attachment_size: on_unknown_attachment_size,
            temperature: temperature, extra_options: extra_options,
            observers: observers, on_incomplete_output: on_incomplete_output, token_count: token_count
          )
        end

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
