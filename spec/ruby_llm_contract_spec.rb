# frozen_string_literal: true

RSpec.describe RubyLLM::Contract do
  # Drop redundant `not_to be_nil` — A14 / redundant with the semver match
  # below (a non-nil non-semver value would pass the old test silently).

  it "has a version matching semver format" do
    expect(RubyLLM::Contract::VERSION).to match(/\A\d+\.\d+\.\d+\z/)
  end

  # `be_a(Class)` alone is A4 — would still pass if the constant pointed at
  # any unrelated Class. Pin a structural-AND-behavioural fact instead:
  # the class genuinely inherits from `Step::Base` semantics by exposing
  # the DSL macros adopters rely on.
  it "defines Step::Base with the public DSL surface" do
    klass = RubyLLM::Contract::Step::Base
    expect(klass).to respond_to(:prompt, :validate, :retry_policy, :run)
  end

  # Same fix: Adapters::Test must respond to the adapter contract
  # (`call(messages:, **)`), not merely be some Class.
  it "defines Adapters::Test with the adapter contract" do
    expect(RubyLLM::Contract::Adapters::Test.instance_method(:call)).not_to be_nil
    expect(RubyLLM::Contract::Adapters::Test.ancestors).to include(RubyLLM::Contract::Adapters::Base)
  end
end
