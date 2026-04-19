# frozen_string_literal: true

require "forwardable"

module RubyLLM
  module Contract
    module Eval
      class Report
        extend Forwardable

        attr_reader :dataset_name, :results, :step_name

        GENERIC_DETAILS = ["passed", "not passed"].freeze
        HISTORY_DIR = ".eval_history"
        BASELINE_DIR = ".eval_baselines"

        def_delegators :@stats, :score, :passed, :failed, :skipped, :failures, :pass_rate, :pass_rate_ratio,
                       :total_cost, :avg_latency_ms, :passed?,
                       :production_mode?, :escalation_rate, :single_shot_cost, :single_shot_latency_ms,
                       :effective_cost, :effective_latency_ms, :latency_percentiles
        def_delegators :@presenter, :summary, :to_s, :print_summary
        def_delegators :@storage, :save_history!, :eval_history, :save_baseline!, :compare_with_baseline,
                       :baseline_exists?

        def initialize(dataset_name:, results:, step_name: nil)
          @dataset_name = dataset_name
          @step_name = step_name
          @results = results.dup.freeze
          @stats = ReportStats.new(results: @results)
          @presenter = ReportPresenter.new(report: self, stats: @stats)
          @storage = ReportStorage.new(report: self, stats: @stats)
          freeze
        end

        def each(&block)
          results.each(&block)
        end
      end
    end
  end
end
