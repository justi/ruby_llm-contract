# frozen_string_literal: true

require "tmpdir"
require "webmock"
require "webmock/rspec/matchers"

# `token_count :exact` measures the input for max_input / max_cost with the
# provider's counting endpoint instead of the chars/4 heuristic. Exercised on
# OpenAI's Responses API with HTTP intercepted: what is counted, what a count
# over the limit does, and what happens when no count can be had.
RSpec.describe "token_count :exact (HTTP intercepted)" do
  include WebMock::API
  include WebMock::Matchers

  let(:count_bodies) { [] }
  let(:counted) { 120 }
  let(:count_url) { %r{\Ahttps://api\.openai\.com/v1/responses/input_tokens\z} }
  let(:completion_url) { %r{\Ahttps://api\.openai\.com/v1/responses\z} }

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
    stub_request(:post, count_url).to_return do |request|
      count_bodies << JSON.parse(request.body)
      { status: 200, headers: { "Content-Type" => "application/json" },
        body: { object: "response.input_tokens", input_tokens: counted }.to_json }
    end
    stub_request(:post, completion_url).to_return(
      status: 200, headers: { "Content-Type" => "application/json" },
      body: { id: "r", object: "response", model: "gpt-4.1-mini", status: "completed",
              output: [{ type: "message", role: "assistant",
                         content: [{ type: "output_text", text: '{"label":"x"}' }] }],
              usage: { input_tokens: 120, output_tokens: 3 } }.to_json
    )
  end

  let(:step) do
    Class.new(RubyLLM::Contract::Step::Base) do
      prompt "Classify: {input}"
      token_count :exact
      max_input 500
    end
  end

  def run(klass = step, **context)
    klass.run("refund please", context: { adapter: RubyLLM::Contract::Adapters::RubyLLM.new,
                                          model: "gpt-4.1-mini", **context })
  end

  it "asks the provider for the count, then sends the call" do
    result = run

    expect(result.status).to eq(:ok)
    expect(count_bodies.last["input"].to_s).to include("Classify: refund please")
    expect(a_request(:post, completion_url)).to have_been_made.once
  end

  context "when the count is over max_input" do
    let(:counted) { 900 }

    it "refuses before sending, naming the provider's count" do
      result = run

      expect(result.status).to eq(:limit_exceeded)
      expect(result.validation_errors)
        .to eq(["Input token limit exceeded: 900 tokens (counted by the provider), max 500"])
      expect(result.trace.usage).to include(estimated_input_tokens: 900, estimate_method: :exact)
      expect(a_request(:post, completion_url)).not_to have_been_made
    end
  end

  it "counts an attachment without attachment_token_estimate" do
    png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="
    priced = Class.new(step) { max_cost 1.0 }

    result = Dir.mktmpdir do |dir|
      path = File.join(dir, "pixel.png")
      File.binwrite(path, png.unpack1("m0"))
      run(priced, attachment: path)
    end

    expect(result.status).to eq(:ok)
    expect(count_bodies.last.to_s).to include("input_image")
  end

  it "refuses when the provider cannot count, instead of estimating" do
    stub_request(:post, count_url).to_return(status: 400, body: { error: { message: "nope" } }.to_json,
                                             headers: { "Content-Type" => "application/json" })

    result = run

    expect(result.status).to eq(:limit_exceeded)
    expect(result.validation_errors.first).to start_with("token_count :exact: the provider could not count")
    expect(result.trace.usage).to eq(input_tokens: 0, output_tokens: 0, estimate_method: :exact)
    expect(a_request(:post, completion_url)).not_to have_been_made
  end

  it "refuses with an adapter that cannot count" do
    plain = Class.new(RubyLLM::Contract::Adapters::Base) do
      def call(messages:, **_options) # rubocop:disable Lint/UnusedMethodArgument
        RubyLLM::Contract::Adapters::Response.new(content: "{}", usage: {})
      end
    end.new

    result = step.run("x", context: { adapter: plain, model: "gpt-4.1-mini" })

    expect(result.validation_errors).to eq(["token_count :exact needs an adapter that counts tokens; " \
                                            "#{plain.class} does not"])
  end

  it "uses the heuristic under the Test adapter, which has no provider to ask" do
    adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"label":"x"}')

    expect(step.run("refund please", context: { adapter: adapter, model: "gpt-4.1-mini" }).status).to eq(:ok)
  end

  it "sends no count request without max_input or max_cost" do
    unlimited = Class.new(RubyLLM::Contract::Step::Base) do
      prompt "Classify: {input}"
      token_count :exact
    end

    run(unlimited)

    expect(a_request(:post, count_url)).not_to have_been_made
  end

  it "is inherited and checked" do
    expect(Class.new(step).token_count).to eq(:exact)
    expect { Class.new(RubyLLM::Contract::Step::Base) { token_count :precise } }
      .to raise_error(ArgumentError, /token_count must be one of \[:estimate, :exact\]/)
  end
end
