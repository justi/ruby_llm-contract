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

        def passed?
          return false if results.empty?

          results.all?(&:passed?)
        end

        def each(&)
          results.each(&)
        end

        def summary
          "#{dataset_name}: #{pass_rate} checks passed"
        end

        GENERIC_DETAILS = ["passed", "not passed"].freeze

        def to_s
          lines = [summary]
          failures.each do |result|
            lines << format_failure(result)
          end
          lines.join("\n")
        end

        def pretty_print(io = $stdout)
          io.puts summary
          io.puts
          results.each do |result|
            icon = result.passed? ? "PASS" : "FAIL"
            io.puts "  #{icon}  #{result.name}"
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
      end
    end
  end
end
