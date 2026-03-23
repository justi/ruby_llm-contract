# frozen_string_literal: true

RSpec.describe RubyLLM::Contract::Adapters::Test do
  subject(:adapter) { described_class.new(response: '{"intent":"sales"}') }

  describe "#call" do
    it "returns the canned response content" do
      response = adapter.call(messages: [{ role: :user, content: "hello" }])
      expect(response.content).to eq('{"intent":"sales"}')
    end

    it "returns a response with usage" do
      response = adapter.call(messages: [])
      expect(response.usage).to eq({ input_tokens: 0, output_tokens: 0 })
    end

    it "ignores the messages argument" do
      r1 = adapter.call(messages: [{ role: :user, content: "hello" }])
      r2 = adapter.call(messages: [{ role: :user, content: "goodbye" }])
      expect(r1.content).to eq(r2.content)
    end
  end

  it "is a subclass of Adapters::Base" do
    expect(described_class).to be < RubyLLM::Contract::Adapters::Base
  end

  it "returns an Adapters::Response" do
    response = adapter.call(messages: [])
    expect(response).to be_a(RubyLLM::Contract::Adapters::Response)
  end

  describe "response:/responses: consistency for Hashes" do
    it "produces same raw_output type (String) regardless of constructor form" do
      step = Class.new(RubyLLM::Contract::Step::Base) do
        prompt { user "{input}" }
        output_type RubyLLM::Contract::Types::Hash
        contract { parse :json }
      end

      adapter_single = described_class.new(response: { "name" => "Alice" })
      adapter_array = described_class.new(responses: [{ "name" => "Alice" }])

      result_single = step.run("test", context: { adapter: adapter_single })
      result_array = step.run("test", context: { adapter: adapter_array })

      expect(result_single.raw_output).to be_a(String)
      expect(result_array.raw_output).to be_a(String)
      expect(result_single.parsed_output).to eq(result_array.parsed_output)
    end
  end

  describe "responses: array" do
    it "raises ArgumentError when responses is an empty array" do
      expect do
        described_class.new(responses: [])
      end.to raise_error(ArgumentError, /must not be empty/)
    end
  end
end
