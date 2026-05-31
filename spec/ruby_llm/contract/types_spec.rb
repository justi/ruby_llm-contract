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
    it "validates a hash" do
      expect(RubyLLM::Contract::Types::Hash[{ a: 1 }]).to eq({ a: 1 })
    end

    it "rejects a non-hash" do
      expect { RubyLLM::Contract::Types::Hash["not a hash"] }
        .to raise_error(Dry::Types::ConstraintError)
    end
  end

  describe "Array" do
    it "validates an array" do
      expect(RubyLLM::Contract::Types::Array[[1, 2]]).to eq([1, 2])
    end

    it "rejects a non-array" do
      expect { RubyLLM::Contract::Types::Array["not an array"] }
        .to raise_error(Dry::Types::ConstraintError)
    end
  end
end
