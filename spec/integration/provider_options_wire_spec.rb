# frozen_string_literal: true

require "webmock"

# RubyLLM 2.0 removed `with_params`; `with_provider_options` is how a request
# carries settings RubyLLM has no method for (service_tier, seed, ...). Checked
# on the wire, since the point is what reaches the provider.
RSpec.describe "provider_options (HTTP intercepted)" do
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
    stub_request(:post, %r{\Ahttps://api\.openai\.com/v1/responses\z}).to_return do |request|
      bodies << JSON.parse(request.body)
      { status: 200, headers: { "Content-Type" => "application/json" },
        body: { id: "r", object: "response", model: "gpt-4.1-mini", status: "completed",
                output: [{ type: "message", role: "assistant",
                           content: [{ type: "output_text", text: '{"label":"x"}' }] }],
                usage: { input_tokens: 5, output_tokens: 2 } }.to_json }
    end
  end

  let(:step) do
    Class.new(RubyLLM::Contract::Step::Base) do
      prompt "Classify: {input}"
      provider_options service_tier: "flex", metadata: { team: "billing" }
    end
  end

  def run(klass = step, **context)
    klass.run("x", context: { adapter: RubyLLM::Contract::Adapters::RubyLLM.new, model: "gpt-4.1-mini", **context })
  end

  it "sends the class-level options in the request" do
    run

    expect(bodies.last).to include("service_tier" => "flex", "metadata" => { "team" => "billing" })
  end

  it "merges the call's options over the class's, the call winning per key" do
    run(provider_options: { service_tier: "priority", store: false })

    expect(bodies.last).to include("service_tier" => "priority", "store" => false,
                                   "metadata" => { "team" => "billing" })
  end

  it "is inherited, and :default stops the inheritance" do
    child = Class.new(step)
    reset = Class.new(step) { provider_options :default }

    run(child)
    expect(bodies.last).to include("service_tier" => "flex")
    run(reset)
    expect(bodies.last).not_to have_key("service_tier")
  end

  it "keeps its own copy of the hash" do
    options = { service_tier: "flex" }
    klass = Class.new(RubyLLM::Contract::Step::Base) { prompt "x {input}" }
    klass.provider_options(options)
    options[:service_tier] = "priority"

    expect(klass.provider_options).to eq(service_tier: "flex")
    expect(klass.provider_options).to be_frozen
  end

  it "refuses a key the step itself sets, at definition and per call" do
    expect { Class.new(RubyLLM::Contract::Step::Base) { provider_options temperature: 0.2 } }
      .to raise_error(ArgumentError, /provider_options cannot set temperature/)
    expect { run(provider_options: { max_output_tokens: 10 }) }
      .to raise_error(ArgumentError, /cannot set max_output_tokens/)
  end

  it "refuses the structured-output keys only on a step with a schema" do
    schema_step = Class.new(step) { output_schema { string :label } }

    expect { run(schema_step, provider_options: { text: { verbosity: "low" } }) }
      .to raise_error(ArgumentError, /cannot set text/)
    run(provider_options: { text: { verbosity: "low" } })
    expect(bodies.last["text"]).to include("verbosity" => "low")
  end
end
