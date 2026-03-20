# frozen_string_literal: true

RSpec.describe "Prompt nodes auto-convert Hash/Array to JSON" do
  before { RubyLLM::Contract.reset_configuration! }

  it "user node converts Array to JSON" do
    step = Class.new(RubyLLM::Contract::Step::Base) do
      input_type Hash
      prompt do |input|
        user input[:items]
      end
    end

    adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"v": 1}')
    result = step.run({ items: [{ id: "t1" }, { id: "t2" }] }, context: { adapter: adapter })

    content = result.trace.messages.last[:content]
    expect(content).to be_a(String)
    expect(JSON.parse(content)).to eq([{ "id" => "t1" }, { "id" => "t2" }])
  end

  it "user node converts Hash to JSON" do
    step = Class.new(RubyLLM::Contract::Step::Base) do
      input_type Hash
      prompt do |input|
        user input[:data]
      end
    end

    adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"v": 1}')
    result = step.run({ data: { key: "val" } }, context: { adapter: adapter })

    content = result.trace.messages.last[:content]
    expect(content).to be_a(String)
    expect(JSON.parse(content)).to eq({ "key" => "val" })
  end

  it "user node keeps String as-is" do
    step = Class.new(RubyLLM::Contract::Step::Base) do
      input_type Hash
      prompt do |input|
        user input[:text]
      end
    end

    adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"v": 1}')
    result = step.run({ text: "hello" }, context: { adapter: adapter })
    expect(result.trace.messages.last[:content]).to eq("hello")
  end

  it "section node converts Hash/Array to JSON" do
    step = Class.new(RubyLLM::Contract::Step::Base) do
      input_type Hash
      prompt do |input|
        section "DATA", input[:items]
        user "process"
      end
    end

    adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"v": 1}')
    result = step.run({ items: [1, 2, 3] }, context: { adapter: adapter })

    section_msg = result.trace.messages.find { |m| m[:content].include?("[DATA]") }
    expect(section_msg[:content]).to include("[DATA]")
    expect(section_msg[:content]).to include("1,2,3")
  end
end
