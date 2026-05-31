# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Multimodal input" do
  describe "DSL: attachment_token_estimate" do
    it "stores positive integer and reads it back" do
      step = Class.new(RubyLLM::Contract::Step::Base) do
        prompt "test"
        attachment_token_estimate 12_500
      end

      expect(step.attachment_token_estimate).to eq(12_500)
    end

    it "raises on non-positive values" do
      expect do
        Class.new(RubyLLM::Contract::Step::Base) do
          attachment_token_estimate(-1)
        end
      end.to raise_error(ArgumentError, /must be positive/)
    end

    it "raises on non-numeric values" do
      expect do
        Class.new(RubyLLM::Contract::Step::Base) do
          attachment_token_estimate("a lot")
        end
      end.to raise_error(ArgumentError, /must be positive/)
    end

    it "inherits from superclass" do
      parent = Class.new(RubyLLM::Contract::Step::Base) do
        prompt "p"
        attachment_token_estimate 5_000
      end
      child = Class.new(parent)
      expect(child.attachment_token_estimate).to eq(5_000)
    end

    it ":default resets to nil and prevents superclass lookup" do
      parent = Class.new(RubyLLM::Contract::Step::Base) do
        prompt "p"
        attachment_token_estimate 5_000
      end
      child = Class.new(parent) do
        attachment_token_estimate :default
      end
      expect(child.attachment_token_estimate).to be_nil
    end
  end

  describe "DSL: on_unknown_attachment_size" do
    it "defaults to :refuse" do
      step = Class.new(RubyLLM::Contract::Step::Base) { prompt "t" }
      expect(step.on_unknown_attachment_size).to eq(:refuse)
    end

    it "accepts :warn" do
      step = Class.new(RubyLLM::Contract::Step::Base) do
        prompt "t"
        on_unknown_attachment_size :warn
      end
      expect(step.on_unknown_attachment_size).to eq(:warn)
    end

    it "raises on invalid mode" do
      expect do
        Class.new(RubyLLM::Contract::Step::Base) do
          on_unknown_attachment_size :ignore
        end
      end.to raise_error(ArgumentError, /must be :refuse or :warn/)
    end
  end

  describe "Adapter pass-through to chat.ask" do
    let(:mock_chat) { instance_double(RubyLLM::Chat) }
    let(:adapter) { RubyLLM::Contract::Adapters::RubyLLM.new }
    let(:mock_response) { instance_double(RubyLLM::Message, content: '{"ok":true}', input_tokens: 5, output_tokens: 3) }

    before do
      allow(RubyLLM).to receive(:chat).and_return(mock_chat)
      allow(mock_chat).to receive(:ask).and_return(mock_response)
      allow(mock_chat).to receive(:with_instructions).and_return(mock_chat)
      allow(mock_chat).to receive(:with_schema).and_return(mock_chat)
      allow(mock_chat).to receive(:with_temperature).and_return(mock_chat)
      allow(mock_chat).to receive(:with_params).and_return(mock_chat)
      allow(mock_chat).to receive(:with_thinking).and_return(mock_chat)
      allow(mock_chat).to receive(:add_message)
    end

    it "passes with: nil when no attachment in options (regression)" do
      adapter.call(messages: [{ role: :user, content: "hi" }], model: "gpt-4.1-mini")

      expect(mock_chat).to have_received(:ask).with("hi", with: nil)
    end

    it "passes with: <attachment> when context attachment present" do
      adapter.call(
        messages: [{ role: :user, content: "describe" }],
        model: "gpt-4.1-mini",
        attachment: "tmp/picture.png"
      )

      expect(mock_chat).to have_received(:ask).with("describe", with: "tmp/picture.png")
    end
  end

  describe "Fail-closed: runtime check_limits" do
    let(:adapter) { RubyLLM::Contract::Adapters::Test.new(response: '{"ok":true}') }

    it "refuses when attachment present + max_cost set + no estimate declared" do
      step = Class.new(RubyLLM::Contract::Step::Base) do
        prompt "describe {input}"
        max_cost 0.10
        # no attachment_token_estimate
      end

      result = step.run(
        "this is a photo",
        context: { adapter: adapter, model: "gpt-4.1-mini", attachment: "doc.pdf" }
      )

      expect(result.status).to eq(:limit_exceeded)
      expect(result.validation_errors.join).to include("attachment_token_estimate not declared")
    end

    it "refuses when attachment present + max_input set + no estimate declared" do
      step = Class.new(RubyLLM::Contract::Step::Base) do
        prompt "describe {input}"
        max_input 5_000
      end

      result = step.run(
        "describe",
        context: { adapter: adapter, model: "gpt-4.1-mini", attachment: "doc.pdf" }
      )

      expect(result.status).to eq(:limit_exceeded)
    end

    it "passes attachment when estimate declared and fits within limit" do
      step = Class.new(RubyLLM::Contract::Step::Base) do
        prompt "describe {input}"
        attachment_token_estimate 500
        max_input 10_000
      end

      result = step.run(
        "describe a small picture",
        context: { adapter: adapter, model: "gpt-4.1-mini", attachment: "doc.pdf" }
      )

      expect(result.status).to eq(:ok)
    end

    it "refuses when estimate + text exceeds max_input" do
      step = Class.new(RubyLLM::Contract::Step::Base) do
        prompt "describe {input}"
        attachment_token_estimate 50_000
        max_input 5_000
      end

      result = step.run(
        "describe",
        context: { adapter: adapter, model: "gpt-4.1-mini", attachment: "huge.pdf" }
      )

      expect(result.status).to eq(:limit_exceeded)
      expect(result.validation_errors.join).to include("Input token limit exceeded")
    end

    it "with on_unknown_attachment_size :warn, proceeds without enforcing attachment cost" do
      step = Class.new(RubyLLM::Contract::Step::Base) do
        prompt "describe {input}"
        max_cost 0.10
        on_unknown_attachment_size :warn
      end

      allow(step).to receive(:warn)

      result = step.run(
        "describe",
        context: { adapter: adapter, model: "gpt-4.1-mini", attachment: "doc.pdf" }
      )

      expect(result.status).to eq(:ok)
    end
  end

  describe "Fail-closed: estimate_cost parity with runtime" do
    it "estimate_cost returns nil (fail-closed) when attachment passed but no estimate declared" do
      step = Class.new(RubyLLM::Contract::Step::Base) do
        prompt "describe {input}"
      end

      result = step.estimate_cost(input: "describe", attachment: "doc.pdf")
      expect(result).to be_nil
    end

    it "estimate_cost adds attachment_token_estimate to input_tokens" do
      step = Class.new(RubyLLM::Contract::Step::Base) do
        prompt "describe {input}"
        model "gpt-4.1-mini"
        attachment_token_estimate 5_000
      end

      with_pdf = step.estimate_cost(input: "describe", attachment: "doc.pdf")
      without = step.estimate_cost(input: "describe")

      expect(with_pdf).not_to be_nil
      expect(without).not_to be_nil
      expect(with_pdf[:input_tokens]).to eq(without[:input_tokens] + 5_000)
      expect(with_pdf[:estimated_cost]).to be > without[:estimated_cost]
    end

    it "with on_unknown_attachment_size :warn, estimate_cost proceeds without attachment cost" do
      step = Class.new(RubyLLM::Contract::Step::Base) do
        prompt "describe {input}"
        model "gpt-4.1-mini"
        on_unknown_attachment_size :warn
      end

      allow(step).to receive(:warn)

      with_pdf = step.estimate_cost(input: "describe", attachment: "doc.pdf")
      without  = step.estimate_cost(input: "describe")

      # In :warn mode the attachment portion is treated as 0 tokens
      # (matching runtime check_limits semantics).
      expect(with_pdf).not_to be_nil
      expect(with_pdf[:input_tokens]).to eq(without[:input_tokens])
    end
  end

  describe "Regression: text-only contracts unaffected" do
    let(:adapter) { RubyLLM::Contract::Adapters::Test.new(response: '{"ok":true}') }

    it "no attachment + no estimate declared → text-only contract runs normally" do
      step = Class.new(RubyLLM::Contract::Step::Base) do
        prompt "summarize {input}"
        max_cost 0.10
      end

      result = step.run("summarize this", context: { adapter: adapter, model: "gpt-4.1-mini" })
      expect(result.status).to eq(:ok)
    end
  end
end
