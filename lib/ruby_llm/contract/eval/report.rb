# frozen_string_literal: true

require "json"
require "fileutils"

module RubyLLM
  module Contract
    module Eval
      class Report
        attr_reader :dataset_name, :results

        def initialize(dataset_name:, results:, step_name: nil)
          @dataset_name = dataset_name
          @step_name = step_name
          @results = results.dup.freeze
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

        def save_baseline!(path: nil, model: nil)
          file = path || default_baseline_path(model: model)
          FileUtils.mkdir_p(File.dirname(file))
          File.write(file, JSON.pretty_generate(serialize_for_baseline))
          file
        end

        def compare_with_baseline(path: nil, model: nil)
          file = path || default_baseline_path(model: model)
          raise ArgumentError, "No baseline found at #{file}" unless File.exist?(file)

          baseline_data = JSON.parse(File.read(file), symbolize_names: true)
          validate_baseline!(baseline_data)
          BaselineDiff.new(
            baseline_cases: baseline_data[:cases],
            current_cases: results.map { |r| serialize_case(r) }
          )
        end

        def baseline_exists?(path: nil, model: nil)
          File.exist?(path || default_baseline_path(model: model))
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

        def default_baseline_path(model: nil)
          parts = [".eval_baselines"]
          parts << sanitize_name(@step_name) if @step_name
          name = sanitize_name(dataset_name)
          name = "#{name}_#{sanitize_name(model)}" if model
          parts << "#{name}.json"
          File.join(*parts)
        end

        def validate_baseline!(data)
          if data[:dataset_name] && data[:dataset_name] != dataset_name
            raise ArgumentError, "Baseline eval '#{data[:dataset_name]}' does not match '#{dataset_name}'"
          end
          if data[:step_name] && @step_name && data[:step_name] != @step_name
            raise ArgumentError, "Baseline step '#{data[:step_name]}' does not match '#{@step_name}'"
          end
        end

        def sanitize_name(name)
          name.to_s.gsub(/[^a-zA-Z0-9_-]/, "_")
        end

        def serialize_for_baseline
          {
            dataset_name: dataset_name,
            step_name: @step_name,
            score: score,
            total_cost: total_cost,
            cases: evaluated_results.map { |r| serialize_case(r) }
          }
        end

        def serialize_case(result)
          {
            name: result.name,
            passed: result.passed?,
            score: result.score,
            details: result.details,
            cost: result.cost
          }
        end

        def format_cost(cost)
          "$#{format("%.6f", cost)}"
        end
      end
    end
  end
end
