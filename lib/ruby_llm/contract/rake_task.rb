# frozen_string_literal: true

require "rake"
require "rake/tasklib"

module RubyLLM
  module Contract
    class RakeTask < ::Rake::TaskLib
      attr_accessor :name, :context, :fail_on_empty, :minimum_score, :maximum_cost,
                    :eval_dirs, :save_baseline, :fail_on_regression

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

          results.each do |host, reports|
            puts "\n#{host.name || host.to_s}"
            reports.each_value do |report|
              report.print_summary
              suite_cost += report.total_cost
              report_ok = report_meets_score?(report) && !check_regression(report)
              gate_passed = false unless report_ok
              passed_reports << report if report_ok
            end
          end

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

      def task_prerequisites
        defined?(::Rails) ? [:environment] : []
      end
    end
  end
end
