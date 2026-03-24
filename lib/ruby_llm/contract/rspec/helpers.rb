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
        # Supports an optional block form for scoped stubbing:
        #
        #   stub_step(ClassifyTicket, response: data) do
        #     # only stubbed inside this block
        #   end
        #   # mock automatically cleaned up by RSpec after example
        #
        def stub_step(step_class, response: nil, responses: nil, &block)
          adapter = build_test_adapter(response: response, responses: responses)
          allow(step_class).to receive(:run).and_wrap_original do |original, input, **kwargs|
            context = (kwargs[:context] || {}).merge(adapter: adapter)
            original.call(input, context: context)
          end
          yield if block
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
