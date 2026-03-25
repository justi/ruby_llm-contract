# frozen_string_literal: true

module RubyLLM
  module Contract
    module Step
      class Result
        attr_reader :status, :raw_output, :parsed_output, :validation_errors, :trace, :observations

        def initialize(status:, raw_output:, parsed_output:, validation_errors: [], trace: nil, observations: [])
          @status = status
          @raw_output = raw_output
          @parsed_output = parsed_output
          @validation_errors = validation_errors.freeze
          @observations = observations.freeze
          @trace = normalize_trace(trace)
          freeze
        end

        def ok?
          @status == :ok
        end

        def failed?
          @status != :ok
        end

        private

        def normalize_trace(trace)
          case trace
          when Trace then trace
          when Hash then Trace.new(**trace)
          when nil then Trace.new
          else trace
          end.freeze
        end

        public

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
