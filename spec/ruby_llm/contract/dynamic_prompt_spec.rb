# frozen_string_literal: true

RSpec.describe "Dynamic prompt — block receives |input| (ADR-0004)" do
  before { RubyLLM::Contract.reset_configuration! }

  describe "prompt block with |input|" do
    it "receives input hash and builds prompt dynamically" do
      step = Class.new(RubyLLM::Contract::Step::Base) do
        input_type Hash

        prompt do |input|
          system "Classify threads for #{input[:url]}"
          user input[:text]
        end
      end

      adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"v": 1}')
      result = step.run({ url: "acme.com", text: "hello world" }, context: { adapter: adapter })

      expect(result.status).to eq(:ok)
      messages = result.trace.messages
      expect(messages[0][:content]).to eq("Classify threads for acme.com")
      expect(messages[1][:content]).to eq("hello world")
    end

    it "supports conditional sections via Ruby if" do
      step = Class.new(RubyLLM::Contract::Step::Base) do
        input_type Hash

        prompt do |input|
          system "Classify."
          section "PAGES", input[:pages] if input[:pages]
          user input[:text]
        end
      end

      adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"v": 1}')

      # With pages
      r1 = step.run({ text: "hello", pages: "Page 1\nPage 2" }, context: { adapter: adapter })
      expect(r1.trace.messages.any? { |m| m[:content].include?("Page 1") }).to be true

      # Without pages
      r2 = step.run({ text: "hello" }, context: { adapter: adapter })
      expect(r2.trace.messages.none? { |m| m[:content]&.include?("Page 1") }).to be true
    end

    it "supports .to_json and complex transforms" do
      step = Class.new(RubyLLM::Contract::Step::Base) do
        input_type Hash

        prompt do |input|
          system "Process items."
          user input[:items].map { |i| "- #{i[:name]}" }.join("\n")
        end
      end

      adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"v": 1}')
      result = step.run({ items: [{ name: "A" }, { name: "B" }] }, context: { adapter: adapter })

      expect(result.trace.messages.last[:content]).to eq("- A\n- B")
    end

    it "works with validate" do
      step = Class.new(RubyLLM::Contract::Step::Base) do
        input_type Hash

        prompt do |input|
          system "Classify for #{input[:url]}"
          user input[:text]
        end

        validate("has result") { |o| o[:v] == 1 }
      end

      adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"v": 1}')
      result = step.run({ url: "acme.com", text: "hi" }, context: { adapter: adapter })
      expect(result.status).to eq(:ok)
    end

    it "works with output_schema" do
      step = Class.new(RubyLLM::Contract::Step::Base) do
        input_type Hash

        output_schema do
          string :intent
        end

        prompt do |input|
          system "Classify intent for #{input[:company]}"
          user input[:text]
        end
      end

      adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"intent": "billing"}')
      result = step.run({ company: "Acme", text: "invoice help" }, context: { adapter: adapter })
      expect(result.status).to eq(:ok)
      expect(result.parsed_output[:intent]).to eq("billing")
    end
  end

  describe "backward compat" do
    it "zero-arg block with {placeholder} still works" do
      step = Class.new(RubyLLM::Contract::Step::Base) do
        prompt do
          system "Classify."
          user "{input}"
        end
      end

      adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"v": 1}')
      result = step.run("hello", context: { adapter: adapter })
      expect(result.trace.messages.last[:content]).to eq("hello")
    end

    it "string prompt still works" do
      step = Class.new(RubyLLM::Contract::Step::Base) do
        prompt "Classify: {input}"
      end

      adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"v": 1}')
      result = step.run("hello", context: { adapter: adapter })
      expect(result.trace.messages.last[:content]).to eq("Classify: hello")
    end
  end
end
