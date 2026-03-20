# frozen_string_literal: true

module RubyLLM
  module Contract
    module Step
      class Base
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

          KNOWN_CONTEXT_KEYS = %i[adapter model temperature max_tokens schema provider assume_model_exists].freeze

          def run(input, context: {})
            warn_unknown_context_keys(context)
            adapter = resolve_adapter(context)
            default_model = context[:model] || RubyLLM::Contract.configuration.default_model
            policy = retry_policy

            if policy
              run_with_retry(input, adapter: adapter, default_model: default_model, policy: policy)
            else
              run_once(input, adapter: adapter, model: default_model)
            end
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

          def run_once(input, adapter:, model:)
            Runner.new(
              input_type: input_type, output_type: output_type,
              prompt_block: prompt, contract_definition: effective_contract,
              adapter: adapter, model: model, output_schema: output_schema,
              max_output: max_output, max_input: max_input, max_cost: max_cost
            ).call(input)
          rescue ArgumentError => e
            Result.new(status: :input_error, raw_output: nil, parsed_output: nil,
                       validation_errors: [e.message])
          end

          def effective_contract
            base = contract
            extra = @class_validates || []
            inferred_parse = json_compatible_type?(output_type) ? :json : nil

            return base if extra.empty? && inferred_parse.nil?

            Definition.merge(
              base,
              extra_invariants: extra,
              parse_override: inferred_parse && !@contract_definition ? inferred_parse : nil
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
