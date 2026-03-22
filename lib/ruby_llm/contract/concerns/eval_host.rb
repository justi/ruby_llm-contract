# frozen_string_literal: true

module RubyLLM
  module Contract
    module Concerns
      module EvalHost
        def define_eval(name, &)
          @eval_definitions ||= {}
          key = name.to_s
          if @eval_definitions.key?(key)
            raise ArgumentError, "eval '#{key}' is already defined on #{self}. Use a unique name."
          end

          @eval_definitions[key] = Eval::EvalDefinition.new(key, step_class: self, &)
          Contract.register_eval_host(self)
          # Register existing subclasses that inherit this eval
          ObjectSpace.each_object(Class) do |klass|
            Contract.register_eval_host(klass) if klass < self
          end
        end

        def eval_names
          all_eval_definitions.keys
        end

        def eval_defined?
          !all_eval_definitions.empty?
        end

        def run_eval(name = nil, context: {})
          if name
            run_single_eval(name, context)
          else
            run_all_own_evals(context)
          end
        end

        def compare_models(eval_name, models:, context: {})
          reports = models.each_with_object({}) do |model, hash|
            model_context = context.merge(model: model)
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

        def run_single_eval(name, context)
          defn = all_eval_definitions[name.to_s]
          raise ArgumentError, "No eval '#{name}' defined. Available: #{all_eval_definitions.keys}" unless defn

          effective_context = eval_context(defn, context)
          Eval::Runner.run(step: self, dataset: defn.build_dataset, context: effective_context)
        end

        def run_all_own_evals(context)
          all_eval_definitions.transform_values do |defn|
            effective_context = eval_context(defn, context)
            Eval::Runner.run(step: self, dataset: defn.build_dataset, context: effective_context)
          end
        end

        def eval_context(defn, context)
          return context if context[:adapter]

          sample_adapter = defn.build_adapter
          return context unless sample_adapter

          context.merge(adapter: sample_adapter)
        end
      end
    end
  end
end
