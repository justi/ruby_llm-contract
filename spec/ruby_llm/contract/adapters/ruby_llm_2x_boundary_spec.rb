# frozen_string_literal: true

# Pins the RubyLLM 2.x seam. Everything upstream-version-specific in this gem is
# supposed to live in Adapters::RubyLLM and CostCalculator; every other layer is
# supposed to see only this gem's own `{ input_tokens:, output_tokens: }` hash.
#
# These tests exist because the 1.x -> 2.x port moved two upstream shapes
# (Message token counters, Model pricing) and a green suite alone does not prove
# the normalised shape still reaches trace, retry aggregation, pipeline
# aggregation, max_cost and to_s.
RSpec.describe "RubyLLM 2.x adapter boundary" do
  let(:adapter) { RubyLLM::Contract::Adapters::RubyLLM.new }

  def message_double(content:, input:, output:)
    instance_double("RubyLLM::Message", content: content,
                                        tokens: RubyLLM::Tokens.new(input: input, output: output))
  end

  # Every chainable option the adapter may call, stubbed to return the chat so
  # the builder chain survives. `with_params` is deliberately absent: it does not
  # exist in 2.x, and a verified double must reject it.
  CHAINABLE = %i[with_instructions with_temperature with_max_output_tokens
                 with_thinking with_schema].freeze

  def chat_double(response)
    instance_double("RubyLLM::Chat").tap do |chat|
      CHAINABLE.each { |m| allow(chat).to receive(m).and_return(chat) }
      allow(chat).to receive(:add_message).and_return(nil)
      allow(chat).to receive(:ask).and_return(response)
    end
  end

  describe "token counters" do
    it "reads RubyLLM::Tokens and republishes this gem's flat usage hash" do
      allow(RubyLLM).to receive(:chat)
        .and_return(chat_double(message_double(content: "hi", input: 45, output: 12)))

      result = adapter.call(messages: [{ role: :user, content: "Hi" }], model: "gpt-4.1-mini")

      # The flat shape is the public contract. If this ever becomes a Tokens
      # object, every adopter reading trace[:usage] breaks.
      expect(result.usage).to eq({ input_tokens: 45, output_tokens: 12 })
    end

    it "does not leak RubyLLM::Tokens past the adapter" do
      allow(RubyLLM).to receive(:chat)
        .and_return(chat_double(message_double(content: "hi", input: 1, output: 2)))

      usage = adapter.call(messages: [{ role: :user, content: "Hi" }], model: "gpt-4.1-mini").usage

      expect(usage).to be_a(Hash)
      expect(usage.values).to all(be_a(Integer))
    end
  end

  describe "max_output_tokens" do
    it "forwards max_tokens through the 2.0 method, positionally" do
      chat = chat_double(message_double(content: "hi", input: 1, output: 1))
      allow(RubyLLM).to receive(:chat).and_return(chat)

      adapter.call(messages: [{ role: :user, content: "Hi" }], model: "gpt-4.1-mini", max_tokens: 100)

      expect(chat).to have_received(:with_max_output_tokens).with(100)
    end

    it "does not call it when max_tokens is absent" do
      chat = chat_double(message_double(content: "hi", input: 1, output: 1))
      allow(RubyLLM).to receive(:chat).and_return(chat)

      adapter.call(messages: [{ role: :user, content: "Hi" }], model: "gpt-4.1-mini")

      expect(chat).not_to have_received(:with_max_output_tokens)
    end
  end

  describe "pricing extraction" do
    # RubyLLM 2.0 dropped the flat *_price_per_million readers for a nested
    # pricing -> text_tokens -> standard walk.
    it "reads prices from the real RubyLLM 2.x model registry" do
      cost = RubyLLM::Contract::CostCalculator.calculate(
        model_name: "gpt-4.1-mini",
        usage: { input_tokens: 1_000_000, output_tokens: 0 }
      )

      model = RubyLLM.models.find("gpt-4.1-mini")
      expect(cost).to be_within(1e-9).of(model.pricing.text_tokens.standard.input_per_million)
    end

    it "still honours locally registered custom pricing" do
      RubyLLM::Contract::CostCalculator.reset_custom_models!
      RubyLLM::Contract::CostCalculator.register_model("ft:mine", input_per_1m: 10.0, output_per_1m: 20.0)

      cost = RubyLLM::Contract::CostCalculator.calculate(
        model_name: "ft:mine", usage: { input_tokens: 1_000_000, output_tokens: 1_000_000 }
      )

      expect(cost).to be_within(1e-9).of(30.0)
    ensure
      RubyLLM::Contract::CostCalculator.reset_custom_models!
    end

    it "returns nil — not zero — for a model object with no reachable pricing" do
      # A future upstream reshape must degrade to the documented "unknown
      # pricing" signal, which max_cost fails closed on. Returning 0.0 here
      # would silently let every budgeted call through.
      shapeless = Object.new
      allow(RubyLLM::Contract::CostCalculator).to receive(:find_model).and_return(shapeless)

      cost = RubyLLM::Contract::CostCalculator.calculate(
        model_name: "whatever", usage: { input_tokens: 100, output_tokens: 100 }
      )

      expect(cost).to be_nil
    end

    it "fails max_cost closed when pricing is unreachable" do
      shapeless = Object.new
      allow(RubyLLM::Contract::CostCalculator).to receive(:find_model).and_return(shapeless)

      step = Class.new(RubyLLM::Contract::Step::Base) do
        prompt "Analyze {input}"
        max_cost 0.05
      end

      result = step.run("hello", context: {
                          adapter: RubyLLM::Contract::Adapters::Test.new(response: '{"v":1}'),
                          model: "gpt-4.1-mini"
                        })

      expect(result.status).to eq(:limit_exceeded)
      expect(result.validation_errors.first).to include("no pricing data")
    end
  end

  describe "the normalised shape survives downstream" do
    let(:priced_step) do
      Class.new(RubyLLM::Contract::Step::Base) do
        prompt "Analyze {input}"
      end
    end

    it "reaches Step::Trace#usage and #cost with a real 2.x price lookup" do
      result = priced_step.run("hello", context: {
                                 adapter: RubyLLM::Contract::Adapters::Test.new(
                                   response: '{"v":1}', usage: { input_tokens: 1000, output_tokens: 500 }
                                 ),
                                 model: "gpt-4.1-mini"
                               })

      expect(result.trace.usage).to eq({ input_tokens: 1000, output_tokens: 500 })
      expect(result.trace.cost).to be_a(Float)
      expect(result.trace.cost).to be > 0
      expect(result.trace.to_s).to match(/1000\+500 tokens/)
    end
  end
end
