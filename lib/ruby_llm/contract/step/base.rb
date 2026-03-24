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
            model_name = model || (self.model if respond_to?(:model)) || RubyLLM::Contract.configuration.default_model
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

            step_model = (self.model if respond_to?(:model))
            model_list = models || [step_model || RubyLLM::Contract.configuration.default_model].compact
            cases = defn.build_dataset.cases

            model_list.each_with_object({}) do |model_name, result|
              per_case = cases.sum do |c|
                est = estimate_cost(input: c.input, model: model_name)
                est ? est[:estimated_cost] : 0.0
              end
              result[model_name] = per_case.round(6)
            end
          end

          KNOWN_CONTEXT_KEYS = %i[adapter model temperature max_tokens provider assume_model_exists].freeze

          include Concerns::ContextHelpers

          def run(input, context: {})
            context = safe_context(context)
            warn_unknown_context_keys(context)
            adapter = resolve_adapter(context)
            default_model = context[:model] || model || RubyLLM::Contract.configuration.default_model
            policy = retry_policy

            ctx_temp = context[:temperature]
            extra = context.slice(:provider, :assume_model_exists, :max_tokens)
            result = if policy
                       run_with_retry(input, adapter: adapter, default_model: default_model,
                                      policy: policy, context_temperature: ctx_temp, extra_options: extra)
                     else
                       run_once(input, adapter: adapter, model: default_model,
                                context_temperature: ctx_temp, extra_options: extra)
                     end

            log_result(result)
            invoke_around_call(input, result)
          end

          def build_messages(input)
            dynamic = prompt.arity >= 1
            builder_input = dynamic ? input : Prompt::Builder::NOT_PROVIDED
            ast = Prompt::Builder.build(input: builder_input, &prompt)
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

          def run_once(input, adapter:, model:, context_temperature: nil, extra_options: {})
            effective_temp = context_temperature || temperature
            Runner.new(
              input_type: input_type, output_type: output_type,
              prompt_block: prompt, contract_definition: effective_contract,
              adapter: adapter, model: model, output_schema: output_schema,
              max_output: max_output, max_input: max_input, max_cost: max_cost,
              on_unknown_pricing: on_unknown_pricing,
              temperature: effective_temp, extra_options: extra_options
            ).call(input)
          rescue ArgumentError => e
            Result.new(status: :input_error, raw_output: nil, parsed_output: nil,
                       validation_errors: [e.message])
          end

          def log_result(result)
            logger = RubyLLM::Contract.configuration.logger
            return unless logger

            trace = result.trace
            msg = "[ruby_llm-contract] #{name || self} " \
                  "model=#{trace.model} status=#{result.status} " \
                  "latency=#{trace.latency_ms}ms " \
                  "tokens=#{trace.usage&.dig(:input_tokens) || 0}+#{trace.usage&.dig(:output_tokens) || 0} " \
                  "cost=$#{format("%.6f", trace.cost || 0)}"
            logger.info(msg)
          end

          def invoke_around_call(input, result)
            return result unless around_call

            around_call.call(self, input, result)
            result
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
