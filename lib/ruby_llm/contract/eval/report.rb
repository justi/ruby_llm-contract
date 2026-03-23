# frozen_string_literal: true

module RubyLLM
  module Contract
    module Eval
      class Report
        attr_reader :dataset_name, :results

        def initialize(dataset_name:, results:)
          @dataset_name = dataset_name
          @results = results.freeze
          freeze
        end

        def score
          evaluated = evaluated_results
          return 0.0 if evaluated.empty?

          evaluated.sum(&:score) / evaluated.length
        end

        def passed
          evaluated_results.count(&:passed?)
        end

        def failed
          evaluated_results.count(&:failed?)
        end

        def skipped
          results.count { |r| r.step_status == :skipped }
        end

        def failures
          evaluated_results.select(&:failed?)
        end

        def pass_rate
          "#{passed}/#{evaluated_results.length}"
        end

        def total_cost
          results.sum { |r| r.cost || 0.0 }
        end

        def avg_latency_ms
          latencies = results.filter_map(&:duration_ms)
          return nil if latencies.empty?

          latencies.sum.to_f / latencies.length
        end

        def passed?
          evaluated = evaluated_results
          return false if evaluated.empty?

          evaluated.all?(&:passed?)
        end

        def each(&)
          results.each(&)
        end

        def summary
          parts = ["#{dataset_name}: #{pass_rate} checks passed"]
          parts << "#{skipped} skipped" if skipped.positive?
          parts << format_cost(total_cost) if total_cost.positive?
          parts.join(", ")
        end

        GENERIC_DETAILS = ["passed", "not passed"].freeze

        def to_s
          lines = [summary]
          failures.each do |result|
            lines << format_failure(result)
          end
          lines.join("\n")
        end

        def print_summary(io = $stdout)
          io.puts summary
          io.puts
          results.each do |result|
            icon = result.label
            cost_str = result.cost ? "  #{format_cost(result.cost)}" : ""
            latency_str = result.duration_ms ? "  #{result.duration_ms}ms" : ""
            io.puts "  #{icon}  #{result.name}#{cost_str}#{latency_str}"
            io.puts "        #{result.details}" if result.failed? && useful_details?(result.details)
          end
        end

        private

        def format_failure(result)
          line = "  FAIL  #{result.name}"
          line += ": #{result.details}" if useful_details?(result.details)
          line
        end

        def useful_details?(details)
          details && !GENERIC_DETAILS.include?(details)
        end

        def evaluated_results
          results.reject { |r| r.step_status == :skipped }
        end

        def format_cost(cost)
          "$#{format("%.6f", cost)}"
        end
      end
    end
  end
end
