# frozen_string_literal: true

module RubyLLM
  module Contract
    module Eval
      # Extracted from Runner to reduce class length.
      # Builds contract detail strings for contract-only evaluation.
      module ContractDetailBuilder
        private

        def build_contract_details
          parts = ["contract passed"]
          append_schema_details(parts)
          append_invariant_details(parts)
          parts.join(", ")
        end

        def append_schema_details(parts)
          return unless @step.respond_to?(:output_schema)

          schema = @step.output_schema
          return unless schema

          field_count = begin
            schema.properties.size
          rescue StandardError
            0
          end
          parts << "schema: #{field_count} fields" if field_count.positive?
        end

        def append_invariant_details(parts)
          return unless @step.respond_to?(:contract)

          invariant_count = begin
            @step.contract.invariants.size
          rescue StandardError
            0
          end
          class_validates = @step.instance_variable_get(:@class_validates)&.size || 0
          total = invariant_count + class_validates
          parts << "validates: #{total} passed" if total.positive?
        end
      end
    end
  end
end
