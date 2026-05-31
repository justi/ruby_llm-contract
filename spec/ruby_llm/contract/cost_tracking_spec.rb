# frozen_string_literal: true

RSpec.describe "Token cost tracking (GH-15)" do
  before { RubyLLM::Contract.reset_configuration! }

  describe "Step::Trace#cost" do
    it "calculates cost from model registry when available" do
      t = RubyLLM::Contract::Step::Trace.new(
        model: "gpt-4.1-mini",
        usage: { input_tokens: 1000, output_tokens: 500 }
      )
      # gpt-4.1-mini: $0.40/M input, $1.60/M output
      # 1000 * 0.4 / 1M + 500 * 1.6 / 1M = 0.0004 + 0.0008 = 0.0012
      # Anti-facade F4: assert the exact value, not just `> 0`.
      # `> 0` is satisfied by any positive constant (e.g. `0.000001`) -
      # the cost calculator could return a fabricated number and pass.
      expect(t.cost).to be_within(1e-9).of(0.0012)
    end

    it "returns nil for unknown model" do
      t = RubyLLM::Contract::Step::Trace.new(
        model: "nonexistent-model-xyz",
        usage: { input_tokens: 100, output_tokens: 50 }
      )
      expect(t.cost).to be_nil
    end

    it "returns nil when usage is nil" do
      t = RubyLLM::Contract::Step::Trace.new(model: "gpt-4.1-mini")
      expect(t.cost).to be_nil
    end

    it "includes cost in to_s" do
      t = RubyLLM::Contract::Step::Trace.new(
        model: "gpt-4.1-mini", latency_ms: 100,
        usage: { input_tokens: 1000, output_tokens: 500 }
      )
      # Anti-facade F14: `include("$")` passes for any `$X` string,
      # including `"$0.000000"`. Require the actual cost formatted with
      # 4+ significant digits, not just the dollar sign.
      expect(t.to_s).to match(/\$0\.0012/)
    end

    it "does not show cost in to_s when nil" do
      t = RubyLLM::Contract::Step::Trace.new(model: "no-model", latency_ms: 100)
      expect(t.to_s).not_to include("$")
    end
  end

  describe "Pipeline::Trace#total_cost" do
    it "sums step costs" do
      st1 = RubyLLM::Contract::Step::Trace.new(model: "gpt-4.1-mini", usage: { input_tokens: 500, output_tokens: 200 })
      st2 = RubyLLM::Contract::Step::Trace.new(model: "gpt-4.1-mini", usage: { input_tokens: 500, output_tokens: 200 })

      pt = RubyLLM::Contract::Pipeline::Trace.new(step_traces: [st1, st2])
      # Anti-facade F10: assert the absolute total, not `st1.cost + st2.cost`.
      # That comparison is circular - both sides flow through the same
      # CostCalculator, so dividing pricing by 100_000 in the SUT would
      # still make both sides equal (just both wrong). Per-step cost for
      # 500/200 tokens against gpt-4.1-mini ($0.40/M in, $1.60/M out) is
      # 500*0.4/1M + 200*1.6/1M = 0.00052; two steps -> 0.00104.
      expect(pt.total_cost).to be_within(1e-9).of(0.00104)
    end

    it "returns nil when no costs available" do
      st1 = RubyLLM::Contract::Step::Trace.new(model: "no-model", usage: { input_tokens: 0, output_tokens: 0 })
      pt = RubyLLM::Contract::Pipeline::Trace.new(step_traces: [st1])
      expect(pt.total_cost).to be_nil
    end

    it "includes cost in to_s" do
      st1 = RubyLLM::Contract::Step::Trace.new(model: "gpt-4.1-mini", usage: { input_tokens: 500, output_tokens: 200 })
      pt = RubyLLM::Contract::Pipeline::Trace.new(trace_id: "abc", step_traces: [st1])
      # Anti-facade F14: same as Step::Trace#to_s above - assert the
      # formatted number, not just the dollar sign.
      expect(pt.to_s).to match(/\$0\.000?5/)
    end
  end

  describe "max_output DSL" do
    it "forwards max_tokens to adapter" do
      received_options = nil
      spy_adapter = Class.new(RubyLLM::Contract::Adapters::Base) do
        define_method(:call) do |messages:, **options|
          received_options = options
          RubyLLM::Contract::Adapters::Response.new(content: '{"v": 1}', usage: { input_tokens: 0, output_tokens: 0 })
        end
      end.new

      step = Class.new(RubyLLM::Contract::Step::Base) do
        prompt "test {input}"
        max_output 200
      end

      step.run("hello", context: { adapter: spy_adapter })
      expect(received_options[:max_tokens]).to eq(200)
    end

    it "does not send max_tokens when not set" do
      received_options = nil
      spy_adapter = Class.new(RubyLLM::Contract::Adapters::Base) do
        define_method(:call) do |messages:, **options|
          received_options = options
          RubyLLM::Contract::Adapters::Response.new(content: '{"v": 1}', usage: { input_tokens: 0, output_tokens: 0 })
        end
      end.new

      step = Class.new(RubyLLM::Contract::Step::Base) do
        prompt "test {input}"
      end

      step.run("hello", context: { adapter: spy_adapter })
      expect(received_options).not_to have_key(:max_tokens)
    end
  end

  describe "Pipeline token_budget" do
    it "halts with :budget_exceeded when total tokens exceed limit" do
      RubyLLM::Contract::Adapters::Test.new(
        responses: [{ v: 1 }, { v: 2 }, { v: 3 }]
      )
      # Each step uses 0 tokens (Test adapter) so we override with a counting adapter
      counting_adapter = Class.new(RubyLLM::Contract::Adapters::Base) do
        define_method(:call) do |messages:, **_options|
          RubyLLM::Contract::Adapters::Response.new(
            content: '{"v": 1}',
            usage: { input_tokens: 500, output_tokens: 200 }
          )
        end
      end.new

      s1 = Class.new(RubyLLM::Contract::Step::Base) { prompt "test {input}" }
      s2 = Class.new(RubyLLM::Contract::Step::Base) do
        input_type Hash
        prompt "test {input}"
      end
      s3 = Class.new(RubyLLM::Contract::Step::Base) do
        input_type Hash
        prompt "test {input}"
      end

      pipeline = Class.new(RubyLLM::Contract::Pipeline::Base)
      pipeline.step s1, as: :first
      pipeline.step s2, as: :second
      pipeline.step s3, as: :third
      pipeline.token_budget 1000 # 700 per step, budget exceeded after step 2

      result = pipeline.run("test", context: { adapter: counting_adapter })

      expect(result.status).to eq(:budget_exceeded)
      expect(result.outputs_by_step.keys).not_to include(:third)
    end

    it "completes normally when within budget" do
      adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"v": 1}')

      s1 = Class.new(RubyLLM::Contract::Step::Base) { prompt "test {input}" }

      pipeline = Class.new(RubyLLM::Contract::Pipeline::Base)
      pipeline.step s1, as: :only
      pipeline.token_budget 100_000

      result = pipeline.run("test", context: { adapter: adapter })
      expect(result.status).to eq(:ok)
    end
  end
end
