# frozen_string_literal: true

require "ruby_llm/contract"

module RubyLLM
  module Contract
    module MinitestHelpers
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

      # Stub a specific step to return a canned response without API calls.
      # Routes per-step — other steps are not affected.
      #
      #   stub_step(ClassifyTicket, response: { priority: "high" })
      #
      # Supports an optional block form — the override is removed after the
      # block returns (even if it raises):
      #
      #   stub_step(ClassifyTicket, response: data) do
      #     result = ClassifyTicket.run("test")
      #   end
      #   # ClassifyTicket.run no longer stubbed
      #
      def stub_step(step_class, response: nil, responses: nil, &block)
        adapter = if responses
                    Adapters::Test.new(responses: responses)
                  else
                    Adapters::Test.new(response: response)
                  end

        overrides = RubyLLM::Contract.step_adapter_overrides
        previous = overrides[step_class]
        overrides[step_class] = adapter

        if block
          begin
            yield
          ensure
            if previous
              overrides[step_class] = previous
            else
              overrides.delete(step_class)
            end
          end
        end
      end

      # Stub multiple steps at once with different responses.
      # Takes a hash of step_class => options. Requires a block.
      #
      #   stub_steps(
      #     ClassifyTicket => { response: { priority: "high" } },
      #     RouteToTeam => { response: { team: "billing" } }
      #   ) do
      #     result = TicketPipeline.run("test")
      #   end
      #
      def stub_steps(stubs, &block)
        raise ArgumentError, "stub_steps requires a block" unless block

        overrides = RubyLLM::Contract.step_adapter_overrides
        previous = {}

        stubs.each do |step_class, opts|
          opts = opts.transform_keys(&:to_sym)
          adapter = if opts[:responses]
                      Adapters::Test.new(responses: opts[:responses])
                    else
                      Adapters::Test.new(response: opts[:response])
                    end
          previous[step_class] = overrides[step_class]
          overrides[step_class] = adapter
        end

        begin
          yield
        ensure
          stubs.each_key do |step_class|
            if previous[step_class]
              overrides[step_class] = previous[step_class]
            else
              overrides.delete(step_class)
            end
          end
        end
      end

      # Set a global test adapter for ALL steps.
      #
      #   stub_all_steps(response: { default: true })
      #
      # Supports an optional block form — the previous adapter is restored
      # after the block returns (even if it raises):
      #
      #   stub_all_steps(response: { default: true }) do
      #     # all steps use test adapter
      #   end
      #   # original adapter restored
      #
      def stub_all_steps(response: nil, responses: nil, &block)
        adapter = if responses
                    Adapters::Test.new(responses: responses)
                  else
                    Adapters::Test.new(response: response)
                  end

        if block
          previous = RubyLLM::Contract.configuration.default_adapter
          begin
            RubyLLM::Contract.configuration.default_adapter = adapter
            yield
          ensure
            RubyLLM::Contract.configuration.default_adapter = previous
          end
        else
          RubyLLM::Contract.configure { |c| c.default_adapter = adapter }
        end
      end
    end
  end
end
