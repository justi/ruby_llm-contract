# frozen_string_literal: true

RSpec.describe "Pretty print (to_s)" do
  before { RubyLLM::Contract.reset_configuration! }

  describe "Step::Trace#to_s" do
    it "shows model, latency, tokens, cost" do
      t = RubyLLM::Contract::Step::Trace.new(model: "gpt-4.1-mini", latency_ms: 234, usage: { input_tokens: 120, output_tokens: 60 })
      expect(t.to_s).to include("gpt-4.1-mini")
      expect(t.to_s).to include("234ms")
      expect(t.to_s).to include("120+60 tokens")
      expect(t.to_s).to include("$") if t.cost
    end

    it "handles nil usage" do
      t = RubyLLM::Contract::Step::Trace.new(model: "gpt-4.1", latency_ms: 100)
      expect(t.to_s).to eq("gpt-4.1 100ms")
    end

    it "handles nil model" do
      t = RubyLLM::Contract::Step::Trace.new(latency_ms: 50, usage: { input_tokens: 10, output_tokens: 5 })
      expect(t.to_s).to eq("no-model 50ms 10+5 tokens")
    end
  end

  describe "Step::Result#to_s" do
    it "shows status and trace on success" do
      trace = RubyLLM::Contract::Step::Trace.new(model: "gpt-4.1-mini", latency_ms: 100, usage: { input_tokens: 50, output_tokens: 25 })
      r = RubyLLM::Contract::Step::Result.new(status: :ok, raw_output: "{}", parsed_output: {}, trace: trace)
      expect(r.to_s).to include("ok")
      expect(r.to_s).to include("gpt-4.1-mini")
      expect(r.to_s).to include("100ms")
    end

    it "shows status and errors on failure" do
      r = RubyLLM::Contract::Step::Result.new(status: :validation_failed, raw_output: "{}", parsed_output: {},
                                           validation_errors: ["locale is invalid", "description too short"])
      expect(r.to_s).to eq("validation_failed: locale is invalid, description too short")
    end

    it "truncates errors to 3" do
      r = RubyLLM::Contract::Step::Result.new(status: :validation_failed, raw_output: "{}", parsed_output: {},
                                           validation_errors: ["a", "b", "c", "d"])
      expect(r.to_s).to include("a, b, c, ...")
    end
  end

  describe "Pipeline::Trace#to_s" do
    it "shows trace_id, latency, tokens, step count" do
      t = RubyLLM::Contract::Pipeline::Trace.new(
        trace_id: "abc12345-long-uuid", total_latency_ms: 1234,
        total_usage: { input_tokens: 600, output_tokens: 300 },
        step_traces: [1, 2, 3]
      )
      expect(t.to_s).to eq("trace=abc12345 1234ms 600+300 tokens (3 steps)")
    end
  end

  describe "Pipeline::Result#to_s" do
    let(:step_trace) { RubyLLM::Contract::Step::Trace.new(model: "gpt-4", latency_ms: 50, usage: { input_tokens: 100, output_tokens: 50 }) }
    let(:step_result) { RubyLLM::Contract::Step::Result.new(status: :ok, raw_output: "{}", parsed_output: { v: 1 }, trace: step_trace) }

    it "renders header + step lines" do
      r = RubyLLM::Contract::Pipeline::Result.new(
        status: :ok,
        step_results: [{ alias: :analyze, result: step_result }],
        outputs_by_step: { analyze: { v: 1 } },
        trace: RubyLLM::Contract::Pipeline::Trace.new(
          trace_id: "abc12345", total_latency_ms: 50,
          total_usage: { input_tokens: 100, output_tokens: 50 },
          step_traces: [step_trace]
        )
      )

      str = r.to_s
      expect(str).to include("Pipeline: ok")
      expect(str).to include("analyze")
    end
  end

  describe "Pipeline::Result#pretty_print" do
    let(:adapter) { RubyLLM::Contract::Adapters::Test.new(response: '{"v": 1}') }

    it "renders an ASCII table to IO" do
      s1 = Class.new(RubyLLM::Contract::Step::Base) do
        input_type RubyLLM::Contract::Types::String
        output_type RubyLLM::Contract::Types::Hash
        prompt { user "{input}" }
        contract { parse :json }
      end

      pipeline = Class.new(RubyLLM::Contract::Pipeline::Base)
      pipeline.step s1, as: :only

      result = pipeline.run("test", context: { adapter: adapter })

      output = StringIO.new
      result.pretty_print(output)
      table = output.string

      expect(table).to include("+")
      expect(table).to include("Pipeline: ok")
      expect(table).to include("Step")
      expect(table).to include("Output")
      expect(table).to include("only")
      expect(table).to include("v: 1")
    end
  end

  describe "Eval::Report#to_s" do
    it "returns summary" do
      r = RubyLLM::Contract::Eval::Report.new(dataset_name: "test", results: [{ score: 1.0, passed: true }])
      expect(r.to_s).to eq("test: 1/1 checks passed")
    end
  end

  describe "Eval::EvaluationResult#to_s" do
    it "shows label and score" do
      r = RubyLLM::Contract::Eval::EvaluationResult.new(score: 1.0, passed: true, details: "exact match")
      expect(r.to_s).to eq("PASS (score: 1.0 — exact match)")
    end

    it "shows FAIL" do
      r = RubyLLM::Contract::Eval::EvaluationResult.new(score: 0.0, passed: false, details: "mismatch")
      expect(r.to_s).to eq("FAIL (score: 0.0 — mismatch)")
    end
  end
end
