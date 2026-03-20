# frozen_string_literal: true

module RubyLLM
  module Contract
    module Step
      class Result
        attr_reader :status, :raw_output, :parsed_output, :validation_errors, :trace

        def initialize(status:, raw_output:, parsed_output:, validation_errors: [], trace: {})
          @status = status
          @raw_output = raw_output
          @parsed_output = parsed_output
          @validation_errors = validation_errors.freeze
          @trace = trace.freeze
          freeze
        end

        def ok?
          @status == :ok
        end

        def failed?
          @status != :ok
        end

        def to_s
          if ok?
            "#{@status} (#{@trace})"
          else
            errors = @validation_errors.first(3).join(", ")
            errors += ", ..." if @validation_errors.size > 3
            "#{@status}: #{errors}"
          end
        end
      end
    end
  end
end
