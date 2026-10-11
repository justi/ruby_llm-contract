# frozen_string_literal: true

module RubyLLM
  module Contract
    module Concerns
      # Helpers for injecting a retry_policy_override into per-candidate eval
      # context when compare_models runs in production-mode. When candidate
      # == fallback, retry injection is skipped so the row degenerates into
      # a single-shot eval by construction.
      module ProductionModeContext
        private

        def normalize_production_mode(production_mode)
          return nil if production_mode.nil? || production_mode == false

          unless production_mode.is_a?(Hash) && production_mode[:fallback]
            raise ArgumentError, "production_mode: must be a Hash with :fallback, got #{production_mode.inspect}"
          end

          RubyLLM::Contract.normalize_candidate_config(production_mode[:fallback])
        end

        def production_mode_override(config, fallback_config, inherited_effort = nil)
          return nil if same_request?(config, fallback_config, inherited_effort)

          Step::RetryPolicy.new(models: [config, fallback_config])
        end

        # Compared by what each would send: a candidate without an effort runs
        # with the call's or the Step's, a fallback without one with the
        # candidate's, and :default sends none.
        def same_request?(candidate, fallback, inherited_effort)
          candidate_effort = sent_effort(candidate[:reasoning_effort] || inherited_effort)
          fallback_effort = fallback[:reasoning_effort] ? sent_effort(fallback[:reasoning_effort]) : candidate_effort
          candidate[:model] == fallback[:model] && candidate_effort == fallback_effort
        end

        def sent_effort(effort)
          RubyLLM::Contract.normalize_effort(effort) == :default ? nil : effort
        end
      end
    end
  end
end
