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
        end

        def run_eval(name = nil, context: {})
          if name
            run_single_eval(name, context)
          else
            run_all_evals(context)
          end
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

        def run_all_evals(context)
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
