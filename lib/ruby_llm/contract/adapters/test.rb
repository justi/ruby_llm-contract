# frozen_string_literal: true

module RubyLLM
  module Contract
    module Adapters
      class Test < Base
        def initialize(response: nil, responses: nil, usage: nil)
          super()
          @usage = (usage || { input_tokens: 0, output_tokens: 0 }).dup.freeze
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

        # Exposes raw responses array for concurrent eval to split per-case
        def responses_array
          @responses
        end

        # Returns a fresh adapter with reset index for concurrent execution
        def clone_for_concurrency
          if @responses
            self.class.new(responses: @responses.dup, usage: @usage.dup)
          else
            self.class.new(response: @response, usage: @usage.dup)
          end
        end

        def call(messages:, **_options) # rubocop:disable Lint/UnusedMethodArgument
          content = if @responses
                      c = @responses[@index] || @responses.last
                      @index += 1
                      c
                    else
                      @response
                    end
          Response.new(content: content, usage: @usage)
        end
      end
    end
  end
end
