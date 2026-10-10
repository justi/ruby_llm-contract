# frozen_string_literal: true

# An adapter that reports its own cost owns the figure: an explicit nil means
# "unknown", never "price it from the registry". Before 1.1.2 Trace did
# `cost || CostCalculator.calculate(...)`, so an adapter could not say unknown.
RSpec.describe "Accounting state on Response and Trace" do
  let(:trace_class) { RubyLLM::Contract::Step::Trace }
  let(:response_class) { RubyLLM::Contract::Adapters::Response }
  # Priced in RubyLLM's registry, so any re-pricing would produce a number.
  let(:priced_model) { "gpt-4.1-mini" }
  let(:tokens) { { input_tokens: 100, output_tokens: 50 } }

  describe "Step::Trace" do
    it "prices an omitted cost from the registry, as before" do
      expect(trace_class.new(model: priced_model, usage: tokens).cost).to be_a(Float)
    end

    it "keeps an explicit nil cost nil instead of re-pricing it" do
      trace = trace_class.new(model: priced_model, usage: tokens, cost: nil, cost_complete: false)

      expect(trace.cost).to be_nil
      expect(trace.cost_unknown?).to be(true)
    end

    it "does not re-price an omitted cost when the adapter already said the cost is incomplete" do
      expect(trace_class.new(model: priced_model, usage: tokens, cost_complete: false).cost).to be_nil
    end

    it "treats cost_complete: false as unknown even with zero reported tokens" do
      trace = trace_class.new(model: priced_model, usage: { input_tokens: 0, output_tokens: 0 },
                              cost: nil, cost_complete: false)

      expect(trace.cost_unknown?).to be(true)
    end

    it "treats a complete cost of 0.0 as known" do
      trace = trace_class.new(model: "no-pricing-model-xyz", usage: tokens, cost: 0.0, cost_complete: true)

      expect(trace.cost_unknown?).to be(false)
    end

    it "keeps a reported cost known when the token counts are incomplete" do
      trace = trace_class.new(model: priced_model, usage: { input_tokens: 0, output_tokens: 0 },
                              cost: 0.12, cost_complete: true, usage_complete: false)

      expect(trace.cost_unknown?).to be(false)
      expect(trace.usage_complete).to be(false)
    end

    it "never re-prices on merge, even when model and usage change" do
      trace = trace_class.new(model: priced_model, usage: tokens, cost: nil, cost_complete: false)
      merged = trace.merge(model: "gpt-4.1-nano", usage: { input_tokens: 9, output_tokens: 9 })

      expect(merged.cost).to be_nil
      expect(merged.cost_complete).to be(false)
      expect(merged.cost_unknown?).to be(true)
    end

    it "carries the accounting fields through merge" do
      trace = trace_class.new(model: priced_model, usage: tokens, cost: 0.5, cost_complete: true,
                              usage_complete: false, finish_reason: :max_tokens)
      merged = trace.merge(latency_ms: 10)

      expect(merged.to_h).to include(cost: 0.5, cost_complete: true, usage_complete: false,
                                     finish_reason: :max_tokens, latency_ms: 10)
    end

    it "survives a round trip through to_h with cost and unknown intact" do
      unknown = trace_class.new(model: priced_model, usage: tokens, cost: nil, cost_complete: false)
      known = trace_class.new(model: priced_model, usage: tokens, cost: 0.25, cost_complete: true)

      [unknown, known].each do |trace|
        copy = trace_class.new(**trace.to_h)
        expect([copy.cost, copy.cost_unknown?]).to eq([trace.cost, trace.cost_unknown?])
      end
    end

    it "keeps a given nil cost through to_h, so a copy is not priced from the registry" do
      trace = trace_class.new(model: priced_model, usage: tokens, cost: nil)

      [trace, trace.merge(latency_ms: 5)].each do |original|
        expect(original.to_h).to include(cost: nil)
        expect(trace_class.new(**original.to_h).cost).to be_nil
      end
    end

    it "serializes a trace without accounting state exactly as before" do
      expect(trace_class.new(model: priced_model, usage: tokens).to_h.keys)
        .to contain_exactly(:model, :usage, :cost)
    end

    it "exposes the new fields through [] and key?" do
      trace = trace_class.new(cost: nil, cost_complete: false, finish_reason: :stop)

      expect(trace[:cost_complete]).to be(false)
      expect(trace[:finish_reason]).to eq(:stop)
      expect(trace.key?(:usage_complete)).to be(false)
    end
  end

  describe "Adapters::Response" do
    it "omits cost from the trace fields when the adapter did not give one" do
      response = response_class.new(content: "x", usage: tokens)

      expect(response.cost_provided?).to be(false)
      expect(response.cost).to be_nil
      expect(response.trace_accounting).to eq({})
    end

    it "passes an explicit nil cost on" do
      response = response_class.new(content: "x", usage: tokens, cost: nil, cost_complete: false)

      expect(response.trace_accounting).to eq(cost: nil, cost_complete: false)
    end
  end

  describe "through Step.run" do
    let(:scripted_adapter_class) do
      Class.new(RubyLLM::Contract::Adapters::Base) do
        def initialize(responses)
          super()
          @responses = responses
        end

        def call(messages:, **_options) # rubocop:disable Lint/UnusedMethodArgument
          @responses.shift
        end
      end
    end

    let(:step) do
      Class.new(RubyLLM::Contract::Step::Base) do
        def self.name = "AccountingProbe"

        input_type String
        output_type Hash
        prompt "Classify: {input}"
        retry_policy attempts: 2
      end
    end

    def response(content, **accounting)
      response_class.new(content: content, usage: { input_tokens: 10, output_tokens: 5 }, **accounting)
    end

    def run(*responses)
      step.run("x", context: { adapter: scripted_adapter_class.new(responses), model: priced_model })
    end

    it "keeps an adapter's unknown cost unknown instead of pricing its tokens" do
      result = run(response('{"a":1}', cost: nil, cost_complete: false))

      expect(result.trace.cost).to be_nil
      expect(result.trace.cost_unknown?).to be(true)
    end

    it "uses the adapter's cost, not the registry's" do
      result = run(response('{"a":1}', cost: 0.42, cost_complete: true, usage_complete: true))

      expect(result.trace.cost).to eq(0.42)
      expect(result.trace.cost_unknown?).to be(false)
    end

    it "marks a retried step unknown when an earlier attempt was, while keeping the subtotal" do
      result = run(response("not json", cost: nil, cost_complete: false),
                   response('{"a":1}', cost: 0.01, cost_complete: true, usage_complete: true))

      expect(result.status).to eq(:ok)
      expect(result.trace.cost).to eq(0.01)
      expect(result.trace.cost_complete).to be(false)
      expect(result.trace.cost_unknown?).to be(true)
      expect(result.trace.attempts.first).to include(cost_unknown: true)
    end

    it "marks a retried step complete when every attempt was" do
      result = run(response("not json", cost: 0.02, cost_complete: true, usage_complete: false),
                   response('{"a":1}', cost: 0.01, cost_complete: true, usage_complete: true))

      expect(result.trace.cost).to eq(0.03)
      expect(result.trace.cost_complete).to be(true)
      # The last attempt reported full counts; the earlier one did not.
      expect(result.trace.usage_complete).to be(false)
      expect(result.trace.attempts.first).to include(usage_complete: false)
    end

    it "does not let the last attempt's complete cost speak for an unpriced earlier one" do
      escalating = Class.new(step) { retry_policy { escalate "no-pricing-model-xyz", "gpt-4.1-mini" } }
      adapter = scripted_adapter_class.new(
        [response_class.new(content: "not json", usage: { input_tokens: 10, output_tokens: 5 }),
         response('{"a":1}', cost: 0.01, cost_complete: true, usage_complete: true)]
      )
      result = escalating.run("x", context: { adapter: adapter })

      expect(result.trace.cost_complete).to be(false)
      expect(result.trace.cost_unknown?).to be(true)
    end

    it "sums the cache breakdown across attempts" do
      cached = { input_tokens: 100, output_tokens: 5, cache_read_tokens: 80 }
      result = run(response_class.new(content: "not json", usage: cached),
                   response_class.new(content: '{"a":1}', usage: cached))

      expect(result.trace.usage).to eq(input_tokens: 200, output_tokens: 10, cache_read_tokens: 160)
    end

    it "accepts a duck-typed adapter response with only content and usage" do
      plain = Struct.new(:content, :usage).new('{"a":1}', { input_tokens: 10, output_tokens: 5 })
      result = run(plain)

      expect(result.status).to eq(:ok)
      expect(result.trace.cost).to be_a(Float)
    end
  end
end
