# frozen_string_literal: true

RSpec.describe "Plain prompt entry with JSON defaults (ADR-0002)" do
  before { RubyLLM::Contract.reset_configuration! }

  describe "2-line minimum step" do
    it "works with just prompt string + validate" do
      step = Class.new(RubyLLM::Contract::Step::Base) do
        prompt "Classify this: {input}"
        validate("has intent") { |o| !o[:intent].to_s.empty? }
      end

      adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"intent": "billing"}')
      result = step.run("help with invoice", context: { adapter: adapter })

      expect(result.status).to eq(:ok)
      expect(result.parsed_output).to eq({ intent: "billing" })
    end
  end

  describe "defaults" do
    it "input_type defaults to String" do
      step = Class.new(RubyLLM::Contract::Step::Base) do
        prompt "test {input}"
      end

      adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"v": 1}')
      result = step.run("hello", context: { adapter: adapter })
      expect(result.status).to eq(:ok)
    end

    it "output_type defaults to Hash" do
      step = Class.new(RubyLLM::Contract::Step::Base) do
        prompt "test {input}"
      end

      adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"v": 1}')
      result = step.run("hello", context: { adapter: adapter })
      expect(result.parsed_output).to eq({ v: 1 })
    end

    it "parse defaults to :json (from Hash output)" do
      step = Class.new(RubyLLM::Contract::Step::Base) do
        prompt "test {input}"
        validate("has key") { |o| o[:v] == 1 }
      end

      adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"v": 1}')
      result = step.run("hello", context: { adapter: adapter })
      expect(result.status).to eq(:ok)
    end

    it "rejects non-String input by default" do
      step = Class.new(RubyLLM::Contract::Step::Base) do
        prompt "test {input}"
      end

      adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"v": 1}')
      result = step.run(42, context: { adapter: adapter })
      expect(result.status).to eq(:input_error)
    end
  end

  describe "prompt as string" do
    it "renders as user message" do
      step = Class.new(RubyLLM::Contract::Step::Base) do
        prompt "Classify this: {input}"
      end

      adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"v": 1}')
      result = step.run("hello", context: { adapter: adapter })

      messages = result.trace.messages
      expect(messages.size).to eq(1)
      expect(messages[0][:role]).to eq(:user)
      expect(messages[0][:content]).to eq("Classify this: hello")
    end
  end

  describe "explicit overrides still work" do
    it "explicit output_type String gives text output" do
      step = Class.new(RubyLLM::Contract::Step::Base) do
        output_type String
        prompt "test {input}"
      end

      adapter = RubyLLM::Contract::Adapters::Test.new(response: "plain text")
      result = step.run("hello", context: { adapter: adapter })

      expect(result.status).to eq(:ok)
      expect(result.parsed_output).to eq("plain text")
    end

    it "prompt block still works" do
      step = Class.new(RubyLLM::Contract::Step::Base) do
        prompt do
          system "You are a classifier."
          user "{input}"
        end
      end

      adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"v": 1}')
      result = step.run("hello", context: { adapter: adapter })

      expect(result.trace.messages.size).to eq(2)
      expect(result.trace.messages[0][:role]).to eq(:system)
    end

    it "explicit input_type still works" do
      step = Class.new(RubyLLM::Contract::Step::Base) do
        input_type Hash
        prompt "test {input}"
      end

      adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"v": 1}')
      result = step.run({ key: "val" }, context: { adapter: adapter })
      expect(result.status).to eq(:ok)
    end
  end

  describe "progression path" do
    it "level 0: prompt string only" do
      step = Class.new(RubyLLM::Contract::Step::Base) do
        prompt "Classify: {input}"
      end

      adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"intent": "sales"}')
      result = step.run("upgrade plan", context: { adapter: adapter })
      expect(result.parsed_output[:intent]).to eq("sales")
    end

    it "level 1: prompt string + validate" do
      step = Class.new(RubyLLM::Contract::Step::Base) do
        prompt "Classify: {input}"
        validate("valid intent") { |o| %w[sales support billing].include?(o[:intent]) }
      end

      adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"intent": "sales"}')
      result = step.run("upgrade", context: { adapter: adapter })
      expect(result.status).to eq(:ok)
    end

    it "level 2: prompt block + validate" do
      step = Class.new(RubyLLM::Contract::Step::Base) do
        prompt do
          system "You are a classifier."
          rule "Return JSON with intent."
          user "{input}"
        end
        validate("valid intent") { |o| %w[sales support billing].include?(o[:intent]) }
      end

      adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"intent": "billing"}')
      result = step.run("invoice help", context: { adapter: adapter })
      expect(result.status).to eq(:ok)
    end
  end
end
