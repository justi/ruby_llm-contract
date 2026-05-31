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
    # Hand-rolled fake — replaces RSpec `mock_chat = instance_double` +
    # `allow(...).to receive(:ask)` because the latter form gives a false
    # green if the adapter is refactored to call a different method (e.g.
    # `ask!` or `send_message`): `have_received(:ask)` silently never
    # fires, but the stubbed mock still returns the canned response.
    #
    # With a hand-rolled class, ANY method name change in the adapter
    # raises NoMethodError immediately — making this test diagnostic for
    # both "right argument value" AND "right method called".
    let(:fake_chat_class) do
      Class.new do
        attr_reader :asked_content, :asked_with

        def initialize(response)
          @response = response
          @asked_content = nil
          @asked_with = nil
        end

        def with_instructions(*); self; end
        def with_schema(*); self; end
        def with_temperature(*); self; end
        def with_params(*); self; end
        def with_thinking(*); self; end
        def add_message(**); end

        def ask(content, with: nil)
          @asked_content = content
          @asked_with = with
          @response
        end
      end
    end

    let(:fake_response) do
      instance_double(RubyLLM::Message, content: '{"ok":true}',
                                        input_tokens: 5, output_tokens: 3)
    end
    let(:fake_chat) { fake_chat_class.new(fake_response) }
    let(:adapter) { RubyLLM::Contract::Adapters::RubyLLM.new }

    before { allow(RubyLLM).to receive(:chat).and_return(fake_chat) }

    it "passes content + with: nil when no attachment in options (regression)" do
      result = adapter.call(messages: [{ role: :user, content: "hi" }], model: "gpt-4.1-mini")

      expect(fake_chat.asked_content).to eq("hi")
      expect(fake_chat.asked_with).to be_nil
      expect(result.usage[:input_tokens]).to eq(5)
    end

    # F1 follow-up: verify `chat.ask("text", with: nil)` works against a
    # RubyLLM::Chat double whose `ask` honours the documented 1.15.0
    # contract (chat.rb:36-37 + content.rb:8-14): non-nil text + nil
    # attachments → Content with empty attachments → text-only path.
    # If RubyLLM ever regresses by raising on `with: nil`, this test
    # catches it before adopters do.
    it "real-ish chat.ask honours with: nil per RubyLLM 1.15 contract" do
      strict_chat_class = Class.new(fake_chat_class) do
        def ask(content, with: nil)
          raise ArgumentError, "Text and attachments cannot be both nil" if content.nil? && with.nil?

          super
        end
      end

      strict = strict_chat_class.new(fake_response)
      allow(RubyLLM).to receive(:chat).and_return(strict)

      result = adapter.call(messages: [{ role: :user, content: "hi" }], model: "gpt-4.1-mini")

      expect(strict.asked_with).to be_nil
      expect(result.usage[:input_tokens]).to eq(5)
    end

    it "passes content + with: <attachment> when context attachment present" do
      result = adapter.call(
        messages: [{ role: :user, content: "describe" }],
        model: "gpt-4.1-mini",
        attachment: "tmp/picture.png"
      )

      expect(fake_chat.asked_content).to eq("describe")
      expect(fake_chat.asked_with).to eq("tmp/picture.png")
      expect(result.usage[:input_tokens]).to eq(5)
    end

    it "passes array attachment through unchanged (multi-attachment)" do
      pages = ["tmp/page1.pdf", "tmp/page2.pdf", "tmp/page3.pdf"]
      result = adapter.call(
        messages: [{ role: :user, content: "summarize" }],
        model: "gpt-4.1-mini",
        attachment: pages
      )

      expect(fake_chat.asked_content).to eq("summarize")
      expect(fake_chat.asked_with).to eq(pages)
      expect(result.usage[:input_tokens]).to eq(5)
    end

    it "passes hash-shaped attachment through unchanged (typed multi-attachment)" do
      shaped = { images: ["tmp/a.png"], pdfs: ["tmp/b.pdf"] }
      result = adapter.call(
        messages: [{ role: :user, content: "extract" }],
        model: "gpt-4.1-mini",
        attachment: shaped
      )

      expect(fake_chat.asked_content).to eq("extract")
      expect(fake_chat.asked_with).to eq(shaped)
      expect(result.usage[:input_tokens]).to eq(5)
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

      # Drop `not_to be_nil` — A4 existence-only and redundant: the bracket
      # accesses below would raise NoMethodError on nil. The diagnostic
      # comparison and inequality assertions imply non-nil.
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
      # (matching runtime check_limits semantics). The eq comparison
      # implies non-nil — a `not_to be_nil` precursor is A4 redundancy.
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
