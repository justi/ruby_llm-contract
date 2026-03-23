# frozen_string_literal: true

module RubyLLM
  module Contract
    module Adapters
      class Test < Base
        def initialize(response: nil, responses: nil)
          super()
          if responses
            raise ArgumentError, "responses: must not be empty (use response: nil for nil content)" if responses.empty?

            @responses = responses.map { |r| normalize_response(r) }
            @index = 0
          else
            @response = normalize_response(response)
          end
        end

        private

        def normalize_response(response)
          case response
          when Hash, Array then response.to_json
          when nil then ""
          else response.to_s
          end
        end

        public

        def call(messages:, **_options) # rubocop:disable Lint/UnusedMethodArgument
          content = if @responses
                      c = @responses[@index] || @responses.last
                      @index += 1
                      c
                    else
                      @response
                    end
          Response.new(content: content, usage: { input_tokens: 0, output_tokens: 0 })
        end
      end
    end
  end
end
