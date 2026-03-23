# frozen_string_literal: true

RSpec.describe "DSL Simplification (GH-12)" do
  before { RubyLLM::Contract.reset_configuration! }

  # =========================================================================
  # F-1: Top-level validate without contract do
  # =========================================================================

  describe "top-level validate" do
    it "works without contract do wrapper" do
      step = Class.new(RubyLLM::Contract::Step::Base) do
        input_type String
        output_type Hash

        prompt { user "{input}" }

        validate("has name") { |o| !o[:name].to_s.empty? }
        validate("age positive") { |o| o[:age].is_a?(Integer) && o[:age] > 0 }
      end

      adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"name": "Alice", "age": 30}')
      result = step.run("test", context: { adapter: adapter })

      expect(result.status).to eq(:ok)
    end

    it "catches validation failures" do
      step = Class.new(RubyLLM::Contract::Step::Base) do
        input_type String
        output_type Hash
        prompt { user "{input}" }
        validate("has name") { |o| !o[:name].to_s.empty? }
      end

      adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"name": ""}')
      result = step.run("test", context: { adapter: adapter })

      expect(result.status).to eq(:validation_failed)
      expect(result.validation_errors).to include("has name")
    end

    it "works alongside contract do (backward compat)" do
      step = Class.new(RubyLLM::Contract::Step::Base) do
        input_type String
        output_type Hash
        prompt { user "{input}" }

        contract do
          parse :json
          validate("from contract") { |o| o[:a] == 1 }
        end

        validate("from top-level") { |o| o[:b] == 2 }
      end

      adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"a": 1, "b": 2}')
      result = step.run("test", context: { adapter: adapter })
      expect(result.status).to eq(:ok)

      # Both fail
      adapter2 = RubyLLM::Contract::Adapters::Test.new(response: '{"a": 0, "b": 0}')
      result2 = step.run("test", context: { adapter: adapter2 })
      expect(result2.validation_errors).to include("from contract")
      expect(result2.validation_errors).to include("from top-level")
    end
  end

  # =========================================================================
  # F-2: Implicit parse from output_type
  # =========================================================================

  describe "implicit parse" do
    it "output_type Hash implies JSON parse" do
      step = Class.new(RubyLLM::Contract::Step::Base) do
        input_type String
        output_type Hash
        prompt { user "{input}" }
        validate("has key") { |o| o[:v] == 1 }
      end

      adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"v": 1}')
      result = step.run("test", context: { adapter: adapter })

      expect(result.status).to eq(:ok)
      expect(result.parsed_output).to eq({ v: 1 })
    end

    it "output_type String implies text parse" do
      step = Class.new(RubyLLM::Contract::Step::Base) do
        input_type String
        output_type String
        prompt { user "{input}" }
      end

      adapter = RubyLLM::Contract::Adapters::Test.new(response: "hello world")
      result = step.run("test", context: { adapter: adapter })

      expect(result.status).to eq(:ok)
      expect(result.parsed_output).to eq("hello world")
    end

    it "explicit contract parse overrides implicit" do
      step = Class.new(RubyLLM::Contract::Step::Base) do
        input_type String
        output_type RubyLLM::Contract::Types::Hash
        prompt { user "{input}" }
        contract { parse :text }
      end

      adapter = RubyLLM::Contract::Adapters::Test.new(response: "not json")
      result = step.run("test", context: { adapter: adapter })

      # text parse → raw string, Hash type validation fails
      expect(result.status).to eq(:validation_failed)
    end
  end

  # =========================================================================
  # F-3: retry_policy keyword args + models alias
  # =========================================================================

  describe "retry_policy keywords" do
    it "accepts models: as one-liner" do
      step = Class.new(RubyLLM::Contract::Step::Base) do
        input_type String
        output_type Hash
        prompt { user "{input}" }
        validate("always fails") { |_o| false }
        retry_policy models: %w[nano mini full]
      end

      adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"v": 1}')
      result = step.run("test", context: { adapter: adapter })

      expect(result.trace[:attempts].size).to eq(3)
      expect(result.trace[:attempts].map { |a| a[:model] }).to eq(%w[nano mini full])
    end

    it "accepts attempts: without models" do
      step = Class.new(RubyLLM::Contract::Step::Base) do
        input_type String
        output_type Hash
        prompt { user "{input}" }
        validate("always fails") { |_o| false }
        retry_policy attempts: 2
      end

      adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"v": 1}')
      result = step.run("test", context: { adapter: adapter, model: "default" })

      expect(result.trace[:attempts].size).to eq(2)
      expect(result.trace[:attempts].map { |a| a[:model] }).to eq(%w[default default])
    end

    it "models alias works in block DSL" do
      step = Class.new(RubyLLM::Contract::Step::Base) do
        input_type String
        output_type Hash
        prompt { user "{input}" }
        validate("always fails") { |_o| false }
        retry_policy do
          models "nano", "full"
        end
      end

      adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"v": 1}')
      result = step.run("test", context: { adapter: adapter })

      expect(result.trace[:attempts].size).to eq(2)
    end

    it "block DSL still works (backward compat)" do
      step = Class.new(RubyLLM::Contract::Step::Base) do
        input_type String
        output_type Hash
        prompt { user "{input}" }
        validate("always fails") { |_o| false }
        retry_policy do
          attempts 3
          escalate "a", "b", "c"
          retry_on :validation_failed
        end
      end

      adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"v": 1}')
      result = step.run("test", context: { adapter: adapter })

      expect(result.trace[:attempts].size).to eq(3)
    end
  end

  # =========================================================================
  # F-4: Test adapter with responses: array
  # =========================================================================

  describe "Test adapter responses: array" do
    it "returns responses in order" do
      adapter = RubyLLM::Contract::Adapters::Test.new(responses: [
                                                        { a: 1 },
                                                        { b: 2 },
                                                        { c: 3 }
                                                      ])

      r1 = adapter.call(messages: [])
      r2 = adapter.call(messages: [])
      r3 = adapter.call(messages: [])

      expect(r1.content).to eq({ a: 1 }.to_json)
      expect(r2.content).to eq({ b: 2 }.to_json)
      expect(r3.content).to eq({ c: 3 }.to_json)
    end

    it "repeats last response on overflow" do
      adapter = RubyLLM::Contract::Adapters::Test.new(responses: [{ a: 1 }])

      r1 = adapter.call(messages: [])
      r2 = adapter.call(messages: [])

      expect(r1.content).to eq(r2.content)
    end

    it "single response: still works (backward compat)" do
      adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"v": 1}')
      r = adapter.call(messages: [])
      expect(r.content).to eq('{"v": 1}')
    end
  end

  # =========================================================================
  # F-5: Pipeline.test with named responses
  # =========================================================================

  describe "Pipeline.test" do
    it "runs pipeline with named per-step responses" do
      s1 = Class.new(RubyLLM::Contract::Step::Base) do
        input_type String
        output_type Hash
        prompt { user "{input}" }
      end

      s2 = Class.new(RubyLLM::Contract::Step::Base) do
        input_type Hash
        output_type Hash
        prompt { user "{input}" }
      end

      pipeline = Class.new(RubyLLM::Contract::Pipeline::Base)
      pipeline.step s1, as: :first
      pipeline.step s2, as: :second

      result = pipeline.test("hello",
                             responses: {
                               first: { greeting: "hi" },
                               second: { reply: "bye" }
                             })

      expect(result.status).to eq(:ok)
      expect(result.outputs_by_step[:first]).to eq({ greeting: "hi" })
      expect(result.outputs_by_step[:second]).to eq({ reply: "bye" })
    end
  end

  # =========================================================================
  # F-6: Per-step model in pipeline
  # =========================================================================

  describe "per-step model in pipeline" do
    it "forwards model to each step" do
      s1 = Class.new(RubyLLM::Contract::Step::Base) do
        input_type String
        output_type Hash
        prompt { user "{input}" }
      end

      s2 = Class.new(RubyLLM::Contract::Step::Base) do
        input_type Hash
        output_type Hash
        prompt { user "{input}" }
      end

      pipeline = Class.new(RubyLLM::Contract::Pipeline::Base)
      pipeline.step s1, as: :first, model: "gpt-4.1-nano"
      pipeline.step s2, as: :second, model: "gpt-4.1"

      adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"v": 1}')
      result = pipeline.run("test", context: { adapter: adapter })

      models = result.step_results.map { |sr| sr[:result].trace.model }
      expect(models).to eq(%w[gpt-4.1-nano gpt-4.1])
    end

    it "falls back to context model when step model not set" do
      s1 = Class.new(RubyLLM::Contract::Step::Base) do
        input_type String
        output_type Hash
        prompt { user "{input}" }
      end

      pipeline = Class.new(RubyLLM::Contract::Pipeline::Base)
      pipeline.step s1, as: :only

      adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"v": 1}')
      result = pipeline.run("test", context: { adapter: adapter, model: "fallback" })

      expect(result.step_results.first[:result].trace.model).to eq("fallback")
    end
  end
end
