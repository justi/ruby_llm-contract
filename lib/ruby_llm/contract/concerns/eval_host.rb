# frozen_string_literal: true

module RubyLLM
  module Contract
    module Concerns
      module EvalHost
        include ContextHelpers
        include ProductionModeContext

        SAMPLE_RESPONSE_COMPARE_WARNING = "[ruby_llm-contract] compare_with ignores sample_response. " \
                                          "Without model: or context: { adapter: ... }, both sides will be skipped " \
                                          "and the A/B comparison is not meaningful.".freeze

        def define_eval(name, &)
          @eval_definitions ||= {}
          @file_sourced_evals ||= Set.new
          key = name.to_s

          if @eval_definitions.key?(key) && !Thread.current[:ruby_llm_contract_reloading]
            warn "[ruby_llm-contract] Redefining eval '#{key}' on #{self}. " \
                 "This replaces the previous definition."
          end

          @eval_definitions[key] = Eval::EvalDefinition.new(key, step_class: self, &)
          @file_sourced_evals.add(key) if Thread.current[:ruby_llm_contract_reloading]
          Contract.register_eval_host(self)
          register_subclasses(self)
        end

        def clear_file_sourced_evals!
          return unless defined?(@file_sourced_evals) && defined?(@eval_definitions)

          @file_sourced_evals.each { |key| @eval_definitions.delete(key) }
          @file_sourced_evals.clear
        end

        def eval_names
          all_eval_definitions.keys
        end

        def eval_defined?
          !all_eval_definitions.empty?
        end

        def run_eval(name = nil, context: {}, concurrency: nil)
          context = safe_context(context)
          if name
            run_single_eval(name, context, concurrency: concurrency)
          else
            run_all_own_evals(context, concurrency: concurrency)
          end
        end

        # Compare this step (candidate) with another step (baseline) using the
        # baseline's eval definition as single source of truth.
        #
        # Requires a real adapter or model in context. sample_response is
        # intentionally NOT used, because A/B testing with canned data
        # gives identical results for both sides rather than a real comparison.
        def compare_with(other_step, eval:, model: nil, context: {})
          ctx = comparison_context(context, model)
          baseline_defn = baseline_eval_definition(other_step, eval)
          raise ArgumentError, "No eval '#{eval}' on baseline step #{other_step}" unless baseline_defn

          dataset = baseline_defn.build_dataset
          warn_sample_response_compare(ctx, baseline_defn)

          my_report = Eval::Runner.run(step: self, dataset: dataset, context: isolate_context(ctx))
          other_report = Eval::Runner.run(step: other_step, dataset: dataset, context: isolate_context(ctx))

          Eval::PromptDiff.new(candidate: my_report, baseline: other_report)
        end

        def compare_models(eval_name, models: [], candidates: [], context: {}, runs: 1, production_mode: nil)
          raise ArgumentError, "Pass either models: or candidates:, not both" if models.any? && candidates.any?

          runs = coerce_runs(runs)

          context = safe_context(context)
          candidate_configs = normalize_candidates(models, candidates)
          reject_production_mode_on_pipeline!(production_mode)
          fallback_config = normalize_production_mode(production_mode)

          reports = {}
          configs = {}
          candidate_configs.each do |config|
            label = Eval::ModelComparison.candidate_label(config)
            model_context = build_candidate_context(context, config, fallback_config)
            per_run = Array.new(runs) { run_single_eval(eval_name, model_context) }
            reports[label] = runs == 1 ? per_run.first : Eval::AggregatedReport.new(per_run)
            configs[label] = config
          end

          Eval::ModelComparison.new(
            eval_name: eval_name, reports: reports, configs: configs, fallback: fallback_config
          )
        end

        private

        def coerce_runs(runs)
          raise ArgumentError, "runs must be an Integer >= 1, got #{runs.inspect}" unless runs.is_a?(Integer)
          raise ArgumentError, "runs must be >= 1, got #{runs.inspect}" if runs < 1

          runs
        end

        def reject_production_mode_on_pipeline!(production_mode)
          return if production_mode.nil? || production_mode == false
          return unless defined?(Pipeline::Base) && self < Pipeline::Base

          raise ArgumentError,
                "production_mode: is not supported on Pipeline (#{self}). Retry injection happens at Step level; " \
                "call compare_models with production_mode: on individual Step classes instead."
        end

        def build_candidate_context(context, config, fallback_config)
          model_context = isolate_context(context).merge(model: config[:model])
          model_context[:reasoning_effort] = config[:reasoning_effort] if config[:reasoning_effort]
          return model_context unless fallback_config

          model_context[:retry_policy_override] = production_mode_override(config, fallback_config)
          model_context
        end

        def normalize_candidates(models, candidates)
          if candidates.any?
            candidates.map { |c| RubyLLM::Contract.normalize_candidate_config(c) }.uniq
          elsif models.any?
            models.uniq.map { |m| { model: m } }
          else
            raise ArgumentError, "Pass models: or candidates: with at least one entry"
          end
        end

        def comparison_context(context, model)
          base_context = safe_context(context)
          model ? base_context.merge(model: model) : base_context
        end

        def baseline_eval_definition(other_step, eval_name)
          other_step.send(:all_eval_definitions)[eval_name.to_s]
        end

        def warn_sample_response_compare(context, baseline_defn)
          return if context[:adapter] || context[:model] || !baseline_defn.build_adapter

          warn SAMPLE_RESPONSE_COMPARE_WARNING
        end

        def all_eval_definitions
          inherited = if superclass.respond_to?(:all_eval_definitions, true)
                        superclass.send(:all_eval_definitions)
                      else
                        {}
                      end
          own = defined?(@eval_definitions) ? @eval_definitions : {}
          inherited.merge(own)
        end

        def run_single_eval(name, context, concurrency: nil)
          defn = all_eval_definitions[name.to_s]
          raise ArgumentError, "No eval '#{name}' defined. Available: #{all_eval_definitions.keys}" unless defn

          run_eval_definition(defn, context, concurrency: concurrency)
        end

        def run_all_own_evals(context, concurrency: nil)
          all_eval_definitions.transform_values do |defn|
            run_eval_definition(defn, isolate_context(context), concurrency: concurrency)
          end
        end

        def run_eval_definition(defn, context, concurrency: nil)
          Eval::Runner.run(
            step: self,
            dataset: defn.build_dataset,
            context: eval_context(defn, context),
            concurrency: concurrency
          )
        end

        def eval_context(defn, context)
          context = safe_context(context)
          return context if context[:adapter]

          sample_adapter = defn.build_adapter
          return context unless sample_adapter

          context.merge(adapter: sample_adapter)
        end

        def register_subclasses(klass)
          if klass.respond_to?(:subclasses)
            klass.subclasses.each do |sub|
              Contract.register_eval_host(sub)
              register_subclasses(sub)
            end
          else
            ObjectSpace.each_object(Class) do |sub|
              Contract.register_eval_host(sub) if sub < klass
            end
          end
        end

      end
    end
  end
end
