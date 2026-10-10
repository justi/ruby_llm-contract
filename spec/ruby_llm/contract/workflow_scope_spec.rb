# frozen_string_literal: true

require "webmock"

# With workflow_instrumentation on, steps and pipelines run inside
# RubyLLM.workflow, so RubyLLM's events (and the OpenTelemetry spans built
# from them) carry the step's name. Observed through RubyLLM's instrumenter.
RSpec.describe RubyLLM::Contract::WorkflowScope do
  let(:events) { [] }
  let(:recorder) do
    log = events
    Object.new.tap do |instrumenter|
      instrumenter.define_singleton_method(:instrument) do |name, payload, &block|
        log << [name, payload.slice(:workflow_name, :workflow_step_name, :workflow_parent_id)]
        block&.call(payload)
      end
    end
  end
  let(:adapter) { RubyLLM::Contract::Adapters::Test.new(response: '{"label":"x"}') }

  let(:classify) do
    Class.new(RubyLLM::Contract::Step::Base) do
      def self.name = "ClassifyTicket"

      prompt "Classify: {input}"
      output_type Hash
    end
  end
  let(:route) do
    Class.new(RubyLLM::Contract::Step::Base) do
      def self.name = "RouteTicket"

      input_type Hash
      prompt "Route: {input}"
      output_type Hash
    end
  end
  let(:pipeline) do
    first = classify
    second = route
    Class.new(RubyLLM::Contract::Pipeline::Base) do
      def self.name = "TicketPipeline"

      step first, as: :classify
      step second, as: :route
    end
  end

  around do |example|
    previous = RubyLLM.config.instrumenter
    RubyLLM.config.instrumenter = recorder
    example.run
  ensure
    RubyLLM.config.instrumenter = previous
    RubyLLM::Contract.reset_configuration!
  end

  def enable = RubyLLM::Contract.configure { |c| c.workflow_instrumentation = true }

  it "is off by default" do
    classify.run("x", context: { adapter: adapter })

    expect(events).to be_empty
  end

  it "runs a step in a workflow named after it" do
    enable
    result = classify.run("x", context: { adapter: adapter })

    expect(result.status).to eq(:ok)
    expect(events).to eq([["workflow.ruby_llm", { workflow_name: "ClassifyTicket" }]])
  end

  it "runs a pipeline as one workflow with a step per alias, and no workflow per step" do
    enable
    pipeline.run("x", context: { adapter: adapter })

    expect(events.map(&:first)).to eq(%w[workflow.ruby_llm workflow_step.ruby_llm workflow_step.ruby_llm])
    expect(events.drop(1).map { |_, payload| payload[:workflow_step_name] }).to eq(%w[classify route])
    expect(events.map { |_, payload| payload[:workflow_name] }.uniq).to eq(["TicketPipeline"])
  end

  it "nests under a workflow the application opened" do
    enable
    RubyLLM.workflow("Support inbox") { classify.run("x", context: { adapter: adapter }) }

    inner = events.find { |_, payload| payload[:workflow_name] == "ClassifyTicket" }
    expect(inner.last[:workflow_parent_id]).not_to be_nil
  end

  it "leaves no scope behind when a step raises" do
    enable
    failing = Class.new(classify) do
      around_call { |_input, _result| raise "boom" }
    end

    expect { failing.run("x", context: { adapter: adapter }) }.to raise_error("boom")
    expect(described_class.current).to be_nil
  end

  describe "with a real RubyLLM call (HTTP intercepted)" do
    include WebMock::API

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

    it "tags the chat event with the pipeline and step" do
      stub_request(:post, %r{\Ahttps://api\.openai\.com/v1/responses\z}).to_return(
        status: 200, headers: { "Content-Type" => "application/json" },
        body: { id: "r", object: "response", model: "gpt-4.1-mini", status: "completed",
                output: [{ type: "message", role: "assistant",
                           content: [{ type: "output_text", text: '{"label":"x"}' }] }],
                usage: { input_tokens: 5, output_tokens: 2 } }.to_json
      )
      enable

      pipeline.run("x", context: { adapter: RubyLLM::Contract::Adapters::RubyLLM.new, model: "gpt-4.1-mini" })

      chat_events = events.select { |name, _| name.start_with?("chat") }
      expect(chat_events).not_to be_empty
      expect(chat_events.map { |_, payload| payload[:workflow_step_name] }.uniq).to eq(%w[classify route])
    end
  end
end
