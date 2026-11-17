# frozen_string_literal: true

require "webmock"

# A request that never gets an answer, through the real adapter. RubyLLM 2.1
# raises the Faraday error unwrapped; 2.2 wraps it in RubyLLM::ConnectionError
# (a RubyLLM::Error), so a `retry_on` naming a Faraday class stops matching
# after the upgrade. AdapterCaller rescues both, so either way it is an
# :adapter_error, not an exception out of Step.run.
RSpec.describe "Network failure (HTTP intercepted)" do
  include WebMock::API

  wraps = Gem::Version.new(RubyLLM::VERSION) >= Gem::Version.new("2.2")
  # Each failure with the Faraday error ruby_llm 2.1 raises for it.
  failures = {
    "a connection timeout" => [:to_timeout.to_proc, "Faraday::ConnectionFailed"],
    "a refused connection" => [->(stub) { stub.to_raise(Errno::ECONNREFUSED) }, "Faraday::ConnectionFailed"],
    "a read timeout" => [->(stub) { stub.to_raise(Net::ReadTimeout) }, "Faraday::TimeoutError"]
  }

  let(:models) { [] }

  around do |example|
    previous_key = RubyLLM.config.openai_api_key
    previous_retries = RubyLLM.config.max_retries
    RubyLLM.config.openai_api_key = "test-key-not-real"
    RubyLLM.config.max_retries = 0
    WebMock.enable!
    WebMock.disable_net_connect!
    example.run
  ensure
    WebMock.reset!
    WebMock.allow_net_connect!
    WebMock.disable!
    RubyLLM.config.openai_api_key = previous_key
    RubyLLM.config.max_retries = previous_retries
  end

  def ok(request)
    body = JSON.parse(request.body)
    models << body["model"]
    { status: 200, headers: { "Content-Type" => "application/json" },
      body: { id: "r", object: "response", model: body["model"], status: "completed",
              output: [{ type: "message", role: "assistant", content: [{ type: "output_text", text: '{"a":1}' }] }],
              usage: { input_tokens: 5, output_tokens: 2 } }.to_json }
  end

  def run(step)
    step.run("x", context: { adapter: RubyLLM::Contract::Adapters::RubyLLM.new, model: "gpt-4.1-mini" })
  end

  def escalating_on(error)
    Class.new(RubyLLM::Contract::Step::Base) do
      prompt "{input}"
      retry_policy do
        escalate "gpt-4.1-mini", "gpt-4.1"
        retry_on error
      end
    end
  end

  failures.each do |failure, (fail_first, faraday_error)|
    context "on #{failure}" do
      let(:connection_error) { wraps ? "RubyLLM::ConnectionError" : faraday_error }

      before do
        fail_first.call(stub_request(:post, %r{\Ahttps://api\.openai\.com/v1/responses\z}))
                  .then.to_return { |request| ok(request) }
      end

      it "ends as :adapter_error naming the error the installed ruby_llm raises" do
        result = run(Class.new(RubyLLM::Contract::Step::Base) { prompt "{input}" })

        expect(result.status).to eq(:adapter_error)
        expect(result.trace[:error_class]).to eq(connection_error)
      end

      it "escalates on it when retry_on names that error" do
        result = run(escalating_on(Object.const_get(connection_error)))

        expect(result.status).to eq(:ok)
        expect(result.trace[:attempts].map { |attempt| attempt[:model] }).to eq(%w[gpt-4.1-mini gpt-4.1])
        expect(models).to eq(["gpt-4.1"])
      end

      # `if:` leaves it out on 2.1 rather than marking it pending, which CI forbids.
      it "does not escalate on a Faraday class once ruby_llm wraps the error", if: wraps do
        result = run(escalating_on(Faraday::Error))

        expect(result.status).to eq(:adapter_error)
        expect(models).to be_empty
      end
    end
  end
end
