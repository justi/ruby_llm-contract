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
        # For multiple sequential responses:
        #   stub_step(ClassifyTicket, responses: [{ a: 1 }, { a: 2 }])
        #
        def stub_step(step_class, response: nil, responses: nil)
          adapter = if responses
                      Adapters::Test.new(responses: responses.map { |r| r.is_a?(String) ? r : r.to_json })
                    else
                      content = response.is_a?(String) ? response : response.to_json
                      Adapters::Test.new(response: content)
                    end
          RubyLLM::Contract.configure { |c| c.default_adapter = adapter }
        end
      end
    end
  end
end
