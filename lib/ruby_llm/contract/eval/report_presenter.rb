# frozen_string_literal: true

module RubyLLM
  module Contract
    module Eval
      # Formats eval reports for console and string output.
      class ReportPresenter
        def initialize(report:, stats:)
          @report = report
          @stats = stats
        end

        def summary
          summary_parts.join(", ")
        end

        def to_s
          ([summary] + @stats.failures.map { |result| format_failure(result) }).join("\n")
        end

        def print_summary(io = $stdout)
          io.puts summary
          io.puts
          @report.results.each { |result| print_result(io, result) }
        end

        private

        def summary_parts
          parts = ["#{@report.dataset_name}: #{@stats.pass_rate} checks passed"]
          parts << "#{@stats.skipped} skipped" if @stats.skipped.positive?
          parts << format_cost(@stats.total_cost) if @stats.total_cost.positive?
          parts
        end

        def format_failure(result)
          line = "  FAIL  #{result.name}"
          line += ": #{result.details}" if useful_details?(result.details)
          line
        end

        def print_result(io, result)
          io.puts "  #{result.label}  #{result.name}#{result_cost(result)}#{result_latency(result)}"
          io.puts "        #{result.details}" if result.failed? && useful_details?(result.details)
        end

        def useful_details?(details)
          details && !Report::GENERIC_DETAILS.include?(details)
        end

        def result_cost(result)
          result.cost ? "  #{format_cost(result.cost)}" : ""
        end

        def result_latency(result)
          result.duration_ms ? "  #{result.duration_ms}ms" : ""
        end

        def format_cost(cost)
          "$#{format("%.6f", cost)}"
        end
      end
    end
  end
end
