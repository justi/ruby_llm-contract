# frozen_string_literal: true

module RubyLLM
  module Contract
    module Eval
      class StepResultNormalizer
        def call(result)
          return result if result.respond_to?(:parsed_output)

          normalize_pipeline_result(result)
        end

        private

        def normalize_pipeline_result(result)
          last_result = result.step_results&.last&.dig(:result)
          successful = result.ok?
          trace = result.respond_to?(:trace) ? result.trace : nil

          PipelineResultAdapter.new(
            status: result.status,
            ok_flag: successful,
            parsed_output: successful ? result.outputs_by_step.values.last : nil,
            validation_errors: validation_errors_for(last_result),
            trace: trace || trace_for(last_result)
          )
        end

        def validation_errors_for(result)
          result.respond_to?(:validation_errors) ? result.validation_errors : []
        end

        def trace_for(result)
          result.respond_to?(:trace) ? result.trace : {}
        end
      end
    end
  end
end
