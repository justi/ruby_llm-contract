# frozen_string_literal: true

require "ruby_llm/contract"

module RubyLLM
  module Contract
    module MinitestHelpers
      include Concerns::StubHelpers

      # Snapshot adapter before each test so teardown can restore it.
      def setup
        super if defined?(super)
        @_contract_original_adapter = RubyLLM::Contract.configuration.default_adapter
      end

      # Auto-cleanup: clear overrides AND restore original adapter.
      # Prevents both non-block stub_step and stub_all_steps from leaking.
      def teardown
        RubyLLM::Contract.step_adapter_overrides.clear
        RubyLLM::Contract.configuration.default_adapter = @_contract_original_adapter
        super if defined?(super)
      end

      def assert_satisfies_contract(result, msg = nil)
        assert result.ok?, msg || "Expected step result to satisfy contract, " \
          "but got status: #{result.status}. Errors: #{result.validation_errors.join(", ")}"
      end

      def refute_satisfies_contract(result, msg = nil)
        refute result.ok?, msg || "Expected step result NOT to satisfy contract, but it passed"
      end

      def assert_eval_passes(step, eval_name, minimum_score: nil, maximum_cost: nil, context: {}, msg: nil)
        report = step.run_eval(eval_name, context: context)

        if minimum_score
          assert report.score >= minimum_score,
                 msg || "Expected #{eval_name} eval score >= #{minimum_score}, got #{report.score.round(2)} (#{report.pass_rate})"
        else
          assert report.passed?,
                 msg || "Expected #{eval_name} eval to pass, got #{report.score.round(2)} (#{report.pass_rate})"
        end

        if maximum_cost
          assert report.total_cost <= maximum_cost,
                 msg || "Expected #{eval_name} eval cost <= $#{format("%.4f", maximum_cost)}, got $#{format("%.4f", report.total_cost)}"
        end

        report
      end

      # `stub_step`, `stub_steps`, `stub_all_steps` — provided by
      # `Concerns::StubHelpers` (included above). Shared implementation
      # used by both Minitest and RSpec hosts; documentation and method
      # signatures live in `concerns/stub_helpers.rb`.
    end
  end
end
