# frozen_string_literal: true

module RubyLLM
  module Contract
    module Step
      class Runner
        include LimitChecker

        # rubocop:disable Metrics/ParameterLists
        def initialize(input_type:, output_type:, prompt_block:, contract_definition:,
                       adapter:, model:, output_schema: nil, max_output: nil,
                       max_input: nil, max_cost: nil)
          @input_type = input_type
          @output_type = output_type
          @prompt_block = prompt_block
          @contract_definition = contract_definition
          @adapter = adapter
          @model = model
          @output_schema = output_schema
          @max_output = max_output
          @max_input = max_input
          @max_cost = max_cost
        end
        # rubocop:enable Metrics/ParameterLists

        def call(input)
          validated_input = validate_input(input)
          return validated_input if validated_input.is_a?(Result)

          messages = build_and_render_prompt(input)
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

          response, latency_ms = execute_adapter(messages)
          return build_error_result(response, messages) if response.is_a?(Result)

          build_result(response, messages, latency_ms, input)
        end

        def validate_input(input)
          type = @input_type
          if type.is_a?(Class) && !type.respond_to?(:[])
            raise TypeError, "#{input.inspect} is not a #{type}" unless input.is_a?(type)
          else
            type[input]
          end
          nil
        rescue Dry::Types::CoercionError, TypeError, ArgumentError => e
          Result.new(status: :input_error, raw_output: nil, parsed_output: nil, validation_errors: [e.message])
        end

        def build_and_render_prompt(input)
          dynamic = @prompt_block.arity >= 1
          ast = Prompt::Builder.build(input: dynamic ? input : nil, &@prompt_block)

          Prompt::Renderer.render(ast, variables: dynamic ? {} : template_variables_for(input))
        rescue StandardError => e
          raise RubyLLM::Contract::Error, "Prompt build failed: #{e.class}: #{e.message}"
        end

        def template_variables_for(input)
          base = { input: input }
          input.is_a?(Hash) ? base.merge(input.transform_keys(&:to_sym)) : base
        end

        def execute_adapter(messages)
          start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          response = @adapter.call(messages: messages, **build_adapter_options)
          latency_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time) * 1000).round
          [response, latency_ms]
        rescue StandardError => e
          [Result.new(status: :adapter_error, raw_output: nil, parsed_output: nil, validation_errors: [e.message]), 0]
        end

        def build_adapter_options
          { model: @model }.tap do |opts|
            opts[:schema] = @output_schema if @output_schema
            opts[:max_tokens] = @max_output if @max_output
          end
        end

        def build_error_result(error_result, messages)
          Result.new(
            status: error_result.status,
            raw_output: error_result.raw_output,
            parsed_output: error_result.parsed_output,
            validation_errors: error_result.validation_errors,
            trace: Trace.new(messages: messages, model: @model)
          )
        end

        def build_result(response, messages, latency_ms, input)
          raw_output = response.content
          validation_result = validate_output(raw_output, input)
          trace = Trace.new(messages: messages, model: @model, latency_ms: latency_ms, usage: response.usage)

          Result.new(
            status: validation_result[:status],
            raw_output: raw_output,
            parsed_output: validation_result[:parsed_output],
            validation_errors: validation_result[:errors],
            trace: trace
          )
        end

        def validate_output(raw_output, input)
          Validator.validate(
            raw_output: raw_output,
            definition: @contract_definition,
            output_type: @output_type,
            input: input,
            schema: @output_schema
          )
        end
      end
    end
  end
end
