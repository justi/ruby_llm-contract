# frozen_string_literal: true

class TestClassifyIntent < RubyLLM::Contract::Step::Base
  input_type  RubyLLM::Contract::Types::String
  output_type RubyLLM::Contract::Types::Hash

  prompt do
    system "Classify the user's intent."
    rule   "Return JSON only."
    rule   "Allowed intents: sales, support, billing."
    user   "{input}"
  end

  contract do
    parse :json
    invariant("must include intent") { |output| output[:intent].to_s != "" }
    invariant("intent must be allowed") { |output| %w[sales support billing].include?(output[:intent]) }
  end
end

RSpec.describe RubyLLM::Contract::Step::Base do
  before { RubyLLM::Contract.reset_configuration! }

  describe "class macros" do
    it "has input_type accessor" do
      expect(TestClassifyIntent.input_type).to eq(RubyLLM::Contract::Types::String)
    end

    it "has output_type accessor" do
      expect(TestClassifyIntent.output_type).to eq(RubyLLM::Contract::Types::Hash)
    end

    it "has prompt accessor returning a Proc" do
      expect(TestClassifyIntent.prompt).to be_a(Proc)
    end

    it "has contract accessor returning a Definition" do
      expect(TestClassifyIntent.contract).to be_a(RubyLLM::Contract::Definition)
    end
  end

  describe ".run" do
    context "with valid input and valid adapter response" do
      it "returns :ok with parsed output" do
        adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"intent":"sales"}')
        result = TestClassifyIntent.run("I need help with sales", context: { adapter: adapter })

        expect(result.status).to eq(:ok)
        expect(result.ok?).to be true
        expect(result.parsed_output).to eq({ intent: "sales" })
      end
    end

    context "with invalid input" do
      it "returns :input_error" do
        adapter = RubyLLM::Contract::Adapters::Test.new(response: "unused")
        result = TestClassifyIntent.run(123, context: { adapter: adapter })

        expect(result.status).to eq(:input_error)
        expect(result.failed?).to be true
        expect(result.validation_errors).not_to be_empty
      end
    end

    context "with adapter returning JSON that fails invariant" do
      it "returns :validation_failed" do
        adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"intent":"unknown"}')
        result = TestClassifyIntent.run("help me", context: { adapter: adapter })

        expect(result.status).to eq(:validation_failed)
        expect(result.validation_errors).to include("intent must be allowed")
        expect(result.raw_output).to eq('{"intent":"unknown"}')
        expect(result.parsed_output).to eq({ intent: "unknown" })
      end
    end

    context "with adapter returning malformed JSON" do
      it "returns :parse_error" do
        adapter = RubyLLM::Contract::Adapters::Test.new(response: "not json")
        result = TestClassifyIntent.run("help me", context: { adapter: adapter })

        expect(result.status).to eq(:parse_error)
        expect(result.raw_output).to eq("not json")
      end
    end

    context "adapter resolution" do
      it "uses global default adapter when no context adapter" do
        adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"intent":"billing"}')
        RubyLLM::Contract.configure { |c| c.default_adapter = adapter }

        result = TestClassifyIntent.run("I need help with my invoice")

        expect(result.status).to eq(:ok)
        expect(result.parsed_output).to eq({ intent: "billing" })
      end

      it "uses context adapter over global default" do
        global_adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"intent":"sales"}')
        context_adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"intent":"billing"}')
        RubyLLM::Contract.configure { |c| c.default_adapter = global_adapter }

        result = TestClassifyIntent.run("help", context: { adapter: context_adapter })

        expect(result.parsed_output).to eq({ intent: "billing" })
      end

      it "raises RubyLLM::Contract::Error when no adapter is configured" do
        expect do
          TestClassifyIntent.run("help")
        end.to raise_error(RubyLLM::Contract::Error, /No adapter configured/)
      end
    end

    context "with model in context" do
      it "passes model to trace" do
        adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"intent":"sales"}')
        result = TestClassifyIntent.run("help", context: { adapter: adapter, model: "gpt-4.1-mini" })

        expect(result.trace[:model]).to eq("gpt-4.1-mini")
      end
    end
  end

  describe "2-arity validate (receives input)" do
    it "passes input to the validate block alongside output" do
      step = Class.new(RubyLLM::Contract::Step::Base) do
        input_type String
        prompt "Translate: {input}"
        validate("output language matches requested") do |output, input|
          output[:requested] == input
        end
      end

      adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"requested": "hello"}')
      result = step.run("hello", context: { adapter: adapter })
      expect(result.status).to eq(:ok)
    end

    it "fails when 2-arity validate returns false" do
      step = Class.new(RubyLLM::Contract::Step::Base) do
        input_type String
        prompt "Process: {input}"
        validate("output echoes input") do |output, input|
          output[:echo] == input
        end
      end

      adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"echo": "wrong"}')
      result = step.run("expected", context: { adapter: adapter })
      expect(result.status).to eq(:validation_failed)
      expect(result.validation_errors).to include("output echoes input")
    end
  end

  describe ".define_eval duplicate name" do
    it "warns and replaces when defining an eval with a duplicate name" do
      step = Class.new(RubyLLM::Contract::Step::Base) do
        prompt "test {input}"
      end

      step.define_eval("smoke") do
        default_input "test"
      end

      expect(step).to receive(:warn).with(/Redefining eval 'smoke'/i)

      step.define_eval("smoke") do
        default_input "test again"
      end

      expect(step.eval_names).to eq(["smoke"])
    end
  end

  describe "reasoning_effort forwarding" do
    it "passes reasoning_effort from context through to adapter" do
      step = Class.new(described_class) { prompt "test {input}" }
      adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"v": 1}')

      allow(adapter).to receive(:call).and_call_original

      step.run("hello", context: { adapter: adapter, reasoning_effort: "low" })

      expect(adapter).to have_received(:call).with(
        hash_including(messages: anything, reasoning_effort: "low")
      )
    end
  end

  describe ".recommend" do
    it "returns a Recommendation with best model and retry_chain" do
      step = Class.new(described_class) do
        input_type String
        output_type Hash
        prompt { user "{input}" }
        validate("has intent") { |o| !o[:intent].to_s.empty? }

        define_eval("smoke") do
          default_input "test query"
          verify "has intent", { intent: /billing/ }
        end
      end

      # Use a non-zero usage so CostCalculator can produce a positive cost
      adapter = RubyLLM::Contract::Adapters::Test.new(
        response: '{"intent": "billing", "confidence": 0.9}',
        usage: { input_tokens: 100, output_tokens: 50 }
      )

      rec = step.recommend(
        "smoke",
        candidates: [
          { model: "gpt-4.1-nano" },
          { model: "gpt-4.1-mini" }
        ],
        min_score: 0.5,
        context: { adapter: adapter }
      )

      expect(rec).to be_a(RubyLLM::Contract::Eval::Recommendation)
      expect(rec).to be_frozen
      expect(rec.to_dsl).to be_a(String)
      # Warnings may include unknown pricing since Test adapter doesn't look up real costs
      # The recommendation still returns valid structure
      expect(rec.rationale).not_to be_empty
    end
  end

  describe ".current_model_config" do
    it "returns first config from retry_policy when present" do
      step = Class.new(described_class) do
        prompt "test {input}"
        retry_policy do
          escalate({ model: "gpt-4.1-nano" }, { model: "gpt-4.1-mini", reasoning_effort: "high" })
        end
      end

      config = step.send(:current_model_config)
      expect(config).to eq({ model: "gpt-4.1-nano" })
    end

    it "returns model hash when no retry_policy" do
      step = Class.new(described_class) do
        prompt "test {input}"
        model "gpt-4.1-mini"
      end

      config = step.send(:current_model_config)
      expect(config).to eq({ model: "gpt-4.1-mini" })
    end

    it "returns default_model hash when no model set" do
      RubyLLM::Contract.configure { |c| c.default_model = "gpt-5-mini" }

      step = Class.new(described_class) do
        prompt "test {input}"
      end

      config = step.send(:current_model_config)
      expect(config).to eq({ model: "gpt-5-mini" })
    end
  end
end
