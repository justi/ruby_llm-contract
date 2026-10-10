# frozen_string_literal: true

module RubyLLM
  module Contract
    module Step
      class ResultBuilder
        # Why the provider stopped, worded for a failed result. Anthropic also
        # reports an exhausted context window as :max_tokens, so the message
        # does not claim max_output was the limit hit.
        FINISH_REASON_ERRORS = {
          max_tokens: "provider reported token-limit termination",
          content_filter: "provider reported content filtering or refusal"
        }.freeze

        # Statuses for `on_incomplete_output :refuse`.
        INCOMPLETE_STATUSES = { max_tokens: :output_truncated, content_filter: :content_filtered }.freeze

        def initialize(contract_definition:, output_type:, output_schema:, model:, observers:, max_output: nil,
                       on_incomplete_output: Dsl::INCOMPLETE_OUTPUT_DEFAULT)
          @contract_definition = contract_definition
          @output_type = output_type
          @output_schema = output_schema
          @model = model
          @observers = observers
          @max_output = max_output
          @on_incomplete_output = on_incomplete_output
        end

        def error_result(error_result:, messages:)
          Result.new(
            status: error_result.status,
            raw_output: error_result.raw_output,
            parsed_output: error_result.parsed_output,
            validation_errors: error_result.validation_errors,
            trace: Trace.new(messages: messages, model: @model, **error_fields(error_result.trace))
          )
        end

        def success_result(response:, messages:, latency_ms:, input:)
          raw_output = response.content
          trace = Trace.new(messages: messages, model: @model, latency_ms: latency_ms, usage: response.usage,
                            **response_accounting(response))
          incomplete = incomplete_result(response, trace)
          return incomplete if incomplete

          validation_result = validate_output(raw_output, input)

          Result.new(
            status: validation_result[:status],
            raw_output: raw_output,
            parsed_output: validation_result[:parsed_output],
            validation_errors: validation_errors(validation_result, response),
            trace: trace,
            observations: observations_for(validation_result, input)
          )
        end

        private

        def error_fields(trace)
          return {} unless trace.respond_to?(:error_class) && trace.error_class

          { error_class: trace.error_class, error_type: trace.error_type }
        end

        # Decided before validation, so neither validate blocks nor observers
        # see a response the step refuses.
        def incomplete_result(response, trace)
          return unless @on_incomplete_output == :refuse

          status = INCOMPLETE_STATUSES[finish_reason(response)]
          return unless status

          Result.new(status: status, raw_output: response.content, parsed_output: nil,
                     validation_errors: [finish_reason_error(finish_reason(response))], trace: trace)
        end

        def finish_reason(response)
          response.respond_to?(:finish_reason) ? response.finish_reason : nil
        end

        def finish_reason_error(reason)
          message = FINISH_REASON_ERRORS[reason]
          return message unless message && reason == :max_tokens && @max_output

          "#{message}; configured max_output: #{@max_output}"
        end

        # Only a failed result says why the provider stopped; a result that
        # passed validation keeps finish_reason in its trace alone.
        def validation_errors(validation_result, response)
          errors = validation_result[:errors]
          return errors if validation_result[:status] == :ok

          message = finish_reason_error(finish_reason(response))
          message ? [*errors, message] : errors
        end

        # Custom adapters may return any object with `content` and `usage`.
        def response_accounting(response)
          response.respond_to?(:trace_accounting) ? response.trace_accounting : {}
        end

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
