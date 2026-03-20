# frozen_string_literal: true

RSpec.describe RubyLLM::Contract::Types do
  describe "String" do
    it "validates a string" do
      expect(RubyLLM::Contract::Types::String["hello"]).to eq("hello")
    end

    it "rejects a non-string" do
      expect { RubyLLM::Contract::Types::String[123] }.to raise_error(Dry::Types::ConstraintError)
    end
  end

  describe "Hash" do
    it "is available" do
      expect(RubyLLM::Contract::Types::Hash).to be_a(Dry::Types::Type)
    end
  end

  describe "Array" do
    it "is available" do
      expect(RubyLLM::Contract::Types::Array).to be_a(Dry::Types::Type)
    end
  end
end
