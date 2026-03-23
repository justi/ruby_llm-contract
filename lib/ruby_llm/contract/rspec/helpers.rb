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
        def stub_step(step_class, response: nil, responses: nil)
          adapter = build_test_adapter(response: response, responses: responses)
          allow(step_class).to receive(:run).and_wrap_original do |original, input, **kwargs|
            context = (kwargs[:context] || {}).merge(adapter: adapter)
            original.call(input, context: context)
          end
        end

        # Set a global test adapter for ALL steps.
        #
        #   stub_all_steps(response: { default: true })
        #
        def stub_all_steps(response: nil, responses: nil)
          adapter = build_test_adapter(response: response, responses: responses)
          RubyLLM::Contract.configure { |c| c.default_adapter = adapter }
        end

        private

        def build_test_adapter(response: nil, responses: nil)
          if responses
            Adapters::Test.new(responses: responses.map { |r| r.is_a?(String) ? r : r.to_json })
          else
            content = response.is_a?(String) ? response : response.to_json
            Adapters::Test.new(response: content)
          end
        end
      end
    end
  end
end
