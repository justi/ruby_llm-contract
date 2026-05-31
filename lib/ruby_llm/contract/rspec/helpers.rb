# frozen_string_literal: true

module RubyLLM
  module Contract
    module RSpec
      # `stub_step`, `stub_steps`, `stub_all_steps` — provided by
      # `Concerns::StubHelpers`. Shared implementation used by both RSpec
      # and Minitest hosts; documentation and method signatures live in
      # `concerns/stub_helpers.rb`.
      #
      # Cleanup between examples is handled by the `around(:each)` hook
      # in `lib/ruby_llm/contract/rspec.rb`, which snapshots and restores
      # `step_adapter_overrides` plus `configuration.default_adapter`.
      module Helpers
        include Concerns::StubHelpers
      end
    end
  end
end
