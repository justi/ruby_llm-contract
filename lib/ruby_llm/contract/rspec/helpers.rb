# frozen_string_literal: true

module RubyLLM
  module Contract
    module RSpec
      module Helpers
        # Stub a step to return a canned response without API calls.
        #
        #   stub_step(ClassifyTicket, response: { priority: "high" })
        #   result = ClassifyTicket.run("test")
        #   result.parsed_output  # => {priority: "high"}
        #
        # Only affects the specified step — other steps are not affected.
        #
        # With a block, the stub is scoped — cleaned up after the block:
        #
        #   stub_step(ClassifyTicket, response: data) do
        #     # only stubbed inside this block
        #   end
        #   # ClassifyTicket no longer stubbed
        #
        # Without a block, the stub lives until the RSpec example ends.
        #
        def stub_step(step_class, response: nil, responses: nil, &block)
          adapter = build_test_adapter(response: response, responses: responses)

          if block
            # Block form: use thread-local overrides with save/restore for real scoping
            overrides = RubyLLM::Contract.step_adapter_overrides
            previous = overrides[step_class]
            overrides[step_class] = adapter
            begin
              yield
            ensure
              if previous
                overrides[step_class] = previous
              else
                overrides.delete(step_class)
              end
            end
          else
            # Non-block: use RSpec allow (auto-cleaned after example)
            allow(step_class).to receive(:run).and_wrap_original do |original, input, **kwargs|
              context = kwargs[:context] || {}
              unless context.key?(:adapter) || context.key?("adapter")
                context = context.merge(adapter: adapter)
              end
              original.call(input, context: context)
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
            adapter = build_test_adapter(**opts)
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
          adapter = build_test_adapter(response: response, responses: responses)

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

        private

        def build_test_adapter(response: nil, responses: nil)
          if responses
            Adapters::Test.new(responses: responses.map { |r| normalize_test_response(r) })
          else
            Adapters::Test.new(response: normalize_test_response(response))
          end
        end

        def normalize_test_response(value)
          value
        end
      end
    end
  end
end
