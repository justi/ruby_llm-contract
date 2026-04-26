# frozen_string_literal: true

module RubyLLM
  module Contract
    module Step
      class Base
        DEFAULT_OUTPUT_TOKENS = 256

        def self.inherited(subclass)
          super
          Contract.register_eval_host(subclass) if respond_to?(:eval_defined?) && eval_defined?
        end

        class << self
          include Concerns::EvalHost
          include RetryExecutor
          include Dsl

          def eval_case(input:, expected: nil, expected_traits: nil, evaluator: nil, context: {})
            Eval::Runner.run(step: self, dataset: inline_dataset(input, expected, expected_traits, evaluator),
                             context: context).results.first
          end

          def estimate_cost(input:, model: nil)
            model_name = estimated_model_name(model)
            model_info = CostCalculator.send(:find_model, model_name)
            return nil unless model_info

            input_tokens = TokenEstimator.estimate(build_messages(input))
            output_tokens = max_output || DEFAULT_OUTPUT_TOKENS

            {
              model: model_name,
              input_tokens: input_tokens,
              output_tokens_estimate: output_tokens,
              estimated_cost: estimated_cost_for(model_info, input_tokens, output_tokens)
            }
          end

          def estimate_eval_cost(eval_name, models: nil)
            defn = send(:all_eval_definitions)[eval_name.to_s]
            raise ArgumentError, "No eval '#{eval_name}' defined" unless defn

            model_list = models || [estimated_model_name].compact
            cases = defn.build_dataset.cases

            model_list.each_with_object({}) do |model_name, result|
              result[model_name] = estimate_eval_cost_for_model(cases, model_name)
            end
          end

          def recommend(eval_name, candidates:, min_score: 0.95, min_first_try_pass_rate: 0.8, context: {})
            comparison = compare_models(eval_name, candidates: candidates, context: context)
            Eval::Recommender.new(
              comparison: comparison,
              min_score: min_score,
              min_first_try_pass_rate: min_first_try_pass_rate,
              current_config: current_model_config
            ).recommend
          end

          def optimize_retry_policy(candidates:, context: {}, min_score: 0.95, runs: 1, production_mode: nil)
            Eval::RetryOptimizer.new(
              step: self,
              candidates: candidates,
              context: context,
              min_score: min_score,
              runs: runs,
              production_mode: production_mode
            ).call
          end

          KNOWN_CONTEXT_KEYS = %i[adapter model temperature max_tokens provider assume_model_exists
                                  reasoning_effort retry_policy_override].freeze

          include Concerns::ContextHelpers

          def run(input, context: {})
            context = safe_context(context)
            warn_unknown_context_keys(context)

            result = dispatch_run(input, context)
            log_result(result)
            invoke_around_call(input, result)
          end

          def build_messages(input)
            dynamic = prompt.arity >= 1
            builder_input = dynamic ? input : Prompt::Builder::NOT_PROVIDED
            ast = Prompt::Builder.build(input: builder_input, &prompt)
            Prompt::Renderer.render(ast, variables: prompt_variables(input, dynamic))
          end

          private

          def inline_dataset(input, expected, expected_traits, evaluator)
            Eval::Dataset.define("single_case") do
              add_case("inline", input: input, expected: expected,
                                 expected_traits: expected_traits, evaluator: evaluator)
            end
          end

          def estimated_model_name(model = nil)
            model || (self.model if respond_to?(:model)) || RubyLLM::Contract.configuration.default_model
          end

          def estimated_cost_for(model_info, input_tokens, output_tokens)
            CostCalculator.send(
              :compute_cost,
              model_info,
              { input_tokens: input_tokens, output_tokens: output_tokens }
            )
          end

          def estimate_eval_cost_for_model(cases, model_name)
            cases.sum do |test_case|
              estimate = estimate_cost(input: test_case.input, model: model_name)
              estimate ? estimate[:estimated_cost] : 0.0
            end.round(6)
          end

          def prompt_variables(input, dynamic)
            variables = dynamic ? {} : { input: input }
            variables.merge!(input.transform_keys(&:to_sym)) if !dynamic && input.is_a?(Hash)
            variables
          end

          def warn_unknown_context_keys(context)
            unknown = context.keys - KNOWN_CONTEXT_KEYS
            return if unknown.empty?

            warn "[ruby_llm-contract] Unknown context keys: #{unknown.inspect}. " \
                 "Known keys: #{KNOWN_CONTEXT_KEYS.inspect}"
          end

          def dispatch_run(input, context)
            adapter = resolve_adapter(context)
            runtime = runtime_settings(context)

            if runtime[:policy]
              run_with_retry(
                input,
                adapter: adapter,
                default_model: runtime[:model],
                policy: runtime[:policy],
                context_temperature: runtime[:temperature],
                extra_options: runtime[:extra_options]
              )
            else
              run_once(
                input,
                adapter: adapter,
                model: runtime[:model],
                context_temperature: runtime[:temperature],
                extra_options: runtime[:extra_options]
              )
            end
          end

          def runtime_settings(context)
            policy = context.key?(:retry_policy_override) ? context[:retry_policy_override] : retry_policy
            extra = context.slice(:provider, :assume_model_exists, :max_tokens, :reasoning_effort)

            # Always pass the class-level `thinking` config to the adapter when
            # set, so fields like `budget` survive a per-call `reasoning_effort`
            # override. The adapter's `resolve_thinking_config` merges
            # `reasoning_effort` over `thinking[:effort]` while keeping the
            # rest of the hash intact.
            #
            # `reasoning_effort` is also seeded into extra_options for
            # backward compat with eval_host / production_mode paths that
            # read it from there — but only when the caller did not already
            # provide one in context.
            if respond_to?(:thinking) && thinking
              extra[:thinking] = thinking
              extra[:reasoning_effort] = thinking[:effort] if !extra.key?(:reasoning_effort) && thinking[:effort]
            end

            {
              model: context[:model] || model || RubyLLM::Contract.configuration.default_model,
              temperature: context[:temperature],
              extra_options: extra,
              policy: policy
            }
          end

          def current_model_config
            policy = retry_policy
            if policy && policy.config_list.any?
              policy.config_list.first
            elsif respond_to?(:model) && model
              { model: model }
            elsif RubyLLM::Contract.configuration.default_model
              { model: RubyLLM::Contract.configuration.default_model }
            end
          end

          def resolve_adapter(context)
            adapter = context[:adapter] || RubyLLM::Contract.configuration.default_adapter
            return adapter if adapter

            raise RubyLLM::Contract::Error, "No adapter configured. Set one with RubyLLM::Contract.configure " \
                                            "{ |c| c.default_adapter = ... } or pass context: { adapter: ... }"
          end

          # ADR-0021 deliverable 2: narrow ArgumentError rescue to DSL-setup phase only.
          #
          # DSL misconfiguration (e.g. `prompt has not been set`, missing required
          # attributes) surfaces as ArgumentError when constructing Runner. We catch
          # that and return :input_error — these are contract-definition issues the
          # caller can handle as "bad input to the step definition".
          #
          # Runner#call itself does NOT get a blanket rescue: input-type validation
          # failures return :input_error from within InputValidator; adapter/runtime
          # programmer bugs (NoMethodError, adapter-code ArgumentError) must propagate
          # instead of being silently masked as :input_error.
          def run_once(input, adapter:, model:, context_temperature: nil, extra_options: {})
            effective_temp = context_temperature || temperature
            runner =
              begin
                Runner.new(
                  input_type: input_type, output_type: output_type,
                  prompt_block: prompt, contract_definition: effective_contract,
                  adapter: adapter, model: model, output_schema: output_schema,
                  max_output: max_output, max_input: max_input, max_cost: max_cost,
                  on_unknown_pricing: on_unknown_pricing,
                  temperature: effective_temp, extra_options: extra_options,
                  observers: class_observers
                )
              rescue ArgumentError => e
                return Result.new(status: :input_error, raw_output: nil, parsed_output: nil,
                                  validation_errors: [e.message])
              end

            runner.call(input)
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

            log_failed_observations(result, logger)
          end

          def log_failed_observations(result, logger)
            failed = result.observations.select { |o| !o[:passed] }
            return if failed.empty?

            failed.each do |obs|
              msg = "[ruby_llm-contract] #{name || self} observation failed: #{obs[:description]}"
              msg += " (#{obs[:error]})" if obs[:error]
              logger.warn(msg)
            end
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
