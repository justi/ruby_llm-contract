# frozen_string_literal: true

module RubyLLM
  module Contract
    module Eval
      # Replaces OpenStruct usage in StepResultNormalizer#normalize_pipeline_result.
      PipelineResultAdapter = Struct.new(:status, :ok_flag, :parsed_output, :validation_errors, :trace) do
        def ok?
          ok_flag
        end
      end
    end
  end
end
