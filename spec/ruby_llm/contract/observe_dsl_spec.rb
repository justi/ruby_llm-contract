# frozen_string_literal: true

RSpec.describe "observe DSL" do
  before { RubyLLM::Contract.reset_configuration! }

  let(:adapter) { RubyLLM::Contract::Adapters::Test.new(response: '{"score": 42}') }

  it "does not affect ok? status when observation fails" do
    step = Class.new(RubyLLM::Contract::Step::Base) do
      prompt "test {input}"
      observe("score below threshold") { |o| o[:score] < 10 }
    end

    result = step.run("test", context: { adapter: adapter })

    expect(result.ok?).to be true
    expect(result.status).to eq(:ok)
  end

  it "returns observation results in result.observations" do
    step = Class.new(RubyLLM::Contract::Step::Base) do
      prompt "test {input}"
      observe("score is positive") { |o| o[:score] > 0 }
      observe("score below threshold") { |o| o[:score] < 10 }
    end

    result = step.run("test", context: { adapter: adapter })

    expect(result.observations).to eq([
      { description: "score is positive", passed: true },
      { description: "score below threshold", passed: false }
    ])
  end

  it "logs failed observations via Contract.logger" do
    logger = instance_double("Logger", info: nil)
    allow(logger).to receive(:warn)

    RubyLLM::Contract.configure { |c| c.logger = logger }

    step = Class.new(RubyLLM::Contract::Step::Base) do
      prompt "test {input}"
      observe("score below threshold") { |o| o[:score] < 10 }
    end

    step.run("test", context: { adapter: adapter })

    expect(logger).to have_received(:warn).with(/observation failed: score below threshold/)
  end

  it "inherits observations from parent class" do
    parent = Class.new(RubyLLM::Contract::Step::Base) do
      prompt "test {input}"
      observe("parent check") { |o| o[:score] > 0 }
    end

    child = Class.new(parent) do
      observe("child check") { |o| o[:score] < 100 }
    end

    result = child.run("test", context: { adapter: adapter })

    descriptions = result.observations.map { |o| o[:description] }
    expect(descriptions).to eq(["parent check", "child check"])
  end

  it "does not run observations when result is not ok" do
    step = Class.new(RubyLLM::Contract::Step::Base) do
      prompt "test {input}"
      validate("must be negative") { |o| o[:score] < 0 }
      observe("should not run") { |_o| raise "this should never execute" }
    end

    result = step.run("test", context: { adapter: adapter })

    expect(result.ok?).to be false
    expect(result.observations).to eq([])
  end

  it "passes (output, input) to 2-arity observe block" do
    step = Class.new(RubyLLM::Contract::Step::Base) do
      prompt "test {input}"
      observe("input-aware check") { |o, i| o[:score] > i.to_s.length }
    end

    result = step.run("hi", context: { adapter: adapter })

    expect(result.observations).to eq([
      { description: "input-aware check", passed: true }
    ])
  end
end
