# frozen_string_literal: true

module RubyLLM
  module Contract
    module Step
      class ResultBuilder
        def initialize(contract_definition:, output_type:, output_schema:, model:, observers:)
          @contract_definition = contract_definition
          @output_type = output_type
          @output_schema = output_schema
          @model = model
          @observers = observers
        end

        def error_result(error_result:, messages:)
          Result.new(
            status: error_result.status,
            raw_output: error_result.raw_output,
            parsed_output: error_result.parsed_output,
            validation_errors: error_result.validation_errors,
            trace: Trace.new(messages: messages, model: @model)
          )
        end

        def success_result(response:, messages:, latency_ms:, input:)
          raw_output = response.content
          validation_result = validate_output(raw_output, input)
          trace = Trace.new(messages: messages, model: @model, latency_ms: latency_ms, usage: response.usage)

          Result.new(
            status: validation_result[:status],
            raw_output: raw_output,
            parsed_output: validation_result[:parsed_output],
            validation_errors: validation_result[:errors],
            trace: trace,
            observations: observations_for(validation_result, input)
          )
        end

        private

        def observations_for(validation_result, input)
          return [] unless validation_result[:status] == :ok && @observers.any?

          Validator.run_observations(@observers, validation_result[:parsed_output], input: input)
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
