# frozen_string_literal: true

RSpec.describe RubyLLM::Contract::Invariant do
  subject(:invariant) do
    described_class.new("must be positive", ->(val) { val > 0 })
  end

  describe "#description" do
    it "returns the description" do
      expect(invariant.description).to eq("must be positive")
    end
  end

  describe "#call" do
    it "returns true when the invariant passes" do
      expect(invariant.call(5)).to be true
    end

    it "returns false when the invariant fails" do
      expect(invariant.call(-1)).to be false
    end
  end

  describe "immutability" do
    it "is frozen" do
      expect(invariant).to be_frozen
    end
  end

  describe "2-arity call with input" do
    it "passes input as second argument when block has arity >= 2" do
      inv = described_class.new("output matches input", ->(output, input) { output[:lang] == input[:lang] })
      expect(inv.call({ lang: "fr" }, input: { lang: "fr" })).to be true
      expect(inv.call({ lang: "en" }, input: { lang: "fr" })).to be false
    end

    it "ignores input for 1-arity blocks" do
      inv = described_class.new("always passes", ->(output) { output > 0 })
      expect(inv.call(5, input: { ignored: true })).to be true
    end
  end
end
