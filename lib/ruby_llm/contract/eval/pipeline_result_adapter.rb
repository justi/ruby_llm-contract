# frozen_string_literal: true

module RubyLLM
  module Contract
    module Eval
      # Lightweight adapter that wraps a Pipeline::Result to look like a Step::Result.
      # Replaces OpenStruct usage in Runner#normalize_pipeline_result.
      PipelineResultAdapter = Struct.new(:status, :ok_flag, :parsed_output, :validation_errors, :trace) do
        def ok?
          ok_flag
        end
      end
    end
  end
end
