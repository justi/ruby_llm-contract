# frozen_string_literal: true

require "webmock"

# With no model from a retry chain, the context, the Step or
# RubyLLM::Contract.configure, the adapter passes model: nil and RubyLLM picks
# its own RubyLLM.config.default_model (gpt-5.6 in 2.1, gpt-6.1-sol in 2.2).
RSpec.describe "Model when none is configured (HTTP intercepted)" do
  include WebMock::API

  let(:bodies) { [] }

  around do |example|
    previous_key = RubyLLM.config.openai_api_key
    previous_model = RubyLLM.config.default_model
    RubyLLM.config.openai_api_key = "test-key-not-real"
    RubyLLM.config.default_model = "gpt-4.1-nano"
    WebMock.enable!
    WebMock.disable_net_connect!
    example.run
  ensure
    WebMock.reset!
    WebMock.allow_net_connect!
    WebMock.disable!
    RubyLLM.config.openai_api_key = previous_key
    RubyLLM.config.default_model = previous_model
  end

  after { RubyLLM::Contract.reset_configuration! }

  before do
    RubyLLM::Contract.reset_configuration!
    stub_request(:post, %r{\Ahttps://api\.openai\.com/v1/responses\z}).to_return do |request|
      body = JSON.parse(request.body)
      bodies << body
      { status: 200, headers: { "Content-Type" => "application/json" },
        body: { id: "r", object: "response", model: body["model"], status: "completed",
                output: [{ type: "message", role: "assistant", content: [{ type: "output_text", text: '{"a":1}' }] }],
                usage: { input_tokens: 5, output_tokens: 2 } }.to_json }
    end
  end

  let(:step) { Class.new(RubyLLM::Contract::Step::Base) { prompt "{input}" } }

  def run(**context)
    step.run("x", context: { adapter: RubyLLM::Contract::Adapters::RubyLLM.new, **context })
  end

  it "sends RubyLLM's own default model" do
    expect(run.status).to eq(:ok)
    expect(bodies.last["model"]).to eq("gpt-4.1-nano")
  end

  it "sends RubyLLM::Contract's default_model over it" do
    RubyLLM::Contract.configure { |c| c.default_model = "gpt-4.1-mini" }

    run

    expect(bodies.last["model"]).to eq("gpt-4.1-mini")
  end

  context "when several sources name a model" do
    before { RubyLLM::Contract.configure { |c| c.default_model = "gpt-4.1-mini" } }

    it "sends the Step's model over the default_model" do
      step.model "gpt-4.1"

      run

      expect(bodies.last["model"]).to eq("gpt-4.1")
    end

    it "sends the context's model over the Step's" do
      step.model "gpt-4.1-mini"

      run(model: "gpt-4.1")

      expect(bodies.last["model"]).to eq("gpt-4.1")
    end

    it "sends the retry chain's model over the context's" do
      step.model "gpt-4.1-mini"
      step.retry_policy models: %w[gpt-4.1]

      run(model: "gpt-4.1-mini")

      expect(bodies.last["model"]).to eq("gpt-4.1")
    end
  end

  context "with max_cost" do
    it "sends nothing, since there is no model to price" do
      step.max_cost 1.0

      expect(run.status).to eq(:limit_exceeded)
      expect(bodies).to be_empty
    end

    it "sends RubyLLM's default model under on_unknown_pricing: :warn" do
      step.max_cost 1.0, on_unknown_pricing: :warn

      expect { expect(run.status).to eq(:ok) }.to output(/no model is set/).to_stderr
      expect(bodies.last["model"]).to eq("gpt-4.1-nano")
    end
  end
end
