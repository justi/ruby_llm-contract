# frozen_string_literal: true

# Holds only what nothing else in the suite catches at the RubyLLM 2.x seam.
# Broad coverage of the adapter and of pricing lives in adapters/ruby_llm_spec.rb,
# cost_tracking_spec.rb and f7_max_cost_spec.rb - do not duplicate it here.
RSpec.describe "RubyLLM 2.x adapter boundary" do
  let(:adapter) { RubyLLM::Contract::Adapters::RubyLLM.new }

  def message_double(content:, input:, output:)
    instance_double("RubyLLM::Message", finish_reason: :stop, cost: RubyLLM::Cost.new, content: content,
                                        tokens: RubyLLM::Tokens.new(input: input, output: output))
  end

  # Verified, so any builder method 2.x does not define - `with_params` among them
  # - fails loudly if the adapter starts calling it. The example below passes no
  # instructions, temperature, schema, thinking or max_tokens, so no builder is
  # reached and stubbing the chain would stub nothing.
  def chat_double(response)
    instance_double("RubyLLM::Chat", ask: response)
  end

  # Measured: republishing the counts as floats keeps the Hash shape, and
  # `{a: 45.0} == {a: 45}` is true in Ruby, so every `eq` assertion elsewhere
  # stays green. This is the only example that fails.
  it "republishes token counts as Integers, not just as a Hash of the right shape" do
    allow(RubyLLM).to receive(:chat)
      .and_return(chat_double(message_double(content: "hi", input: 45, output: 12)))

    usage = adapter.call(messages: [{ role: :user, content: "Hi" }], model: "gpt-4.1-mini").usage

    expect(usage).to eq({ input_tokens: 45, output_tokens: 12 })
    expect(usage.values).to all(be_a(Integer))
  end

  # An unrecognised model shape must degrade to "unknown pricing" (nil), never to
  # a free budget. Nothing else in the suite covers this.
  describe "unreachable pricing degrades to unknown, not to free" do
    let(:shapeless) { Object.new }

    before { allow(RubyLLM::Contract::CostCalculator).to receive(:find_model).and_return(shapeless) }

    it "makes max_cost refuse the call" do
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
end
