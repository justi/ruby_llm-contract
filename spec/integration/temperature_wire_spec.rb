# frozen_string_literal: true

require "webmock"

# RubyLLM 1.x set temperature to 1.0 for OpenAI reasoning models; 2.x sends it
# as given. The adapter leaves it out where RubyLLM's registry says the model
# takes none (metadata temperature: false), so a step escalating from a
# sampling model to a reasoning one does not send a value the model rejects.
RSpec.describe "Temperature on models that take none (HTTP intercepted)" do
  include WebMock::API

  let(:bodies) { [] }

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
  end

  before do
    RubyLLM::Contract::Adapters::RubyLLM.instance_variable_get(:@dropped_temperature_models).clear
    stub_request(:post, %r{\Ahttps://api\.openai\.com/v1/responses\z}).to_return do |request|
      body = JSON.parse(request.body)
      bodies << body
      text = bodies.size == 1 && escalating ? "not json" : '{"label":"x"}'
      { status: 200, headers: { "Content-Type" => "application/json" },
        body: { id: "r", object: "response", model: body["model"], status: "completed",
                output: [{ type: "message", role: "assistant", content: [{ type: "output_text", text: text }] }],
                usage: { input_tokens: 5, output_tokens: 2 } }.to_json }
    end
  end

  let(:escalating) { false }
  let(:step) do
    Class.new(RubyLLM::Contract::Step::Base) do
      prompt "Classify: {input}"
      temperature 0
    end
  end

  def run(model, **context)
    step.run("x", context: { adapter: RubyLLM::Contract::Adapters::RubyLLM.new, model: model, **context })
  end

  it "sends the temperature to a model that takes one" do
    run("gpt-4.1-mini")

    expect(bodies.last["temperature"]).to eq(0)
  end

  it "leaves it out for a model the registry says takes none, warning once" do
    expect { run("gpt-5-mini") }.to output(/gpt-5-mini \(openai\) does not accept temperature/).to_stderr
    expect(bodies.last).not_to have_key("temperature")

    expect { run("gpt-5-mini") }.not_to output.to_stderr
  end

  it "sends it to a model RubyLLM does not know, as before" do
    run("ft-unknown-model", provider: :openai, assume_model_exists: true)

    expect(bodies.last["temperature"]).to eq(0)
  end

  context "when a step escalates from a sampling model to a reasoning one" do
    let(:escalating) { true }
    let(:step) do
      Class.new(RubyLLM::Contract::Step::Base) do
        prompt "Classify: {input}"
        output_type Hash
        temperature 0
        retry_policy { escalate "gpt-4.1-mini", "gpt-5-mini" }
      end
    end

    it "sends the temperature on the first attempt only" do
      result = nil
      expect { result = step.run("x", context: { adapter: RubyLLM::Contract::Adapters::RubyLLM.new }) }
        .to output(/does not accept temperature/).to_stderr

      expect(result.status).to eq(:ok)
      expect(bodies.map { |body| [body["model"], body["temperature"]] })
        .to eq([["gpt-4.1-mini", 0], ["gpt-5-mini", nil]])
    end
  end
end
