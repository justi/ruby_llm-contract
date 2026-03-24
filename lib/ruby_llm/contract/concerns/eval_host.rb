# frozen_string_literal: true

module RubyLLM
  module Contract
    module Concerns
      module EvalHost
        include ContextHelpers
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

        def compare_models(eval_name, models:, context: {})
          context = safe_context(context)
          models = models.uniq
          reports = models.each_with_object({}) do |model, hash|
            model_context = isolate_context(context).merge(model: model)
            hash[model] = run_single_eval(eval_name, model_context)
          end
          Eval::ModelComparison.new(eval_name: eval_name, reports: reports)
        end

        private

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

          effective_context = eval_context(defn, context)
          Eval::Runner.run(step: self, dataset: defn.build_dataset, context: effective_context,
                           concurrency: concurrency)
        end

        def run_all_own_evals(context, concurrency: nil)
          all_eval_definitions.transform_values do |defn|
            isolated_context = isolate_context(context)
            effective_context = eval_context(defn, isolated_context)
            Eval::Runner.run(step: self, dataset: defn.build_dataset, context: effective_context,
                             concurrency: concurrency)
          end
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
