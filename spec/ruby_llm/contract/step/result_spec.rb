# frozen_string_literal: true

RSpec.describe RubyLLM::Contract::Step::Result do
  describe "construction" do
    it "stores all attributes" do
      result = described_class.new(
        status: :ok,
        raw_output: '{"intent":"sales"}',
        parsed_output: { "intent" => "sales" },
        validation_errors: [],
        trace: { model: "gpt-4" }
      )

      expect(result.status).to eq(:ok)
      expect(result.raw_output).to eq('{"intent":"sales"}')
      expect(result.parsed_output).to eq({ "intent" => "sales" })
      expect(result.validation_errors).to eq([])
      expect(result.trace).to eq({ model: "gpt-4" })
    end
  end

  describe "#ok?" do
    it "returns true for :ok status" do
      result = described_class.new(status: :ok, raw_output: nil, parsed_output: nil)
      expect(result.ok?).to be true
    end

    it "returns false for non-:ok status" do
      result = described_class.new(status: :input_error, raw_output: nil, parsed_output: nil)
      expect(result.ok?).to be false
    end
  end

  describe "#failed?" do
    it "returns true for non-:ok status" do
      result = described_class.new(status: :parse_error, raw_output: nil, parsed_output: nil)
      expect(result.failed?).to be true
    end

    it "returns false for :ok status" do
      result = described_class.new(status: :ok, raw_output: nil, parsed_output: nil)
      expect(result.failed?).to be false
    end
  end

  describe "immutability" do
    it "is frozen after construction" do
      result = described_class.new(status: :ok, raw_output: nil, parsed_output: nil)
      expect(result).to be_frozen
    end

    it "has frozen validation_errors" do
      result = described_class.new(status: :ok, raw_output: nil, parsed_output: nil, validation_errors: ["error"])
      expect(result.validation_errors).to be_frozen
    end

    it "has frozen trace" do
      result = described_class.new(status: :ok, raw_output: nil, parsed_output: nil, trace: { model: "gpt-4" })
      expect(result.trace).to be_frozen
    end
  end

  describe "defaults" do
    it "defaults validation_errors to empty array" do
      result = described_class.new(status: :ok, raw_output: nil, parsed_output: nil)
      expect(result.validation_errors).to eq([])
    end

    it "defaults trace to empty hash" do
      result = described_class.new(status: :ok, raw_output: nil, parsed_output: nil)
      expect(result.trace).to eq({})
    end
  end
end
