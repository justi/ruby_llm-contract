# frozen_string_literal: true

module RubyLLM
  module Contract
    module Step
      # Extracted from Runner to reduce class length.
      # Handles input token limit and cost limit checks.
      module LimitChecker
        private

        def check_limits(messages)
          return nil unless @max_input || @max_cost

          estimated = TokenEstimator.estimate(messages)
          errors = collect_limit_errors(estimated)

          return nil if errors.empty?

          build_limit_result(messages, estimated, errors)
        end

        def collect_limit_errors(estimated)
          errors = []
          if @max_input && estimated > @max_input
            errors << "Input token limit exceeded: estimated #{estimated} tokens, max #{@max_input}"
          end
          append_cost_error(estimated, errors) if @max_cost
          errors
        end

        # Default output estimate when max_output is not set.
        # Uses input token count as a conservative proxy — most LLM responses
        # are shorter than the input, so this overestimates slightly.
        # Without this, output cost is zero and max_cost can be bypassed
        # for models expensive on completion side.
        DEFAULT_OUTPUT_RATIO = 1

        def append_cost_error(estimated, errors)
          estimated_output = effective_max_output || (estimated * DEFAULT_OUTPUT_RATIO)
          estimated_cost = CostCalculator.calculate(
            model_name: @model,
            usage: { input_tokens: estimated, output_tokens: estimated_output }
          )

          if estimated_cost.nil?
            handle_unknown_pricing(errors)
          elsif estimated_cost > @max_cost
            errors << "Cost limit exceeded: estimated $#{format("%.6f", estimated_cost)} " \
                      "(#{estimated} input + #{estimated_output} output tokens), " \
                      "max $#{format("%.6f", @max_cost)}"
          end
        end

        def handle_unknown_pricing(errors)
          if @on_unknown_pricing == :warn
            warn "[ruby_llm-contract] max_cost is configured but model '#{@model}' " \
                 "has no pricing data — cost limit not enforced"
          else
            errors << "max_cost is set but model '#{@model}' has no pricing data. " \
                      "Register pricing via CostCalculator.register_model or set " \
                      "on_unknown_pricing: :warn to proceed without cost checks."
          end
        end

        def build_limit_result(messages, estimated, errors)
          Result.new(
            status: :limit_exceeded,
            raw_output: nil,
            parsed_output: nil,
            validation_errors: errors,
            trace: Trace.new(
              messages: messages, model: @model,
              usage: { input_tokens: 0, output_tokens: 0, estimated_input_tokens: estimated,
                       estimate_method: :heuristic }
            )
          )
        end
      end
    end
  end
end
