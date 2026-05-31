# frozen_string_literal: true

RSpec.describe RubyLLM::Contract::Error do
  it "is a direct subclass of StandardError" do
    # `be <` (A4) passes for any descendant of StandardError; a mutation
    # that re-parented this under RuntimeError would still pass. Direct
    # superclass equality pins the actual contract: this is the gem's
    # root error class right at the StandardError boundary.
    expect(described_class.superclass).to eq(StandardError)
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
  it "has RubyLLM::Contract::Error as its direct superclass" do
    # `be <` (A4) accepted any ancestor; `superclass` pins the direct parent
    # so a future contributor cannot accidentally re-parent under
    # StandardError or another sibling.
    expect(described_class.superclass).to eq(RubyLLM::Contract::Error)
  end

  it "can be instantiated with a message and details" do
    error = described_class.new("bad input", details: "expected String")
    expect(error.message).to eq("bad input")
    expect(error.details).to eq("expected String")
  end
end

RSpec.describe RubyLLM::Contract::ParseError do
  it "has RubyLLM::Contract::Error as its direct superclass" do
    # `be <` (A4) accepted any ancestor; `superclass` pins the direct parent
    # so a future contributor cannot accidentally re-parent under
    # StandardError or another sibling.
    expect(described_class.superclass).to eq(RubyLLM::Contract::Error)
  end

  it "can be instantiated with a message and details" do
    error = described_class.new("parse failed", details: "raw output")
    expect(error.message).to eq("parse failed")
    expect(error.details).to eq("raw output")
  end
end

RSpec.describe RubyLLM::Contract::ContractError do
  it "has RubyLLM::Contract::Error as its direct superclass" do
    # `be <` (A4) accepted any ancestor; `superclass` pins the direct parent
    # so a future contributor cannot accidentally re-parent under
    # StandardError or another sibling.
    expect(described_class.superclass).to eq(RubyLLM::Contract::Error)
  end

  it "can be instantiated with a message and details" do
    error = described_class.new("contract violated", details: ["invariant 1"])
    expect(error.message).to eq("contract violated")
    expect(error.details).to eq(["invariant 1"])
  end
end

RSpec.describe RubyLLM::Contract::AdapterError do
  it "has RubyLLM::Contract::Error as its direct superclass" do
    # `be <` (A4) accepted any ancestor; `superclass` pins the direct parent
    # so a future contributor cannot accidentally re-parent under
    # StandardError or another sibling.
    expect(described_class.superclass).to eq(RubyLLM::Contract::Error)
  end

  it "can be instantiated with a message and details" do
    error = described_class.new("adapter failed", details: "timeout")
    expect(error.message).to eq("adapter failed")
    expect(error.details).to eq("timeout")
  end
end
