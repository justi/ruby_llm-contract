# frozen_string_literal: true

# An adapter error carries the class of the exception behind it, and
# `retry_on` can name exception classes, so a step retries a rate limit or an
# overload without also retrying an exhausted balance or a bad request.
RSpec.describe "retry_on with exception classes" do
  let(:raising_adapter_class) do
    Class.new(RubyLLM::Contract::Adapters::Base) do
      attr_reader :calls

      def initialize(*outcomes)
        super()
        @outcomes = outcomes
        @calls = 0
      end

      def call(messages:, **_options) # rubocop:disable Lint/UnusedMethodArgument
        @calls += 1
        outcome = @outcomes.shift
        raise outcome if outcome.is_a?(Exception)

        RubyLLM::Contract::Adapters::Response.new(content: outcome, usage: { input_tokens: 1, output_tokens: 1 })
      end
    end
  end

  def step_retrying_on(*conditions)
    Class.new(RubyLLM::Contract::Step::Base) do
      prompt "Classify: {input}"
      output_type Hash
      retry_policy do
        attempts 2
        retry_on(*conditions)
      end
    end
  end

  def run(step, adapter)
    step.run("x", context: { adapter: adapter, model: "gpt-4.1-mini" })
  end

  it "names the exception class in the trace of an adapter error" do
    adapter = raising_adapter_class.new(RubyLLM::PaymentRequiredError.new("no credit"))
    result = run(step_retrying_on(:validation_failed), adapter)

    expect(result.status).to eq(:adapter_error)
    expect(result.trace[:error_class]).to eq("RubyLLM::PaymentRequiredError")
    expect(result.trace.to_h).to include(error_class: "RubyLLM::PaymentRequiredError")
  end

  it "retries an adapter error of a listed class" do
    adapter = raising_adapter_class.new(RubyLLM::RateLimitError.new("slow down"), '{"a":1}')
    result = run(step_retrying_on(:validation_failed, RubyLLM::RateLimitError), adapter)

    expect(result.status).to eq(:ok)
    expect(adapter.calls).to eq(2)
    expect(result.trace.attempts.first).to include(status: :adapter_error, error_class: "RubyLLM::RateLimitError")
  end

  it "does not retry an adapter error of another class" do
    adapter = raising_adapter_class.new(RubyLLM::PaymentRequiredError.new("no credit"), '{"a":1}')
    result = run(step_retrying_on(:validation_failed, RubyLLM::RateLimitError), adapter)

    expect(result.status).to eq(:adapter_error)
    expect(adapter.calls).to eq(1)
  end

  it "matches subclasses of a listed class" do
    adapter = raising_adapter_class.new(RubyLLM::RateLimitError.new("slow down"), '{"a":1}')

    expect(run(step_retrying_on(RubyLLM::Error), adapter).status).to eq(:ok)
  end

  it "keeps :adapter_error retrying every adapter error" do
    adapter = raising_adapter_class.new(RubyLLM::PaymentRequiredError.new("no credit"), '{"a":1}')

    expect(run(step_retrying_on(:adapter_error, RubyLLM::RateLimitError), adapter).status).to eq(:ok)
  end

  it "replaces the default statuses, as a status list does" do
    adapter = raising_adapter_class.new("not json", '{"a":1}')

    expect(run(step_retrying_on(RubyLLM::RateLimitError), adapter).status).to eq(:parse_error)
    expect(adapter.calls).to eq(1)
  end

  it "takes classes through the keyword form too" do
    step = Class.new(RubyLLM::Contract::Step::Base) do
      prompt "Classify: {input}"
      output_type Hash
      retry_policy attempts: 2, retry_on: [RubyLLM::RateLimitError]
    end
    adapter = raising_adapter_class.new(RubyLLM::RateLimitError.new("slow down"), '{"a":1}')

    expect(run(step, adapter).status).to eq(:ok)
  end

  it "refuses a class that is not an exception" do
    expect { step_retrying_on(String) }.to raise_error(ArgumentError, /exception classes, got String/)
  end

  it "does not match a trace rebuilt from a hash, which keeps only the class name" do
    trace = RubyLLM::Contract::Step::Trace.new(error_class: "RubyLLM::RateLimitError",
                                               error_type: RubyLLM::RateLimitError)
    rebuilt = RubyLLM::Contract::Step::Result.new(status: :adapter_error, raw_output: nil, parsed_output: nil,
                                                  trace: trace.to_h)
    policy = RubyLLM::Contract::Step::RetryPolicy.new(attempts: 2, retry_on: [RubyLLM::RateLimitError])

    expect(rebuilt.trace.error_class).to eq("RubyLLM::RateLimitError")
    expect(policy.retryable?(rebuilt)).to be(false)
    expect(trace.merge.error_type).to eq(RubyLLM::RateLimitError)
  end
end
