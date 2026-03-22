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
          return 0.0 if results.empty?

          results.sum(&:score) / results.length
        end

        def passed
          results.count(&:passed?)
        end

        def failed
          results.count(&:failed?)
        end

        def failures
          results.select(&:failed?)
        end

        def pass_rate
          "#{passed}/#{results.length}"
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
          return false if results.empty?

          results.all?(&:passed?)
        end

        def each(&)
          results.each(&)
        end

        def summary
          parts = ["#{dataset_name}: #{pass_rate} checks passed"]
          parts << format_cost(total_cost) if total_cost > 0
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
            icon = result.passed? ? "PASS" : "FAIL"
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

        def format_cost(cost)
          "$#{format("%.4f", cost)}"
        end
      end
    end
  end
end
