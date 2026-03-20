# frozen_string_literal: true

RSpec.describe RubyLLM::Contract::Error do
  it "is a subclass of StandardError" do
    expect(described_class).to be < StandardError
  end

  it "can be instantiated with a message" do
    error = described_class.new("something went wrong")
    expect(error.message).to eq("something went wrong")
  end

  it "can be instantiated with a message and details" do
    error = described_class.new("something went wrong", details: { key: "value" })
    expect(error.message).to eq("something went wrong")
    expect(error.details).to eq({ key: "value" })
  end

  it "defaults details to nil" do
    error = described_class.new("oops")
    expect(error.details).to be_nil
  end
end

RSpec.describe RubyLLM::Contract::InputError do
  it "is a subclass of RubyLLM::Contract::Error" do
    expect(described_class).to be < RubyLLM::Contract::Error
  end

  it "can be instantiated with a message and details" do
    error = described_class.new("bad input", details: "expected String")
    expect(error.message).to eq("bad input")
    expect(error.details).to eq("expected String")
  end
end

RSpec.describe RubyLLM::Contract::ParseError do
  it "is a subclass of RubyLLM::Contract::Error" do
    expect(described_class).to be < RubyLLM::Contract::Error
  end

  it "can be instantiated with a message and details" do
    error = described_class.new("parse failed", details: "raw output")
    expect(error.message).to eq("parse failed")
    expect(error.details).to eq("raw output")
  end
end

RSpec.describe RubyLLM::Contract::ContractError do
  it "is a subclass of RubyLLM::Contract::Error" do
    expect(described_class).to be < RubyLLM::Contract::Error
  end

  it "can be instantiated with a message and details" do
    error = described_class.new("contract violated", details: ["invariant 1"])
    expect(error.message).to eq("contract violated")
    expect(error.details).to eq(["invariant 1"])
  end
end

RSpec.describe RubyLLM::Contract::AdapterError do
  it "is a subclass of RubyLLM::Contract::Error" do
    expect(described_class).to be < RubyLLM::Contract::Error
  end

  it "can be instantiated with a message and details" do
    error = described_class.new("adapter failed", details: "timeout")
    expect(error.message).to eq("adapter failed")
    expect(error.details).to eq("timeout")
  end
end
