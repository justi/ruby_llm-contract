# frozen_string_literal: true

require "ruby_llm/contract"

require_relative "rspec/satisfy_contract"
require_relative "rspec/pass_eval"
require_relative "rspec/helpers"

RSpec.configure do |config|
  config.include RubyLLM::Contract::RSpec::Helpers

  # Auto-cleanup: snapshot adapter before each example, restore after.
  # Prevents non-block stub_all_steps from leaking between examples.
  config.around(:each) do |example|
    original_adapter = RubyLLM::Contract.configuration.default_adapter
    original_overrides = RubyLLM::Contract.step_adapter_overrides.dup
    begin
      example.run
    ensure
      RubyLLM::Contract.configuration.default_adapter = original_adapter
      RubyLLM::Contract.step_adapter_overrides.replace(original_overrides)
    end
  end
end if defined?(::RSpec)
