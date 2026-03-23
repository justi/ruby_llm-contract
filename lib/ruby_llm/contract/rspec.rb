# frozen_string_literal: true

require "ruby_llm/contract"

require_relative "rspec/satisfy_contract"
require_relative "rspec/pass_eval"
require_relative "rspec/helpers"

RSpec.configure do |config|
  config.include RubyLLM::Contract::RSpec::Helpers
end if defined?(::RSpec)
