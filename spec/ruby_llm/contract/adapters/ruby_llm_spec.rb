# frozen_string_literal: true

RSpec.describe RubyLLM::Contract::Adapters::RubyLLM do
  let(:adapter) { described_class.new }

  let(:mock_response) do
    instance_double(
      "RubyLLM::Message",
      content: '{"intent":"sales"}',
      input_tokens: 45,
      output_tokens: 12
    )
  end

  let(:mock_chat) do
    instance_double("RubyLLM::Chat").tap do |chat|
      allow(chat).to receive(:with_instructions).and_return(chat)
      allow(chat).to receive(:with_temperature).and_return(chat)
      allow(chat).to receive(:with_params).and_return(chat)
      allow(chat).to receive(:with_thinking).and_return(chat)
      allow(chat).to receive(:add_message).and_return(nil)
      allow(chat).to receive(:ask).and_return(mock_response)
    end
  end

  before do
    allow(RubyLLM).to receive(:chat).and_return(mock_chat)
  end

  describe "interface conformance" do
    it "is a subclass of Adapters::Base" do
      expect(adapter).to be_a(RubyLLM::Contract::Adapters::Base)
    end
  end

  describe "#call" do
    context "with a simple user message" do
      let(:messages) do
        [{ role: :user, content: "Hello" }]
      end

      it "returns an Adapters::Response with content and usage" do
        result = adapter.call(messages: messages, model: "gpt-4.1-mini")

        expect(result).to be_a(RubyLLM::Contract::Adapters::Response)
        expect(result.content).to eq('{"intent":"sales"}')
        expect(result.usage).to eq({ input_tokens: 45, output_tokens: 12 })
      end

      it "sends the user message via chat.ask" do
        adapter.call(messages: messages, model: "gpt-4.1-mini")

        expect(mock_chat).to have_received(:ask).with("Hello")
      end

      it "passes model to RubyLLM.chat" do
        adapter.call(messages: messages, model: "gpt-4.1-mini")

        expect(RubyLLM).to have_received(:chat).with(model: "gpt-4.1-mini")
      end
    end

    context "with multiple system messages" do
      let(:messages) do
        [
          { role: :system, content: "You are a classifier." },
          { role: :system, content: "Return JSON only." },
          { role: :system, content: "Allowed intents: sales, support." },
          { role: :user, content: "I want to buy" }
        ]
      end

      it "joins system messages with double newline as instructions" do
        adapter.call(messages: messages, model: "gpt-4.1-mini")

        expect(mock_chat).to have_received(:with_instructions)
          .with("You are a classifier.\n\nReturn JSON only.\n\nAllowed intents: sales, support.")
      end
    end

    context "with user and assistant messages for few-shot examples" do
      let(:messages) do
        [
          { role: :system, content: "Classify intent." },
          { role: :user, content: "I want to buy" },
          { role: :assistant, content: '{"intent":"sales"}' },
          { role: :user, content: "Help with my bill" }
        ]
      end

      it "adds assistant messages to chat history before the final ask" do
        adapter.call(messages: messages, model: "gpt-4.1-mini")

        expect(mock_chat).to have_received(:add_message)
          .with(role: :user, content: "I want to buy")
        expect(mock_chat).to have_received(:add_message)
          .with(role: :assistant, content: '{"intent":"sales"}')
        expect(mock_chat).to have_received(:ask).with("Help with my bill")
      end
    end

    context "with temperature option" do
      it "forwards temperature to the chat" do
        adapter.call(messages: [{ role: :user, content: "Hi" }], model: "gpt-4.1-mini", temperature: 0.0)

        expect(mock_chat).to have_received(:with_temperature).with(0.0)
      end
    end

    context "without temperature option" do
      it "does not call with_temperature" do
        adapter.call(messages: [{ role: :user, content: "Hi" }], model: "gpt-4.1-mini")

        expect(mock_chat).not_to have_received(:with_temperature)
      end
    end

    context "with max_tokens option" do
      it "forwards max_tokens to the chat" do
        adapter.call(messages: [{ role: :user, content: "Hi" }], model: "gpt-4.1-mini", max_tokens: 100)

        expect(mock_chat).to have_received(:with_params).with(max_tokens: 100)
      end
    end

    context "with reasoning_effort option" do
      it "forwards reasoning_effort via with_thinking (canonical path since 0.8)" do
        adapter.call(messages: [{ role: :user, content: "Hi" }], model: "gpt-4.1-mini", reasoning_effort: "low")

        expect(mock_chat).to have_received(:with_thinking).with(effort: "low")
      end
    end

    context "with both max_tokens and reasoning_effort" do
      it "forwards reasoning_effort via with_thinking and max_tokens via with_params" do
        adapter.call(messages: [{ role: :user, content: "Hi" }], model: "gpt-4.1-mini",
                     max_tokens: 100, reasoning_effort: "high")

        expect(mock_chat).to have_received(:with_thinking).with(effort: "high")
        expect(mock_chat).to have_received(:with_params).with(max_tokens: 100)
      end
    end

    context "without max_tokens or reasoning_effort" do
      it "does not call with_params" do
        adapter.call(messages: [{ role: :user, content: "Hi" }], model: "gpt-4.1-mini")

        expect(mock_chat).not_to have_received(:with_params)
      end
    end

    context "when ruby_llm raises an error" do
      before do
        allow(mock_chat).to receive(:ask).and_raise(StandardError, "API key invalid")
      end

      it "lets the error propagate" do
        expect do
          adapter.call(messages: [{ role: :user, content: "Hi" }], model: "gpt-4.1-mini")
        end.to raise_error(StandardError, "API key invalid")
      end
    end

    context "with system-only messages (no user message)" do
      let(:messages) do
        [
          { role: :system, content: "You are a keyword generator." },
          { role: :system, content: "Return JSON only." }
        ]
      end

      it "sends last system message as user ask instead of nil" do
        adapter.call(messages: messages, model: "gpt-4.1-mini")

        expect(mock_chat).to have_received(:ask).with("Return JSON only.")
      end

      it "uses remaining system messages as instructions" do
        adapter.call(messages: messages, model: "gpt-4.1-mini")

        expect(mock_chat).to have_received(:with_instructions).with("You are a keyword generator.")
      end
    end

    context "with completely empty messages array" do
      let(:messages) { [] }

      it "sends empty string instead of nil to chat.ask" do
        adapter.call(messages: messages, model: "gpt-4.1-mini")

        expect(mock_chat).to have_received(:ask).with("")
      end
    end

    context "statelessness" do
      it "creates a fresh chat instance per call" do
        adapter.call(messages: [{ role: :user, content: "First" }], model: "gpt-4.1-mini")
        adapter.call(messages: [{ role: :user, content: "Second" }], model: "gpt-4.1-mini")

        expect(RubyLLM).to have_received(:chat).twice
      end
    end

    context "with nil token counts" do
      let(:mock_response) do
        instance_double(
          "RubyLLM::Message",
          content: "hello",
          input_tokens: nil,
          output_tokens: nil
        )
      end

      it "defaults token counts to zero" do
        result = adapter.call(messages: [{ role: :user, content: "Hi" }], model: "gpt-4.1-mini")

        expect(result.usage).to eq({ input_tokens: 0, output_tokens: 0 })
      end
    end

    context "with schema option" do
      before do
        allow(mock_chat).to receive(:with_schema).and_return(mock_chat)
      end

      it "calls with_schema on the chat object" do
        schema = double("schema")
        adapter.call(messages: [{ role: :user, content: "Hi" }], model: "gpt-4.1-mini", schema: schema)

        expect(mock_chat).to have_received(:with_schema).with(schema)
      end
    end

    context "with Hash content from response (structured output)" do
      let(:mock_response) do
        instance_double(
          "RubyLLM::Message",
          content: { "intent" => "sales", "confidence" => 0.9 },
          input_tokens: 20,
          output_tokens: 10
        )
      end

      it "preserves Hash content without converting to string" do
        result = adapter.call(messages: [{ role: :user, content: "Hi" }], model: "gpt-4.1-mini")
        expect(result.content).to eq({ "intent" => "sales", "confidence" => 0.9 })
        expect(result.content).to be_a(Hash)
      end
    end

    context "with provider option" do
      it "forwards provider to RubyLLM.chat" do
        adapter.call(messages: [{ role: :user, content: "Hi" }], model: "gpt-4.1-mini", provider: :openai)
        expect(RubyLLM).to have_received(:chat).with(model: "gpt-4.1-mini", provider: :openai)
      end
    end

    context "with assume_model_exists option" do
      it "forwards assume_model_exists to RubyLLM.chat" do
        adapter.call(messages: [{ role: :user, content: "Hi" }], model: "custom-model", assume_model_exists: true)
        expect(RubyLLM).to have_received(:chat).with(model: "custom-model", assume_model_exists: true)
      end
    end
  end
end
