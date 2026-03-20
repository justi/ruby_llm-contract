# frozen_string_literal: true

RSpec.describe "Step-level execution limits (GH-17)" do
  before { RubyLLM::Contract.reset_configuration! }

  describe "max_input" do
    it "refuses before LLM call when estimated tokens exceed limit" do
      adapter_called = false
      spy_adapter = Class.new(RubyLLM::Contract::Adapters::Base) do
        define_method(:call) do |messages:, **_opts|
          adapter_called = true
          RubyLLM::Contract::Adapters::Response.new(content: '{"v":1}', usage: { input_tokens: 0, output_tokens: 0 })
        end
      end.new

      step = Class.new(RubyLLM::Contract::Step::Base) do
        prompt "This is a prompt that will generate some tokens: {input}"
        max_input 5  # very low limit — will be exceeded
      end

      result = step.run("hello world this is a test input", context: { adapter: spy_adapter })

      expect(result.status).to eq(:limit_exceeded)
      expect(adapter_called).to be false
      expect(result.validation_errors.first).to include("Input token limit exceeded")
    end

    it "allows call when within limit" do
      adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"v": 1}')

      step = Class.new(RubyLLM::Contract::Step::Base) do
        prompt "Hi {input}"
        max_input 100_000
      end

      result = step.run("test", context: { adapter: adapter })
      expect(result.status).to eq(:ok)
    end

    it "includes estimation metadata in trace" do
      adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"v": 1}')

      step = Class.new(RubyLLM::Contract::Step::Base) do
        prompt "This prompt has some content: {input}"
        max_input 5  # will be exceeded
      end

      result = step.run("test", context: { adapter: adapter })
      usage = result.trace.usage

      expect(usage[:estimated_input_tokens]).to be_a(Integer)
      expect(usage[:estimated_input_tokens]).to be > 0
      expect(usage[:estimate_method]).to eq(:heuristic)
    end
  end

  describe "max_cost" do
    it "refuses before LLM call when estimated cost exceeds limit" do
      adapter_called = false
      spy_adapter = Class.new(RubyLLM::Contract::Adapters::Base) do
        define_method(:call) do |messages:, **_opts|
          adapter_called = true
          RubyLLM::Contract::Adapters::Response.new(content: '{"v":1}', usage: { input_tokens: 0, output_tokens: 0 })
        end
      end.new

      # Build a step with a very long prompt to make cost estimation high
      long_text = "x" * 40_000  # ~10,000 tokens → at $0.40/M = $0.004

      step = Class.new(RubyLLM::Contract::Step::Base) do
        prompt "Analyze: {input}"
        max_cost 0.0001  # very low — will be exceeded with gpt-4.1-mini pricing
      end

      result = step.run(long_text, context: { adapter: spy_adapter, model: "gpt-4.1-mini" })

      expect(result.status).to eq(:limit_exceeded)
      expect(adapter_called).to be false
      expect(result.validation_errors.first).to include("Cost limit exceeded")
    end

    it "allows call when within cost limit" do
      adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"v": 1}')

      step = Class.new(RubyLLM::Contract::Step::Base) do
        prompt "Hi {input}"
        max_cost 1.00  # generous
      end

      result = step.run("test", context: { adapter: adapter, model: "gpt-4.1-mini" })
      expect(result.status).to eq(:ok)
    end

    it "warns when model pricing unavailable but still runs" do
      adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"v": 1}')

      step = Class.new(RubyLLM::Contract::Step::Base) do
        prompt "Hi {input}"
        max_cost 0.0001  # very low
      end

      # Unknown model — no pricing data — warn issued, call still proceeds
      result = step.run("test", context: { adapter: adapter, model: "unknown-model-xyz" })
      expect(result.status).to eq(:ok) # call was not blocked — fail-open with warning
    end
  end

  describe "no limits set" do
    it "behaves normally (no preflight check)" do
      adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"v": 1}')

      step = Class.new(RubyLLM::Contract::Step::Base) do
        prompt "Hi {input}"
      end

      result = step.run("test", context: { adapter: adapter })
      expect(result.status).to eq(:ok)
    end
  end

  describe "TokenEstimator" do
    it "estimates tokens from messages" do
      messages = [
        { role: :system, content: "You are a classifier." },
        { role: :user, content: "Classify this text please." }
      ]

      estimate = RubyLLM::Contract::TokenEstimator.estimate(messages)
      # "You are a classifier." = 21 chars + "Classify this text please." = 26 chars = 47 chars
      # 47 / 4 = 11.75 → ceil = 12
      expect(estimate).to eq(12)
    end

    it "returns 0 for empty messages" do
      expect(RubyLLM::Contract::TokenEstimator.estimate([])).to eq(0)
    end
  end
end
