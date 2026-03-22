# frozen_string_literal: true

RSpec.describe RubyLLM::Contract::Pipeline::Base do
  before { RubyLLM::Contract.reset_configuration! }

  # Define test steps as anonymous classes
  let(:step_upper) do
    Class.new(RubyLLM::Contract::Step::Base) do
      input_type RubyLLM::Contract::Types::String
      output_type RubyLLM::Contract::Types::String
      prompt { user "{input}" }
      contract { parse :text }
    end
  end

  let(:step_wrap) do
    Class.new(RubyLLM::Contract::Step::Base) do
      input_type RubyLLM::Contract::Types::String
      output_type RubyLLM::Contract::Types::Hash
      prompt { user "{input}" }
      contract { parse :json }
    end
  end

  let(:step_from_hash) do
    Class.new(RubyLLM::Contract::Step::Base) do
      input_type RubyLLM::Contract::Types::Hash
      output_type RubyLLM::Contract::Types::Hash
      prompt { user "{input}" }
      contract { parse :json }
    end
  end

  describe "token_budget" do
    it "stores and retrieves the token budget" do
      pipeline = Class.new(described_class)
      pipeline.token_budget 5000
      expect(pipeline.token_budget).to eq(5000)
    end

    it "returns nil when not set" do
      pipeline = Class.new(described_class)
      expect(pipeline.token_budget).to be_nil
    end
  end

  describe "define_eval duplicate name" do
    it "replaces eval with same name (supports reload)" do
      pipeline = Class.new(described_class)

      pipeline.define_eval("smoke") do
        default_input "test"
      end

      pipeline.define_eval("smoke") do
        default_input "test again"
      end

      expect(pipeline.eval_names).to eq(["smoke"])
    end
  end

  describe "step registration" do
    it "registers steps in declaration order" do
      pipeline = Class.new(described_class) do
        step Class.new(RubyLLM::Contract::Step::Base), as: :first
        step Class.new(RubyLLM::Contract::Step::Base), as: :second
        step Class.new(RubyLLM::Contract::Step::Base), as: :third
      end

      expect(pipeline.steps.map { |s| s[:alias] }).to eq(%i[first second third])
    end

    it "raises ArgumentError for invalid depends_on" do
      expect do
        Class.new(described_class) do
          step Class.new(RubyLLM::Contract::Step::Base), as: :first
          step Class.new(RubyLLM::Contract::Step::Base), as: :second, depends_on: :nonexistent
        end
      end.to raise_error(ArgumentError, /Unknown dependency: :nonexistent/)
    end

    it "accepts valid depends_on" do
      expect do
        Class.new(described_class) do
          step Class.new(RubyLLM::Contract::Step::Base), as: :first
          step Class.new(RubyLLM::Contract::Step::Base), as: :second, depends_on: :first
        end
      end.not_to raise_error
    end
  end

  describe ".run" do
    it "executes steps in order threading output to next input" do
      adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"text": "HELLO"}')

      # We need steps that actually work with the adapters
      s1 = step_upper
      s2 = step_wrap

      pipeline = Class.new(described_class)
      pipeline.step s1, as: :upper
      pipeline.step s2, as: :wrap

      result = pipeline.run("hello", context: { adapter: adapter })

      expect(result.ok?).to be true
      expect(result.outputs_by_step[:upper]).to eq('{"text": "HELLO"}')
    end

    it "returns :ok with all outputs on success" do
      adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"value": "done"}')

      s1 = Class.new(RubyLLM::Contract::Step::Base) do
        input_type RubyLLM::Contract::Types::String
        output_type RubyLLM::Contract::Types::Hash
        prompt { user "{input}" }
        contract { parse :json }
      end

      s2 = Class.new(RubyLLM::Contract::Step::Base) do
        input_type RubyLLM::Contract::Types::Hash
        output_type RubyLLM::Contract::Types::Hash
        prompt { user "{input}" }
        contract { parse :json }
      end

      pipeline = Class.new(described_class)
      pipeline.step s1, as: :first
      pipeline.step s2, as: :second

      result = pipeline.run("start", context: { adapter: adapter })

      expect(result.status).to eq(:ok)
      expect(result.ok?).to be true
      expect(result.failed?).to be false
      expect(result.failed_step).to be_nil
      expect(result.outputs_by_step.keys).to eq(%i[first second])
      expect(result.step_results.length).to eq(2)
      expect(result.step_results.map { |s| s[:alias] }).to eq(%i[first second])
    end

    it "halts on first failure and reports failed_step" do
      good_adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"value": "ok"}')

      s1 = Class.new(RubyLLM::Contract::Step::Base) do
        input_type RubyLLM::Contract::Types::String
        output_type RubyLLM::Contract::Types::Hash
        prompt { user "{input}" }
        contract { parse :json }
      end

      s2 = Class.new(RubyLLM::Contract::Step::Base) do
        input_type RubyLLM::Contract::Types::Hash
        output_type RubyLLM::Contract::Types::Hash
        prompt { user "{input}" }
        contract { parse :json }
      end

      s3 = Class.new(RubyLLM::Contract::Step::Base) do
        input_type RubyLLM::Contract::Types::Hash
        output_type RubyLLM::Contract::Types::Hash
        prompt { user "{input}" }
        contract { parse :json }
      end

      pipeline = Class.new(described_class)
      pipeline.step s1, as: :first
      pipeline.step s2, as: :second
      pipeline.step s3, as: :third

      # Step 1 succeeds (good adapter), step 2 uses same adapter but input is Hash
      # Let's make step 2 fail by using bad adapter for all
      # Actually, we need step 1 to succeed and step 2 to fail.
      # Simplest: make step 2 have an invariant that fails.

      s2_failing = Class.new(RubyLLM::Contract::Step::Base) do
        input_type RubyLLM::Contract::Types::Hash
        output_type RubyLLM::Contract::Types::Hash
        prompt { user "{input}" }
        contract do
          parse :json
          invariant("always fails") { |_o| false }
        end
      end

      pipeline2 = Class.new(described_class)
      pipeline2.step s1, as: :first
      pipeline2.step s2_failing, as: :second
      pipeline2.step s3, as: :third

      result = pipeline2.run("test", context: { adapter: good_adapter })

      expect(result.status).to eq(:validation_failed)
      expect(result.failed?).to be true
      expect(result.failed_step).to eq(:second)
      expect(result.outputs_by_step.keys).to eq([:first])
      expect(result.step_results.length).to eq(2) # first + second (failed)
      expect(result.step_results.map { |s| s[:alias] }).to eq(%i[first second])
    end

    it "forwards context to all steps" do
      adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"v": 1}')

      s1 = Class.new(RubyLLM::Contract::Step::Base) do
        input_type RubyLLM::Contract::Types::String
        output_type RubyLLM::Contract::Types::Hash
        prompt { user "{input}" }
        contract { parse :json }
      end

      pipeline = Class.new(described_class)
      pipeline.step s1, as: :only

      result = pipeline.run("test", context: { adapter: adapter, model: "gpt-test" })

      step_result = result.step_results.first[:result]
      expect(step_result.trace[:model]).to eq("gpt-test")
    end

    it "handles input validation failure in first step" do
      adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"v": 1}')

      s1 = Class.new(RubyLLM::Contract::Step::Base) do
        input_type RubyLLM::Contract::Types::String
        output_type RubyLLM::Contract::Types::Hash
        prompt { user "{input}" }
        contract { parse :json }
      end

      pipeline = Class.new(described_class)
      pipeline.step s1, as: :first

      result = pipeline.run(42, context: { adapter: adapter })

      expect(result.status).to eq(:input_error)
      expect(result.failed_step).to eq(:first)
    end
  end

  describe "pipeline trace" do
    it "populates trace on successful pipeline" do
      adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"v": 1}')

      s1 = Class.new(RubyLLM::Contract::Step::Base) do
        input_type RubyLLM::Contract::Types::String
        output_type RubyLLM::Contract::Types::Hash
        prompt { user "{input}" }
        contract { parse :json }
      end

      pipeline = Class.new(described_class)
      pipeline.step s1, as: :only

      result = pipeline.run("test", context: { adapter: adapter })

      expect(result.trace).to be_a(RubyLLM::Contract::Pipeline::Trace)
      expect(result.trace.trace_id).to be_a(String)
      expect(result.trace.trace_id).not_to be_empty
      expect(result.trace.total_latency_ms).to be_a(Numeric)
      expect(result.trace.total_latency_ms).to be >= 0
      expect(result.trace.total_usage).to be_a(Hash)
      expect(result.trace.total_usage).to have_key(:input_tokens)
      expect(result.trace.total_usage).to have_key(:output_tokens)
      expect(result.trace.step_traces).to be_a(Array)
      expect(result.trace.step_traces.length).to eq(1)
    end

    it "populates trace on failed pipeline" do
      adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"v": 1}')

      s1 = Class.new(RubyLLM::Contract::Step::Base) do
        input_type RubyLLM::Contract::Types::String
        output_type RubyLLM::Contract::Types::Hash
        prompt { user "{input}" }
        contract { parse :json }
      end

      s2_failing = Class.new(RubyLLM::Contract::Step::Base) do
        input_type RubyLLM::Contract::Types::Hash
        output_type RubyLLM::Contract::Types::Hash
        prompt { user "{input}" }
        contract do
          parse :json
          invariant("always fails") { |_o| false }
        end
      end

      pipeline = Class.new(described_class)
      pipeline.step s1, as: :first
      pipeline.step s2_failing, as: :second

      result = pipeline.run("test", context: { adapter: adapter })

      expect(result.trace).to be_a(RubyLLM::Contract::Pipeline::Trace)
      expect(result.trace.step_traces.length).to eq(2)
      expect(result.trace.trace_id).not_to be_empty
    end

    it "generates unique trace_id per run" do
      adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"v": 1}')

      s1 = Class.new(RubyLLM::Contract::Step::Base) do
        input_type RubyLLM::Contract::Types::String
        output_type RubyLLM::Contract::Types::Hash
        prompt { user "{input}" }
        contract { parse :json }
      end

      pipeline = Class.new(described_class)
      pipeline.step s1, as: :only

      r1 = pipeline.run("a", context: { adapter: adapter })
      r2 = pipeline.run("b", context: { adapter: adapter })

      expect(r1.trace.trace_id).not_to eq(r2.trace.trace_id)
    end

    it "supports hash-style trace access" do
      adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"v": 1}')

      s1 = Class.new(RubyLLM::Contract::Step::Base) do
        input_type RubyLLM::Contract::Types::String
        output_type RubyLLM::Contract::Types::Hash
        prompt { user "{input}" }
        contract { parse :json }
      end

      pipeline = Class.new(described_class)
      pipeline.step s1, as: :only

      result = pipeline.run("test", context: { adapter: adapter })

      expect(result.trace[:trace_id]).to eq(result.trace.trace_id)
      expect(result.trace[:total_latency_ms]).to eq(result.trace.total_latency_ms)
    end
  end

  describe "timeout" do
    it "returns :timeout when elapsed exceeds timeout_ms" do
      # Use a slow adapter that sleeps
      slow_adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"v": 1}')
      allow(slow_adapter).to receive(:call).and_wrap_original do |m, **args|
        sleep(0.05) # 50ms per step
        m.call(**args)
      end

      s1 = Class.new(RubyLLM::Contract::Step::Base) do
        input_type RubyLLM::Contract::Types::String
        output_type RubyLLM::Contract::Types::Hash
        prompt { user "{input}" }
        contract { parse :json }
      end

      s2 = Class.new(RubyLLM::Contract::Step::Base) do
        input_type RubyLLM::Contract::Types::Hash
        output_type RubyLLM::Contract::Types::Hash
        prompt { user "{input}" }
        contract { parse :json }
      end

      s3 = Class.new(RubyLLM::Contract::Step::Base) do
        input_type RubyLLM::Contract::Types::Hash
        output_type RubyLLM::Contract::Types::Hash
        prompt { user "{input}" }
        contract { parse :json }
      end

      pipeline = Class.new(described_class)
      pipeline.step s1, as: :first
      pipeline.step s2, as: :second
      pipeline.step s3, as: :third

      # 50ms per step, timeout at 80ms → should timeout after step 2
      result = pipeline.run("test", context: { adapter: slow_adapter }, timeout_ms: 80)

      expect(result.status).to eq(:timeout)
      expect(result.failed?).to be true
      expect(result.trace).to be_a(RubyLLM::Contract::Pipeline::Trace)
      expect(result.outputs_by_step.keys).not_to include(:third)
    end

    it "completes normally when under timeout" do
      adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"v": 1}')

      s1 = Class.new(RubyLLM::Contract::Step::Base) do
        input_type RubyLLM::Contract::Types::String
        output_type RubyLLM::Contract::Types::Hash
        prompt { user "{input}" }
        contract { parse :json }
      end

      pipeline = Class.new(described_class)
      pipeline.step s1, as: :only

      result = pipeline.run("test", context: { adapter: adapter }, timeout_ms: 10_000)

      expect(result.status).to eq(:ok)
      expect(result.trace.trace_id).not_to be_empty
    end

    it "works identically without timeout_ms except trace is present" do
      adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"v": 1}')

      s1 = Class.new(RubyLLM::Contract::Step::Base) do
        input_type RubyLLM::Contract::Types::String
        output_type RubyLLM::Contract::Types::Hash
        prompt { user "{input}" }
        contract { parse :json }
      end

      pipeline = Class.new(described_class)
      pipeline.step s1, as: :only

      result = pipeline.run("test", context: { adapter: adapter })

      expect(result.status).to eq(:ok)
      expect(result.trace).to be_a(RubyLLM::Contract::Pipeline::Trace)
    end

    it "raises ArgumentError when timeout_ms is negative" do
      adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"v": 1}')

      s1 = Class.new(RubyLLM::Contract::Step::Base) do
        input_type RubyLLM::Contract::Types::String
        output_type RubyLLM::Contract::Types::Hash
        prompt { user "{input}" }
        contract { parse :json }
      end

      pipeline = Class.new(described_class)
      pipeline.step s1, as: :only

      expect do
        pipeline.run("test", context: { adapter: adapter }, timeout_ms: -100)
      end.to raise_error(ArgumentError, /timeout_ms must be positive/)
    end

    it "raises ArgumentError when timeout_ms is zero" do
      adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"v": 1}')

      s1 = Class.new(RubyLLM::Contract::Step::Base) do
        input_type RubyLLM::Contract::Types::String
        output_type RubyLLM::Contract::Types::Hash
        prompt { user "{input}" }
        contract { parse :json }
      end

      pipeline = Class.new(described_class)
      pipeline.step s1, as: :only

      expect do
        pipeline.run("test", context: { adapter: adapter }, timeout_ms: 0)
      end.to raise_error(ArgumentError, /timeout_ms must be positive/)
    end

    it "includes outputs and trace for executed steps on timeout" do
      slow_adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"v": 1}')
      allow(slow_adapter).to receive(:call).and_wrap_original do |m, **args|
        sleep(0.05)
        m.call(**args)
      end

      s1 = Class.new(RubyLLM::Contract::Step::Base) do
        input_type RubyLLM::Contract::Types::String
        output_type RubyLLM::Contract::Types::Hash
        prompt { user "{input}" }
        contract { parse :json }
      end

      s2 = Class.new(RubyLLM::Contract::Step::Base) do
        input_type RubyLLM::Contract::Types::Hash
        output_type RubyLLM::Contract::Types::Hash
        prompt { user "{input}" }
        contract { parse :json }
      end

      pipeline = Class.new(described_class)
      pipeline.step s1, as: :first
      pipeline.step s2, as: :second

      # 50ms per step, timeout at 80ms → times out after step 2
      result = pipeline.run("test", context: { adapter: slow_adapter }, timeout_ms: 80)

      expect(result.trace.step_traces.length).to be >= 1
      expect(result.trace.total_latency_ms).to be >= 50
    end
  end
end
