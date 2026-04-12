# frozen_string_literal: true

module RubyLLM
  module Contract
    module Eval
      class Recommendation
        include Concerns::DeepFreeze

        attr_reader :best, :retry_chain, :score, :cost_per_call,
                    :rationale, :current_config, :savings, :warnings

        def initialize(best:, retry_chain:, score:, cost_per_call:,
                       rationale:, current_config:, savings:, warnings:)
          @best = deep_dup_freeze(best)
          @retry_chain = deep_dup_freeze(retry_chain)
          @score = score
          @cost_per_call = cost_per_call
          @rationale = rationale.freeze
          @current_config = deep_dup_freeze(current_config)
          @savings = deep_dup_freeze(savings)
          @warnings = warnings.freeze
          freeze
        end

        def to_dsl
          return "# No recommendation — no candidate met the minimum score" if retry_chain.empty?

          if retry_chain.length == 1 && retry_chain.first.keys == [:model]
            "model \"#{retry_chain.first[:model]}\""
          elsif retry_chain.all? { |c| c.keys == [:model] }
            models_str = retry_chain.map { |c| c[:model] }.join(" ")
            "retry_policy models: %w[#{models_str}]"
          else
            args = retry_chain.map { |c| config_to_ruby(c) }.join(",\n             ")
            "retry_policy do\n  escalate(#{args})\nend"
          end
        end

        private

        def config_to_ruby(config)
          pairs = config.map { |k, v| "#{k}: #{v.inspect}" }.join(", ")
          "{ #{pairs} }"
        end
      end
    end
  end
end
