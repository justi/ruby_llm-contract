# frozen_string_literal: true

RSpec.describe RubyLLM::Contract::Definition do
  describe "building with DSL" do
    it "stores parse strategy and invariants" do
      definition = described_class.new do
        parse :json
        invariant("must include intent") { |o| o["intent"].to_s != "" }
        invariant("intent must be allowed") { |o| %w[sales support].include?(o["intent"]) }
      end

      expect(definition.parse_strategy).to eq(:json)
      expect(definition.invariants.size).to eq(2)
      expect(definition.invariants[0].description).to eq("must include intent")
      expect(definition.invariants[1].description).to eq("intent must be allowed")
    end
  end

  describe "defaults" do
    it "defaults parse_strategy to :text" do
      definition = described_class.new
      expect(definition.parse_strategy).to eq(:text)
    end

    it "defaults invariants to empty array" do
      definition = described_class.new
      expect(definition.invariants).to eq([])
    end
  end

  describe "invariants immutability" do
    it "returns frozen invariants array" do
      definition = described_class.new do
        invariant("test") { |_| true }
      end

      expect(definition.invariants).to be_frozen
    end
  end

  describe ".build" do
    it "is a convenience constructor" do
      definition = described_class.build do
        parse :json
      end

      expect(definition).to be_a(described_class)
      expect(definition.parse_strategy).to eq(:json)
    end
  end

  describe "validate alias" do
    it "validate is an alias for invariant inside contract DSL" do
      definition = described_class.new do
        parse :json
        validate("from validate alias") { |o| o[:v] == 1 }
      end

      expect(definition.invariants.size).to eq(1)
      expect(definition.invariants[0].description).to eq("from validate alias")
    end
  end
end
