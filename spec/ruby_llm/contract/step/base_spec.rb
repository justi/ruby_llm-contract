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
    it "raises ArgumentError when defining an eval with a name that already exists" do
      step = Class.new(RubyLLM::Contract::Step::Base) do
        prompt "test {input}"
      end

      step.define_eval("smoke") do
        default_input "test"
      end

      expect do
        step.define_eval("smoke") do
          default_input "test again"
        end
      end.to raise_error(ArgumentError, /eval 'smoke' is already defined/)
    end
  end
end
