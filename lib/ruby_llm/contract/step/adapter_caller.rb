# frozen_string_literal: true

module RubyLLM
  module Contract
    module Step
      class AdapterCaller
        def initialize(adapter:, adapter_options:)
          @adapter = adapter
          @adapter_options = adapter_options
        end

        def call(messages)
          start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          response = @adapter.call(messages: messages, **@adapter_options)
          latency_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time) * 1000).round
          [response, latency_ms]
        rescue StandardError => error
          [Result.new(status: :adapter_error, raw_output: nil, parsed_output: nil, validation_errors: [error.message]), 0]
        end
      end
    end
  end
end
