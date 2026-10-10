# frozen_string_literal: true

module RubyLLM
  module Contract
    module Eval
      # Suite-level counterpart of the step-level `max_cost ... on_unknown_pricing:`.
      # A report's total_cost counts an unpriced case as 0.0, so a maximum_cost
      # gate that only compares totals passes whatever those cases really cost.
      # Shared by the rake task, the pass_eval matcher and assert_eval_passes.
      module UnknownCostGate
        MODES = %i[refuse warn].freeze

        def self.validate!(mode)
          return mode if MODES.include?(mode)

          raise ArgumentError, "on_unknown_pricing must be :refuse or :warn, got #{mode.inspect}"
        end

        # Returns the failure message under :refuse, nil when the gate holds.
        def self.check(reports, mode:)
          names = reports.flat_map(&:unknown_cost_results).map(&:name).uniq
          return nil if names.empty?

          if mode == :warn
            warn "[ruby_llm-contract] #{describe(names)} - maximum_cost checked against priced cases only"
            return nil
          end

          "#{describe(names)}. Register pricing via CostCalculator.register_model " \
            "or set on_unknown_pricing to :warn to check maximum_cost against priced cases only."
        end

        def self.describe(names)
          "#{names.length} case(s) have unknown cost (model has no pricing data): #{names.join(", ")}"
        end
        private_class_method :describe
      end
    end
  end
end
