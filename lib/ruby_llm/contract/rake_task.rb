# frozen_string_literal: true

require "rake"
require "rake/tasklib"

module RubyLLM
  module Contract
    class RakeTask < ::Rake::TaskLib
      attr_accessor :name, :context, :fail_on_empty, :minimum_score, :maximum_cost

      def initialize(name = :"ruby_llm_contract:eval", &block)
        super()
        @name = name
        @context = {}
        @fail_on_empty = true
        @minimum_score = nil # nil = require 100%; float = threshold
        @maximum_cost = nil  # nil = no cost limit; float = budget cap
        block&.call(self)
        define_task
      end

      private

      def define_task
        desc "Run all ruby_llm-contract evals"
        task(@name => task_prerequisites) do
          require "ruby_llm/contract"
          RubyLLM::Contract.load_evals!

          results = RubyLLM::Contract.run_all_evals(context: @context)

          if results.empty?
            if @fail_on_empty
              abort "No evals defined. Define evals with define_eval or set fail_on_empty = false."
            else
              puts "No evals defined."
              next
            end
          end

          gate_passed = true
          results.each do |host, reports|
            puts "\n#{host.name || host.to_s}"
            reports.each_value do |report|
              report.pretty_print
              gate_passed = false unless report_meets_threshold?(report)
            end
          end

          abort "\nEval suite FAILED" unless gate_passed
          puts "\nAll evals passed."
        end
      end

      def report_meets_threshold?(report)
        score_ok = if @minimum_score
                     report.score >= @minimum_score
                   else
                     report.passed?
                   end
        cost_ok = @maximum_cost ? report.total_cost <= @maximum_cost : true
        score_ok && cost_ok
      end

      def task_prerequisites
        Rake::Task.task_defined?(:environment) ? [:environment] : []
      end
    end
  end
end
