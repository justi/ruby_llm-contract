# frozen_string_literal: true

require "rake"
require "rake/tasklib"

module RubyLLM
  module Contract
    class RakeTask < ::Rake::TaskLib
      attr_accessor :name, :context, :fail_on_empty, :minimum_score, :maximum_cost,
                    :eval_dirs, :save_baseline, :fail_on_regression, :track_history

      def initialize(name = :"ruby_llm_contract:eval", &block)
        super()
        @name = name
        @context = {}
        @fail_on_empty = true
        @minimum_score = nil # nil = require 100%; float = threshold
        @maximum_cost = nil  # nil = no cost limit; float = budget cap (suite-level)
        @eval_dirs = []      # directories to load eval files from (non-Rails)
        @save_baseline = false
        @fail_on_regression = false
        @track_history = false
        block&.call(self)
        define_task
      end

      private

      def define_task
        desc "Run all ruby_llm-contract evals"
        task(@name => task_prerequisites) do
          require "ruby_llm/contract"
          RubyLLM::Contract.load_evals!(*@eval_dirs)

          context = @context.respond_to?(:call) ? @context.call : @context
          results = RubyLLM::Contract.run_all_evals(context: context)

          if results.empty?
            if @fail_on_empty
              abort "No evals defined. Define evals with define_eval or set fail_on_empty = false."
            else
              puts "No evals defined."
              next
            end
          end

          gate_passed = true
          suite_cost = 0.0

          passed_reports = []
          all_reports = []

          results.each do |host, reports|
            puts "\n#{host.name || host.to_s}"
            reports.each_value do |report|
              report.print_summary
              suite_cost += report.total_cost
              all_reports << [host, report]
              report_ok = report_meets_score?(report) && !check_regression(report)
              gate_passed = false unless report_ok
              passed_reports << report if report_ok
            end
          end

          # Save history BEFORE gating — failures are valuable trend data (ADR-0016 F3)
          save_all_history!(all_reports, context) if @track_history

          if @maximum_cost && suite_cost > @maximum_cost
            abort "\nEval suite FAILED: total cost $#{format("%.4f", suite_cost)} " \
                  "exceeds budget $#{format("%.4f", @maximum_cost)}"
          end

          abort "\nEval suite FAILED" unless gate_passed

          # Save baselines only after ALL gates pass
          passed_reports.each { |r| save_baseline!(r) } if @save_baseline

          puts "\nAll evals passed."
        end
      end

      def report_meets_score?(report)
        if @minimum_score
          report.score >= @minimum_score
        else
          report.passed?
        end
      end

      def check_regression(report)
        return false unless @fail_on_regression && report.baseline_exists?

        diff = report.compare_with_baseline
        if diff.regressed?
          puts "\n  REGRESSIONS DETECTED:"
          puts "  #{diff}"
          true
        else
          false
        end
      end

      def save_baseline!(report)
        path = report.save_baseline!
        puts "  Baseline saved: #{path}"
      end

      def save_all_history!(host_reports, context)
        context_model = (context[:model] || context["model"]) if context.is_a?(Hash)
        host_reports.each do |host, report|
          # Model priority: context > step DSL > default config
          model = context_model
          model ||= (host.model if host.respond_to?(:model))
          model ||= RubyLLM::Contract.configuration.default_model rescue nil
          path = report.save_history!(model: model)
          puts "  History saved: #{path}"
        end
      end

      def task_prerequisites
        defined?(::Rails) ? [:environment] : []
      end
    end

    # Standalone task: runs all evals for one step across candidates,
    # builds a score matrix, and suggests an optimal retry chain.
    #
    # Loaded automatically when `require "ruby_llm/contract/rake_task"`.
    # Usage:
    #   rake ruby_llm_contract:optimize \
    #     STEP=MatchProblemsToPages \
    #     CANDIDATES=gpt-5-nano,gpt-5-mini@low,gpt-5-mini
    class OptimizeRakeTask < ::Rake::TaskLib
      def initialize
        super()
        define_task
      end

      private

      def define_task
        desc "Run all evals for STEP with CANDIDATES and suggest an optimal retry chain"
        task(:"ruby_llm_contract:optimize" => task_prerequisites) do
          require "ruby_llm/contract"
          eval_dirs = ENV["EVAL_DIRS"].to_s.split(",").map(&:strip).reject(&:empty?)
          RubyLLM::Contract.load_evals!(*eval_dirs)

          step_name = ENV["STEP"].to_s.strip
          abort("STEP is required, e.g. STEP=MatchProblemsToPages") if step_name.empty?
          raw_candidates = ENV["CANDIDATES"].to_s.strip
          abort("CANDIDATES is required, e.g. CANDIDATES=gpt-5-nano,gpt-5-mini@low,gpt-5-mini") if raw_candidates.empty?
          min_score = ENV.fetch("MIN_SCORE", "0.95").to_f
          runs = ENV.fetch("RUNS", "1").to_i

          host = RubyLLM::Contract.eval_hosts.find { |h| h.name == step_name }
          unless host
            available = RubyLLM::Contract.eval_hosts.filter_map(&:name).sort
            abort "Unknown STEP=#{step_name}. Available: #{available.join(", ")}"
          end

          candidates = parse_candidates(raw_candidates)
          context = build_context

          result = host.optimize_retry_policy(
            candidates: candidates,
            context: context,
            min_score: min_score,
            runs: runs
          )

          result.print_summary
        end
      end

      def parse_candidates(raw)
        entries = if raw.start_with?("[")
                    Array(JSON.parse(raw))
                  else
                    raw.split(",").map(&:strip).reject(&:empty?).map do |entry|
                      model, effort = entry.split("@", 2)
                      config = { model: model.strip }
                      config[:reasoning_effort] = effort.strip if effort && !effort.empty?
                      config
                    end
                  end

        entries.map { |e| RubyLLM::Contract.normalize_candidate_config(e) }.uniq
      end

      def build_context
        ctx = {}
        provider = ENV["PROVIDER"].to_s.strip
        # Only inject real adapter when LIVE=1 or PROVIDER is set — otherwise
        # evals use sample_response (offline mode, zero API calls).
        if ENV["LIVE"] == "1" || !provider.empty?
          ctx[:adapter] = RubyLLM::Contract::Adapters::RubyLLM.new
          ctx[:provider] = provider.downcase.to_sym unless provider.empty?
        end
        ctx
      end

      def task_prerequisites
        defined?(::Rails) ? [:environment] : []
      end
    end

    # Auto-register the optimize task when this file is loaded
    OptimizeRakeTask.new
  end
end
