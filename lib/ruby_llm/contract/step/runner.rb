# frozen_string_literal: true

module RubyLLM
  module Contract
    module Step
      class Runner
        include LimitChecker

        # Two construction forms:
        #   Runner.new(config: a_runner_config)          # preferred — value-object
        #   Runner.new(input_type:, output_type:, ...)   # legacy kwarg form (still supported)
        #
        # The legacy form delegates to `RunnerConfig.build(**kwargs)`, so the
        # defaults live in one place (`RunnerConfig.build`) and the kwarg
        # surface is no longer duplicated here.
        def initialize(config: nil, **kwargs)
          @config = config || RunnerConfig.build(**kwargs)
        end

        def call(input)
          validated_input = input_validator.call(input)
          return validated_input if validated_input.is_a?(Result)

          messages = prompt_compiler.call(input)
        rescue RubyLLM::Contract::Error => e
          Result.new(status: :input_error, raw_output: nil, parsed_output: nil,
                     validation_errors: [e.message])
        else
          execute_pipeline(messages, input)
        end

        private

        def execute_pipeline(messages, input)
          limit_result = check_limits(messages)
          return limit_result if limit_result

          response, latency_ms = adapter_caller.call(messages)
          return result_builder.error_result(error_result: response, messages: messages) if response.is_a?(Result)

          result_builder.success_result(response: response, messages: messages, latency_ms: latency_ms, input: input)
        end

        def input_validator
          InputValidator.new(input_type: @config.input_type)
        end

        def prompt_compiler
          PromptCompiler.new(prompt_block: @config.prompt_block)
        end

        def adapter_caller
          AdapterCaller.new(adapter: @config.adapter, adapter_options: @config.adapter_options)
        end

        def result_builder
          ResultBuilder.new(
            contract_definition: @config.contract_definition,
            output_type: @config.output_type,
            output_schema: @config.output_schema,
            model: @config.model,
            observers: @config.observers
          )
        end

        def max_input
          @config.max_input
        end

        def max_cost
          @config.max_cost
        end

        def model_name
          @config.model
        end

        def on_unknown_pricing
          @config.on_unknown_pricing
        end

        def attachment_token_estimate
          @config.attachment_token_estimate
        end

        def on_unknown_attachment_size
          @config.on_unknown_attachment_size
        end

        def attachment_present?
          opts = @config.extra_options
          !opts.nil? && !opts[:attachment].nil?
        end

        def effective_max_output
          @config.effective_max_output
        end
      end
    end
  end
end
