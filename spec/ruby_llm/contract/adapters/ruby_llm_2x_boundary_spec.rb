# frozen_string_literal: true

# What ONLY this file defends at the RubyLLM 2.x seam. The original version of
# this spec had nine examples; six were removed after measuring that other files
# already caught the same mutants (3-17 failures each with this file excluded).
# Those six are covered by:
#
#   flat usage hash from Message#tokens -> adapters/ruby_llm_spec.rb:41,
#                                         step/multimodal_input_spec.rb:118..175
#   with_max_output_tokens forwarding   -> adapters/ruby_llm_spec.rb:140,:156,:166,
#                                         step/thinking_dsl_spec.rb:191,:202,:209
#   nested pricing walk                 -> cost_tracking_spec.rb:7, f7_max_cost_spec.rb,
#                                         step_limits_spec.rb, and 14 others
#   locally registered pricing          -> f7_max_cost_spec.rb:78,:95,:112
#   cost/to_s/usage reaching the trace  -> cost_tracking_spec.rb:7, pretty_print_spec.rb:12
#
# Do not re-add them here. What remains is what nothing else catches.
RSpec.describe "RubyLLM 2.x adapter boundary" do
  let(:adapter) { RubyLLM::Contract::Adapters::RubyLLM.new }

  def message_double(content:, input:, output:)
    instance_double("RubyLLM::Message", content: content,
                                        tokens: RubyLLM::Tokens.new(input: input, output: output))
  end

  # `with_params` is deliberately absent: it does not exist in 2.x, and a verified
  # double must reject it. Spelled out rather than looped - a constant inside a
  # describe block leaks onto Object.
  def chat_double(response)
    chat = instance_double("RubyLLM::Chat", add_message: nil, ask: response)
    allow(chat).to receive(:with_instructions).and_return(chat)
    allow(chat).to receive(:with_temperature).and_return(chat)
    allow(chat).to receive(:with_max_output_tokens).and_return(chat)
    allow(chat).to receive(:with_thinking).and_return(chat)
    allow(chat).to receive(:with_schema).and_return(chat)
    chat
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

  # The fail-closed branch: an unrecognised model shape must degrade to "unknown
  # pricing" (nil), never to a free budget (0.0). Measured: mutating that return
  # to [0.0, 0.0] fails only these two examples, nothing else in the suite.
  describe "unreachable pricing degrades to unknown, not to free" do
    let(:shapeless) { Object.new }

    before { allow(RubyLLM::Contract::CostCalculator).to receive(:find_model).and_return(shapeless) }

    it "returns nil rather than zero" do
      cost = RubyLLM::Contract::CostCalculator.calculate(
        model_name: "whatever", usage: { input_tokens: 100, output_tokens: 100 }
      )

      expect(cost).to be_nil
    end

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
