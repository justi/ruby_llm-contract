# frozen_string_literal: true

RSpec.describe RubyLLM::Contract::Adapters::Base do
  describe "#call" do
    it "raises NotImplementedError" do
      adapter = described_class.new
      expect { adapter.call(messages: []) }.to raise_error(NotImplementedError, "Subclasses must implement #call")
    end
  end
end
