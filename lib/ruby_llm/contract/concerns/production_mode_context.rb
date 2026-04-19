# frozen_string_literal: true

module RubyLLM
  module Contract
    module Concerns
      # Helpers for injecting a retry_policy_override into per-candidate eval
      # context when compare_models runs in production-mode (see ADR-0018).
      # When candidate == fallback, retry injection is skipped so the row
      # degenerates into a single-shot eval by construction.
      module ProductionModeContext
        private

        def normalize_production_mode(production_mode)
          return nil if production_mode.nil? || production_mode == false

          unless production_mode.is_a?(Hash) && production_mode[:fallback]
            raise ArgumentError, "production_mode: must be a Hash with :fallback, got #{production_mode.inspect}"
          end

          RubyLLM::Contract.normalize_candidate_config(production_mode[:fallback])
        end

        def production_mode_override(config, fallback_config)
          return nil if same_candidate?(config, fallback_config)

          Step::RetryPolicy.new(models: [config, fallback_config])
        end

        def same_candidate?(first, second)
          first[:model] == second[:model] && first[:reasoning_effort] == second[:reasoning_effort]
        end
      end
    end
  end
end
