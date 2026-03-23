# frozen_string_literal: true

module RubyLLM
  module Contract
    module Step
      class Base
        def self.inherited(subclass)
          super
          Contract.register_eval_host(subclass) if respond_to?(:eval_defined?) && eval_defined?
        end

        class << self
          include Concerns::EvalHost
          include RetryExecutor
          include Dsl

          def eval_case(input:, expected: nil, expected_traits: nil, evaluator: nil, context: {})
            dataset = Eval::Dataset.define("single_case") do
              add_case("inline", input: input, expected: expected,
                                 expected_traits: expected_traits, evaluator: evaluator)
            end
            report = Eval::Runner.run(step: self, dataset: dataset, context: context)
            report.results.first
          end

          def estimate_cost(input:, model: nil)
            model_name = model || RubyLLM::Contract.configuration.default_model
            messages = build_messages(input)
            input_tokens = TokenEstimator.estimate(messages)
            output_tokens = max_output || 256 # conservative default

            model_info = CostCalculator.send(:find_model, model_name)
            return nil unless model_info

            estimated = CostCalculator.send(:compute_cost, model_info,
                                            { input_tokens: input_tokens, output_tokens: output_tokens })
            {
              model: model_name,
              input_tokens: input_tokens,
              output_tokens_estimate: output_tokens,
              estimated_cost: estimated
            }
          end

          def estimate_eval_cost(eval_name, models: nil)
            defn = send(:all_eval_definitions)[eval_name.to_s]
            raise ArgumentError, "No eval '#{eval_name}' defined" unless defn

            model_list = models || [RubyLLM::Contract.configuration.default_model].compact
            cases = defn.build_dataset.cases

            model_list.each_with_object({}) do |model_name, result|
              per_case = cases.sum do |c|
                est = estimate_cost(input: c.input, model: model_name)
                est ? est[:estimated_cost] : 0.0
              end
              result[model_name] = per_case.round(6)
            end
          end

          KNOWN_CONTEXT_KEYS = %i[adapter model temperature max_tokens schema provider assume_model_exists].freeze

          def run(input, context: {})
            warn_unknown_context_keys(context)
            adapter = resolve_adapter(context)
            default_model = context[:model] || RubyLLM::Contract.configuration.default_model
            policy = retry_policy

            if policy
              run_with_retry(input, adapter: adapter, default_model: default_model, policy: policy)
            else
              run_once(input, adapter: adapter, model: default_model, context_temperature: context[:temperature])
            end
          end

          def build_messages(input)
            dynamic = prompt.arity >= 1
            ast = Prompt::Builder.build(input: dynamic ? input : nil, &prompt)
            variables = dynamic ? {} : { input: input }
            variables.merge!(input.transform_keys(&:to_sym)) if !dynamic && input.is_a?(Hash)
            Prompt::Renderer.render(ast, variables: variables)
          end

          private

          def warn_unknown_context_keys(context)
            unknown = context.keys - KNOWN_CONTEXT_KEYS
            return if unknown.empty?

            warn "[ruby_llm-contract] Unknown context keys: #{unknown.inspect}. " \
                 "Known keys: #{KNOWN_CONTEXT_KEYS.inspect}"
          end

          def resolve_adapter(context)
            adapter = context[:adapter] || RubyLLM::Contract.configuration.default_adapter
            return adapter if adapter

            raise RubyLLM::Contract::Error, "No adapter configured. Set one with RubyLLM::Contract.configure " \
                                            "{ |c| c.default_adapter = ... } or pass context: { adapter: ... }"
          end

          def run_once(input, adapter:, model:, context_temperature: nil)
            effective_temp = context_temperature || temperature
            runner = Runner.new(
              input_type: input_type, output_type: output_type,
              prompt_block: prompt, contract_definition: effective_contract,
              adapter: adapter, model: model, output_schema: output_schema,
              max_output: max_output, max_input: max_input, max_cost: max_cost,
              temperature: effective_temp
            )

            if around_call
              around_call.call(self, input) { runner.call(input) }
            else
              runner.call(input)
            end
          rescue ArgumentError => e
            Result.new(status: :input_error, raw_output: nil, parsed_output: nil,
                       validation_errors: [e.message])
          end

          def effective_contract
            base = contract
            extra = class_validates
            inferred_parse = json_compatible_type?(output_type) ? :json : nil

            return base if extra.empty? && inferred_parse.nil?

            has_own_contract = defined?(@contract_definition) && @contract_definition
            Definition.merge(
              base,
              extra_invariants: extra,
              parse_override: inferred_parse && !has_own_contract ? inferred_parse : nil
            )
          end

          def json_compatible_type?(type)
            type == RubyLLM::Contract::Types::Hash || type == Hash ||
              type == RubyLLM::Contract::Types::Array || type == Array ||
              (type.respond_to?(:name) && type.name&.match?(/Hash|Array/))
          end
        end
      end
    end
  end
end
