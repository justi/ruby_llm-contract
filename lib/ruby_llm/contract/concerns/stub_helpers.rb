# frozen_string_literal: true

module RubyLLM
  module Contract
    module Concerns
      # Shared implementation of `stub_step`, `stub_steps`, and `stub_all_steps`.
      # Included by both `RubyLLM::Contract::RSpec::Helpers` and
      # `RubyLLM::Contract::MinitestHelpers` so the two test-framework
      # adapters cannot drift on stub semantics (Codex DRY finding #1: the
      # prior parallel implementations had already diverged on
      # `normalize_test_response` — RSpec had it, Minitest didn't).
      #
      # Cleanup between examples is the responsibility of the host helper:
      # - RSpec: `around(:each)` hook in `lib/ruby_llm/contract/rspec.rb`
      #   restores `step_adapter_overrides`.
      # - Minitest: `teardown` in `MinitestHelpers` clears overrides and
      #   restores `default_adapter`.
      module StubHelpers
        # Stub a single step to return a canned response without API calls.
        # Block form scopes the stub to the block; non-block form lives
        # until the host's teardown/around hook fires.
        def stub_step(step_class, response: nil, responses: nil, &block)
          adapter = build_test_adapter(response: response, responses: responses)
          overrides = RubyLLM::Contract.step_adapter_overrides

          if block
            previous = overrides[step_class]
            overrides[step_class] = adapter
            begin
              yield
            ensure
              previous ? (overrides[step_class] = previous) : overrides.delete(step_class)
            end
          else
            overrides[step_class] = adapter
          end
        end

        # Stub multiple steps with different responses. Requires a block.
        def stub_steps(stubs, &block)
          raise ArgumentError, "stub_steps requires a block" unless block

          overrides = RubyLLM::Contract.step_adapter_overrides
          previous = {}

          stubs.each do |step_class, opts|
            opts = opts.transform_keys(&:to_sym)
            previous[step_class] = overrides[step_class]
            overrides[step_class] = build_test_adapter(**opts.slice(:response, :responses))
          end

          begin
            yield
          ensure
            stubs.each_key do |step_class|
              previous[step_class] ? (overrides[step_class] = previous[step_class]) : overrides.delete(step_class)
            end
          end
        end

        # Set a global test adapter for ALL steps. Block form restores the
        # previous adapter on exit; non-block form persists until host cleanup.
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

        # Hook for host frameworks to inject custom serialization (e.g.
        # turning hashes into JSON strings). Default: identity.
        def normalize_test_response(value)
          value
        end
      end
    end
  end
end
