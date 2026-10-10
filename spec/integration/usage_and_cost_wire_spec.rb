# frozen_string_literal: true

require "webmock"

# Token counts and cost come from a real RubyLLM response parsed from a real
# OpenAI Responses payload, with HTTP intercepted - so the cache split, the
# missing-usage case and RubyLLM's own pricing are exercised as shipped, not
# through doubles that only return what the test put in.
RSpec.describe "Usage and cost through the RubyLLM adapter (HTTP intercepted)" do
  include WebMock::API

  let(:step) do
    Class.new(RubyLLM::Contract::Step::Base) do
      prompt "Classify: {input}"
      output_schema { string :label }
    end
  end

  around do |example|
    previous_key = RubyLLM.config.openai_api_key
    RubyLLM.config.openai_api_key = "test-key-not-real"
    WebMock.enable!
    WebMock.disable_net_connect!
    example.run
  ensure
    WebMock.reset!
    WebMock.allow_net_connect!
    WebMock.disable!
    RubyLLM.config.openai_api_key = previous_key
    RubyLLM::Contract::CostCalculator.reset_custom_models!
  end

  def respond_with(usage: nil, status: "completed", incomplete_details: nil, text: '{"label":"refund"}')
    body = { id: "resp_1", object: "response", model: "gpt-4.1-mini", status: status,
             incomplete_details: incomplete_details,
             output: [{ type: "message", role: "assistant", content: [{ type: "output_text", text: text }] }] }
    body[:usage] = usage if usage
    stub_request(:post, %r{\Ahttps://api\.openai\.com/v1/responses\z})
      .to_return(status: 200, body: body.to_json, headers: { "Content-Type" => "application/json" })
  end

  def run_step
    step.run("refund please", context: { adapter: RubyLLM::Contract::Adapters::RubyLLM.new, model: "gpt-4.1-mini" })
  end

  # gpt-4.1-mini in RubyLLM 2.x: $0.40 input, $0.10 cache read, $1.60 output per 1M.
  # 1_000 x 0.4 + 9_000 x 0.1 + 200 x 1.6 = 1_620 per million.
  it "counts cached prompt tokens in input_tokens and prices them at the cache rate" do
    respond_with(usage: { input_tokens: 10_000, input_tokens_details: { cached_tokens: 9_000 }, output_tokens: 200 })

    trace = run_step.trace

    expect(trace.usage).to eq(input_tokens: 10_000, output_tokens: 200, cache_read_tokens: 9_000)
    expect(trace.cost).to eq(0.00162)
    expect([trace.usage_complete, trace.cost_complete, trace.cost_unknown?]).to eq([true, true, false])
  end

  it "keeps a full cache hit complete: uncached input of zero is a reported zero" do
    respond_with(usage: { input_tokens: 2_000, input_tokens_details: { cached_tokens: 2_000 }, output_tokens: 10 })

    trace = run_step.trace

    expect(trace.usage).to include(input_tokens: 2_000, cache_read_tokens: 2_000)
    expect(trace.cost_unknown?).to be(false)
  end

  it "keeps reasoning tokens as a breakdown of output, not on top of it" do
    respond_with(usage: { input_tokens: 100, output_tokens: 500, output_tokens_details: { reasoning_tokens: 400 } })

    expect(run_step.trace.usage).to eq(input_tokens: 100, output_tokens: 500, thinking_tokens: 400)
  end

  it "treats a response without usage as unknown cost, not as a free call" do
    respond_with(usage: nil)

    trace = run_step.trace

    expect(trace.usage).to eq(input_tokens: 0, output_tokens: 0)
    expect(trace.cost).to be_nil
    expect([trace.usage_complete, trace.cost_unknown?]).to eq([false, true])
  end

  it "lets a register_model price override RubyLLM's, cache reads at the input price" do
    RubyLLM::Contract::CostCalculator.register_model("gpt-4.1-mini", input_per_1m: 1.0, output_per_1m: 2.0)
    respond_with(usage: { input_tokens: 10_000, input_tokens_details: { cached_tokens: 9_000 }, output_tokens: 200 })

    # 10_000 x 1.0 + 200 x 2.0 = 10_400 per million.
    expect(run_step.trace.cost).to eq(0.0104)
  end

  it "records why the provider stopped" do
    respond_with(usage: { input_tokens: 10, output_tokens: 5 }, status: "incomplete",
                 incomplete_details: { reason: "max_output_tokens" }, text: '{"label":')

    expect(run_step.trace.finish_reason).to eq(:max_tokens)
  end

  describe "a cost the provider reported" do
    let(:chat) { instance_double("RubyLLM::Chat", ask: message).tap { |c| allow(c).to receive(:with_schema).and_return(c) } }
    let(:message) do
      RubyLLM::Message.new(role: :assistant, content: '{"label":"refund"}', model: "gpt-4.1-mini",
                           tokens: RubyLLM::Tokens.new(reported_cost: 0.5))
    end

    before { allow(RubyLLM).to receive(:chat).and_return(chat) }

    it "is the whole cost even without token counts, and wins over register_model" do
      RubyLLM::Contract::CostCalculator.register_model("gpt-4.1-mini", input_per_1m: 1.0, output_per_1m: 2.0)

      trace = run_step.trace

      expect(trace.cost).to eq(0.5)
      expect([trace.usage_complete, trace.cost_complete, trace.cost_unknown?]).to eq([false, true, false])
    end
  end
end
