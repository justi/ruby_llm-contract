# frozen_string_literal: true

require "faraday"

module RubyLLM
  module Contract
    module Step
      class AdapterCaller
        # Exceptions treated as :adapter_error (retryable when explicitly opted in).
        # RubyLLM::Error covers provider-semantic errors (auth, bad request,
        # rate limit, server error, context length). Faraday::Error covers
        # transport failures that escape ruby_llm's Faraday retry middleware
        # after exhaustion (Faraday::TimeoutError, Faraday::ConnectionFailed).
        # Anything else (NoMethodError, programmer ArgumentError from adapter
        # code, etc.) propagates — those are bugs, not retry candidates.
        ADAPTER_ERRORS = [::RubyLLM::Error, ::Faraday::Error].freeze

        def initialize(adapter:, adapter_options:)
          @adapter = adapter
          @adapter_options = adapter_options
        end

        def call(messages)
          start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          response = @adapter.call(messages: messages, **@adapter_options)
          latency_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time) * 1000).round
          [response, latency_ms]
        rescue *ADAPTER_ERRORS => e
          result = Result.new(
            status: :adapter_error,
            raw_output: nil,
            parsed_output: nil,
            validation_errors: [e.message]
          )
          [result, 0]
        end
      end
    end
  end
end
