# frozen_string_literal: true

RSpec.describe RubyLLM::Contract::Pipeline::Trace do
  let(:step_trace) { RubyLLM::Contract::Step::Trace.new(model: "gpt-test", latency_ms: 100, usage: { input_tokens: 50, output_tokens: 25 }) }

  let(:trace) do
    described_class.new(
      trace_id: "abc-123",
      total_latency_ms: 500,
      total_usage: { input_tokens: 200, output_tokens: 100 },
      step_traces: [step_trace]
    )
  end

  describe "named accessors" do
    it "exposes trace_id" do
      expect(trace.trace_id).to eq("abc-123")
    end

    it "exposes total_latency_ms" do
      expect(trace.total_latency_ms).to eq(500)
    end

    it "exposes total_usage" do
      expect(trace.total_usage).to eq({ input_tokens: 200, output_tokens: 100 })
    end

    it "exposes step_traces" do
      expect(trace.step_traces).to eq([step_trace])
    end
  end

  describe "#[]" do
    it "supports hash-style access" do
      expect(trace[:trace_id]).to eq("abc-123")
      expect(trace[:total_latency_ms]).to eq(500)
    end

    it "returns nil for unknown keys" do
      expect(trace[:nonexistent]).to be_nil
    end
  end

  describe "immutability" do
    it "is frozen after construction" do
      expect(trace).to be_frozen
    end
  end

  describe "#to_h" do
    it "returns a hash representation" do
      h = trace.to_h
      expect(h[:trace_id]).to eq("abc-123")
      expect(h[:total_latency_ms]).to eq(500)
      expect(h[:total_usage]).to eq({ input_tokens: 200, output_tokens: 100 })
      expect(h[:step_traces]).to eq([step_trace])
    end

    it "omits nil values" do
      empty = described_class.new
      expect(empty.to_h).to eq({})
    end
  end

  describe "#==" do
    it "equals another Trace with same values" do
      other = described_class.new(
        trace_id: "abc-123",
        total_latency_ms: 500,
        total_usage: { input_tokens: 200, output_tokens: 100 },
        step_traces: [step_trace]
      )
      expect(trace).to eq(other)
    end

    it "equals a hash with same values" do
      expect(trace).to eq(trace.to_h)
    end
  end

  describe "defaults" do
    it "defaults all fields to nil" do
      empty = described_class.new
      expect(empty.trace_id).to be_nil
      expect(empty.total_latency_ms).to be_nil
      expect(empty.total_usage).to be_nil
      expect(empty.step_traces).to be_nil
    end
  end
end
