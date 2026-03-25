# frozen_string_literal: true

require "json"
require "fileutils"

module RubyLLM
  module Contract
    module Eval
      # Persists eval reports as history entries and regression baselines.
      class ReportStorage
        def initialize(report:, stats:)
          @report = report
          @stats = stats
        end

        def save_history!(path: nil, model: nil)
          file = path || storage_path(Report::HISTORY_DIR, "jsonl", model: model)
          EvalHistory.append(file, history_entry)
          file
        end

        def eval_history(path: nil, model: nil)
          EvalHistory.load(path || storage_path(Report::HISTORY_DIR, "jsonl", model: model))
        end

        def save_baseline!(path: nil, model: nil)
          file = path || storage_path(Report::BASELINE_DIR, "json", model: model)
          FileUtils.mkdir_p(File.dirname(file))
          File.write(file, JSON.pretty_generate(serialize_for_baseline))
          file
        end

        def compare_with_baseline(path: nil, model: nil)
          file = path || storage_path(Report::BASELINE_DIR, "json", model: model)
          raise ArgumentError, "No baseline found at #{file}" unless File.exist?(file)

          baseline_data = JSON.parse(File.read(file), symbolize_names: true)
          validate_baseline!(baseline_data)

          BaselineDiff.new(
            baseline_cases: baseline_data[:cases],
            current_cases: @report.results.map { |result| serialize_case(result) }
          )
        end

        def baseline_exists?(path: nil, model: nil)
          File.exist?(path || storage_path(Report::BASELINE_DIR, "json", model: model))
        end

        private

        def history_entry
          {
            date: Time.now.strftime("%Y-%m-%d"),
            score: @stats.score,
            total_cost: @stats.total_cost,
            pass_rate: @stats.pass_rate,
            cases_count: @stats.evaluated_results_count
          }
        end

        def serialize_for_baseline
          {
            dataset_name: @report.dataset_name,
            step_name: @report.step_name,
            score: @stats.score,
            total_cost: @stats.total_cost,
            cases: @stats.evaluated_results.map { |result| serialize_case(result) }
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

        def storage_path(root_dir, extension, model:)
          parts = [root_dir]
          parts << sanitize_name(@report.step_name) if @report.step_name

          dataset_name = sanitize_name(@report.dataset_name)
          dataset_name = "#{dataset_name}_#{sanitize_name(model)}" if model

          File.join(*parts, "#{dataset_name}.#{extension}")
        end

        def validate_baseline!(data)
          if data[:dataset_name] && data[:dataset_name] != @report.dataset_name
            raise ArgumentError, "Baseline eval '#{data[:dataset_name]}' does not match '#{@report.dataset_name}'"
          end
          if data[:step_name] && @report.step_name && data[:step_name] != @report.step_name
            raise ArgumentError, "Baseline step '#{data[:step_name]}' does not match '#{@report.step_name}'"
          end
        end

        def sanitize_name(name)
          name.to_s.gsub(/[^a-zA-Z0-9_-]/, "_")
        end
      end
    end
  end
end
