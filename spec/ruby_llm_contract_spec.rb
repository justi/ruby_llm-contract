# frozen_string_literal: true

RSpec.describe RubyLLM::Contract do
  it "has a version number" do
    expect(RubyLLM::Contract::VERSION).not_to be_nil
  end

  it "has a version matching semver format" do
    expect(RubyLLM::Contract::VERSION).to match(/\A\d+\.\d+\.\d+\z/)
  end

  it "defines Step::Base" do
    expect(RubyLLM::Contract::Step::Base).to be_a(Class)
  end

  it "defines Adapters::Test" do
    expect(RubyLLM::Contract::Adapters::Test).to be_a(Class)
  end
end
