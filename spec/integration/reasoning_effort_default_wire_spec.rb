# frozen_string_literal: true

require "webmock"

# `reasoning_effort: :default` - the word the DSL already uses - leaves the
# class-level effort out of one call, one compare_models candidate or one
# retry-chain element, so a step set up for a reasoning model can also be run
# on one that takes no effort. Without it the class effort is sent and the
# provider's refusal stands; the gem does not guess from the model registry.
# Observed on OpenAI's Responses API with HTTP intercepted.
RSpec.describe "reasoning_effort: :default (HTTP intercepted)" do
  include WebMock::API

  let(:bodies) { [] }
  let(:replies) { [] }

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
        body: { id: "r", object: "response", model: "m", status: "completed",
                output: [{ type: "message", role: "assistant",
                           content: [{ type: "output_text", text: replies.shift || '{"name":"Alice"}' }] }],
                usage: { input_tokens: 5, output_tokens: 2 } }.to_json }
    end
  end

  let(:step) do
    Class.new(RubyLLM::Contract::Step::Base) do
      def self.name = "Summarize"

      prompt "Summarize: {input}"
      output_type Hash
      model "gpt-5-mini"
      reasoning_effort "none"
    end
  end

  let(:adapter) { RubyLLM::Contract::Adapters::RubyLLM.new }

  def sent = bodies.map { |body| [body["model"], body.dig("reasoning", "effort")] }

  def run(klass = step, **context)
    klass.run("text", context: { adapter: adapter, **context })
  end

  describe "per call" do
    it "sends the class effort to a model given in the context" do
      run(model: "gpt-4.1-mini")

      expect(sent).to eq([["gpt-4.1-mini", "none"]])
    end

    it "leaves it out with reasoning_effort: :default" do
      expect(run(model: "gpt-4.1-mini", reasoning_effort: :default).status).to eq(:ok)

      expect(sent).to eq([["gpt-4.1-mini", nil]])
      expect(bodies.last).not_to have_key("reasoning")
    end

    it "does not take nil to mean :default" do
      run(model: "gpt-4.1-mini", reasoning_effort: nil)

      expect(sent).to eq([["gpt-4.1-mini", "none"]])
    end

    it "keeps a thinking budget, as `reasoning_effort :default` in the class does" do
      seen = []
      spy = Class.new(RubyLLM::Contract::Adapters::Base) do
        define_method(:call) do |messages:, **options|
          seen << options
          RubyLLM::Contract::Adapters::Response.new(content: '{"name":"Alice"}', usage: {})
        end
      end.new
      budgeted = Class.new(step) { thinking effort: "low", budget: 2_000 }

      budgeted.run("text", context: { adapter: spy, reasoning_effort: :default })

      expect(seen.last[:thinking]).to eq(budget: 2_000)
      expect(seen.last).not_to have_key(:reasoning_effort)
    end

    it "is understood by the adapter called directly" do
      adapter.call(messages: [{ role: :user, content: "hi" }], model: "gpt-4.1-mini",
                   reasoning_effort: :default, thinking: { effort: "none" })

      expect(sent).to eq([["gpt-4.1-mini", nil]])
    end
  end

  describe "in a retry chain" do
    def chained(*configs)
      Class.new(step) { retry_policy { escalate(*configs) } }
    end

    it "sends the class effort to an element without one, and the trace says so" do
      replies << "not json"
      result = run(chained({ model: "gpt-5-mini", reasoning_effort: "none" }, { model: "gpt-4.1-mini" }))

      expect(sent).to eq([["gpt-5-mini", "none"], ["gpt-4.1-mini", "none"]])
      expect(result.trace.attempts.last[:config]).to eq(model: "gpt-4.1-mini", reasoning_effort: "none")
    end

    it "leaves the effort out for an element with :default, and the trace shows none" do
      replies << "not json"
      result = run(chained({ model: "gpt-5-mini", reasoning_effort: "none" },
                           { model: "gpt-4.1-mini", reasoning_effort: :default }))

      expect(result.status).to eq(:ok)
      expect(sent).to eq([["gpt-5-mini", "none"], ["gpt-4.1-mini", nil]])
      expect(result.trace.attempts.first[:config]).to eq(model: "gpt-5-mini", reasoning_effort: "none")
      expect(result.trace.attempts.last).not_to have_key(:config)
    end

    it "lets an element's own effort win over :default in the context" do
      replies << "not json"
      result = run(chained({ model: "gpt-4.1-mini" }, { model: "gpt-5-mini", reasoning_effort: "high" }),
                   reasoning_effort: :default)

      expect(sent).to eq([["gpt-4.1-mini", nil], ["gpt-5-mini", "high"]])
      expect(result.trace.attempts.map { |a| a[:config] })
        .to eq([nil, { model: "gpt-5-mini", reasoning_effort: "high" }])
    end

    it "keeps :default out of the trace of a same-model retry" do
      replies << "not json"
      retrying = Class.new(step) { retry_policy { attempts 2 } }
      result = run(retrying, model: "gpt-4.1-mini", reasoning_effort: :default)

      expect(sent).to eq([["gpt-4.1-mini", nil], ["gpt-4.1-mini", nil]])
      expect(result.trace.attempts).to all(satisfy { |a| !a.key?(:config) })
    end
  end

  describe "as a compare_models candidate" do
    let(:evaluated) do
      Class.new(step) do
        define_eval("smoke") { add_case "one", input: "text", expected: { name: "Alice" } }
      end
    end

    let(:no_effort_mini) { { model: "gpt-4.1-mini", reasoning_effort: :default } }

    it "runs the candidate without the class effort and labels it" do
      comparison = evaluated.compare_models("smoke", candidates: [no_effort_mini], context: { adapter: adapter })

      expect(sent).to eq([["gpt-4.1-mini", nil]])
      expect(comparison.reports.keys).to eq(["gpt-4.1-mini (effort: default)"])
    end

    it "runs each candidate alone on a Step with a retry chain, without escalating it" do
      replies << "not json"
      chained = Class.new(evaluated) { retry_policy models: %w[gpt-5-nano gpt-5-mini] }
      low_mini = { model: "gpt-5-mini", reasoning_effort: "low" }
      comparison = chained.compare_models("smoke", candidates: [no_effort_mini, low_mini],
                                                   context: { adapter: adapter })

      expect(sent).to eq([["gpt-4.1-mini", nil], ["gpt-5-mini", "low"]])
      expect(comparison.best_for(min_score: 1.0)).to eq("gpt-5-mini (effort: low)")
    end

    it "keeps a Step's same-model retries for the candidate" do
      replies << "not json"
      retrying = Class.new(evaluated) { retry_policy attempts: 2 }
      retrying.compare_models("smoke", candidates: [no_effort_mini], context: { adapter: adapter })

      expect(sent).to eq([["gpt-4.1-mini", nil], ["gpt-4.1-mini", nil]])
    end

    it "keeps the same-model retries of a Pipeline's Step" do
      replies << "not json"
      retrying = Class.new(evaluated) { retry_policy attempts: 2 }
      pipeline = Class.new(RubyLLM::Contract::Pipeline::Base) do
        def self.name = "RetryingPipeline"

        step retrying, as: :summarize
        define_eval("smoke") { add_case "one", input: "text" }
      end

      pipeline.compare_models("smoke", candidates: [no_effort_mini], context: { adapter: adapter })

      expect(sent).to eq([["gpt-4.1-mini", nil], ["gpt-4.1-mini", nil]])
    end

    it "keeps a retry policy the caller passes for the comparison" do
      replies << "not json"
      chained = Class.new(evaluated) { retry_policy models: %w[gpt-5-nano gpt-5-mini] }
      same_model_retry = RubyLLM::Contract::Step::RetryPolicy.new(attempts: 2)
      chained.compare_models("smoke", candidates: [no_effort_mini],
                                      context: { adapter: adapter, retry_policy_override: same_model_retry })

      expect(sent).to eq([["gpt-4.1-mini", nil], ["gpt-4.1-mini", nil]])
    end

    it "runs a Pipeline's chained Step on the candidate" do
      chained = Class.new(evaluated) { retry_policy models: %w[gpt-5-nano gpt-5-mini] }
      pipeline = Class.new(RubyLLM::Contract::Pipeline::Base) do
        def self.name = "SummaryPipeline"

        step chained, as: :summarize
        define_eval("smoke") { add_case "one", input: "text" }
      end

      pipeline.compare_models("smoke", candidates: [no_effort_mini], context: { adapter: adapter })

      expect(sent).to eq([["gpt-4.1-mini", nil]])
    end

    it "takes the string from JSON or an optimizer label as the same candidate" do
      from_json = { "model" => "gpt-4.1-mini", "reasoning_effort" => "default" }

      expect(RubyLLM::Contract.normalize_candidate_config(from_json)).to eq(no_effort_mini)
      expect(RubyLLM::Contract::Eval::CandidateLabel.parse("gpt-4.1-mini (effort: default)")).to eq(no_effort_mini)
    end

    it "falls back without the effort when the production_mode fallback says :default" do
      replies << "not json"
      evaluated.compare_models("smoke", candidates: [{ model: "gpt-5-mini", reasoning_effort: "high" }],
                                        context: { adapter: adapter },
                                        production_mode: { fallback: no_effort_mini })

      expect(sent).to eq([["gpt-5-mini", "high"], ["gpt-4.1-mini", nil]])
    end

    it "does not retry a candidate on a fallback that would send the same request" do
      replies << "not json"
      comparison = evaluated.compare_models("smoke", candidates: [no_effort_mini], context: { adapter: adapter },
                                                     production_mode: { fallback: "gpt-4.1-mini" })

      expect(sent).to eq([["gpt-4.1-mini", nil]])
      expect(comparison.reports.values.first.production_mode?).to be(false)
    end

    it "takes a fallback without an effort as running with the candidate's" do
      replies << "not json"
      evaluated.compare_models("smoke", candidates: [{ model: "gpt-4.1-mini", reasoning_effort: "low" }],
                                        context: { adapter: adapter }, production_mode: { fallback: "gpt-4.1-mini" })

      expect(sent).to eq([["gpt-4.1-mini", "low"]])
    end

    it "sees the class effort a candidate inherits when comparing it with the fallback" do
      replies << "not json"
      fallback = { model: "gpt-4.1-mini", reasoning_effort: "none" }
      evaluated.compare_models("smoke", candidates: ["gpt-4.1-mini"], context: { adapter: adapter },
                                        production_mode: { fallback: fallback })

      expect(sent).to eq([["gpt-4.1-mini", "none"]])
    end

    it "takes :default on the fallback as the no effort a candidate already sends" do
      replies << "not json"
      effortless = Class.new(evaluated) { reasoning_effort :default }
      effortless.compare_models("smoke", candidates: ["gpt-4.1-mini"], context: { adapter: adapter },
                                         production_mode: { fallback: no_effort_mini })

      expect(sent).to eq([["gpt-4.1-mini", nil]])
    end
  end
end
