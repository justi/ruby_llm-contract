# frozen_string_literal: true

module RubyLLM
  module Contract
    module Pipeline
      class Result
        attr_reader :status, :step_results, :outputs_by_step, :failed_step, :trace

        # Column widths for pretty_print table
        COL1 = 14   # step name
        COL2 = 10   # status
        COL3 = 50   # output

        TOP_BORDER = "+#{"-" * (COL1 + COL2 + COL3 + 8)}+".freeze
        MID_BORDER = "+-#{"-" * COL1}-+-#{"-" * COL2}-+-#{"-" * COL3}-+".freeze

        def initialize(status:, step_results:, outputs_by_step:, failed_step: nil, trace: Trace.new)
          @status = status
          @step_results = step_results.each(&:freeze).freeze
          @outputs_by_step = outputs_by_step.freeze
          @failed_step = failed_step
          @trace = trace
          freeze
        end

        def ok?
          @status == :ok
        end

        def failed?
          @status != :ok
        end

        def to_s
          lines = [header_line]
          @step_results.each { |sr| lines << step_line(sr) }
          lines.join("\n")
        end

        def pretty_print(io = $stdout)
          build_table.each { |line| io.puts line }
        end

        private

        def build_table
          header_width = COL1 + COL2 + COL3 + 2
          [TOP_BORDER,
           "| #{header_line.ljust(header_width)} |",
           MID_BORDER,
           "| #{"Step".ljust(COL1)} | #{"Status".ljust(COL2)} | #{"Output".ljust(COL3)} |",
           MID_BORDER,
           *build_step_rows,
           TOP_BORDER]
        end

        def build_step_rows
          rows = []
          @step_results.each_with_index do |sr, idx|
            rows.concat(build_single_step_rows(sr))
            rows << MID_BORDER if idx < @step_results.size - 1
          end
          rows
        end

        def build_single_step_rows(step_record)
          step_alias = step_record[:alias].to_s
          status_str = step_status(step_record[:result])
          output_lines = format_output(@outputs_by_step[step_record[:alias]])
          first_row = build_first_step_row(step_alias, status_str, output_lines.first || "")
          continuation_rows = build_continuation_rows(output_lines.drop(1))

          [first_row, *continuation_rows]
        end

        def build_first_step_row(step_alias, status_str, first_line)
          "| #{step_alias.ljust(COL1)} | #{status_str.ljust(COL2)} | #{first_line.ljust(COL3)} |"
        end

        def build_continuation_rows(lines)
          blank_prefix = "| #{" " * COL1} | #{" " * COL2} | "
          lines.map { |line| "#{blank_prefix}#{line.ljust(COL3)} |" }
        end

        def header_line
          parts = ["Pipeline: #{@status}"]
          append_trace_details(parts) if @trace
          parts.join("  ")
        end

        def append_trace_details(parts)
          parts << "#{@step_results.size} steps"
          parts << "#{@trace.total_latency_ms}ms" if @trace.total_latency_ms
          append_usage_details(parts)
          parts << "$#{format("%.6f", @trace.total_cost)}" if @trace.total_cost
          parts << "trace=#{@trace.trace_id&.slice(0, 8)}" if @trace.trace_id
        end

        def append_usage_details(parts)
          usage = @trace.total_usage
          return unless usage.is_a?(Hash)

          parts << "#{usage[:input_tokens]}+#{usage[:output_tokens]} tokens"
        end

        def step_line(step_record)
          step_result = step_record[:result]
          trace = step_result.trace
          status = step_status(step_result)
          trace_str = trace.respond_to?(:to_s) ? trace.to_s : ""
          "  #{step_record[:alias].to_s.ljust(14)} #{status.ljust(10)} #{trace_str}"
        end

        def step_status(step_result)
          step_result.ok? ? "ok" : step_result.status.to_s
        end

        def format_output(output)
          return ["(no output)"] if output.nil?

          pairs = output.is_a?(Hash) ? output : { value: output }
          pairs.map do |key, val|
            str = val.is_a?(String) ? val : val.inspect
            line = "#{key}: #{str}"
            line.size > COL3 ? "#{line[0, COL3 - 3]}..." : line
          end
        end
      end
    end
  end
end
