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

          results.sum { |result| result[:score] } / results.length
        end

        def passed
          results.count { |result| result[:passed] }
        end

        def failed
          results.count { |result| !result[:passed] }
        end

        def pass_rate
          "#{passed}/#{results.length}"
        end

        def passed?
          results.all? { |result| result[:passed] }
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
          results.reject { |result| result[:passed] }.each do |result|
            lines << format_failure(result)
          end
          lines.join("\n")
        end

        def pretty_print(io = $stdout)
          io.puts summary
          io.puts
          results.each do |result|
            icon = result[:passed] ? "PASS" : "FAIL"
            io.puts "  #{icon}  #{result[:case_name]}"
            io.puts "        #{result[:details]}" if !result[:passed] && useful_details?(result[:details])
          end
        end

        private

        def format_failure(result)
          line = "  FAIL  #{result[:case_name]}"
          line += ": #{result[:details]}" if useful_details?(result[:details])
          line
        end

        def useful_details?(details)
          details && !GENERIC_DETAILS.include?(details)
        end
      end
    end
  end
end
