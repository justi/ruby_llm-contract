# frozen_string_literal: true

RSpec.describe "output_schema integration" do
  before { RubyLLM::Contract.reset_configuration! }

  let(:mock_response) do
    instance_double(
      "RubyLLM::Message",
      content: { "intent" => "sales", "confidence" => 0.95 },
      input_tokens: 30,
      output_tokens: 10
    )
  end

  let(:mock_chat) do
    instance_double("RubyLLM::Chat").tap do |chat|
      allow(chat).to receive(:with_instructions).and_return(chat)
      allow(chat).to receive(:with_temperature).and_return(chat)
      allow(chat).to receive(:with_params).and_return(chat)
      allow(chat).to receive(:with_schema).and_return(chat)
      allow(chat).to receive(:add_message).and_return(nil)
      allow(chat).to receive(:ask).and_return(mock_response)
    end
  end

  # Step with output_schema
  let(:schema_step) do
    Class.new(RubyLLM::Contract::Step::Base) do
      input_type RubyLLM::Contract::Types::String

      output_schema do
        string :intent, enum: %w[sales support billing]
        number :confidence, minimum: 0.0, maximum: 1.0
      end

      prompt do
        system "Classify intent."
        user "{input}"
      end
    end
  end

  # Step with output_schema + invariants
  let(:schema_step_with_invariants) do
    Class.new(RubyLLM::Contract::Step::Base) do
      input_type RubyLLM::Contract::Types::String

      output_schema do
        string :intent, enum: %w[sales support billing]
        number :confidence, minimum: 0.0, maximum: 1.0
      end

      prompt do
        system "Classify intent."
        user "{input}"
      end

      contract do
        invariant("high confidence required") { |o| o[:confidence] > 0.5 }
      end
    end
  end

  describe "Step::Base.output_schema" do
    it "stores schema as a RubyLLM::Schema subclass" do
      expect(schema_step.output_schema).to be < RubyLLM::Schema
    end

    it "returns nil when no schema defined" do
      step = Class.new(RubyLLM::Contract::Step::Base) do
        input_type RubyLLM::Contract::Types::String
        output_type RubyLLM::Contract::Types::Hash
        prompt { user "{input}" }
      end
      expect(step.output_schema).to be_nil
    end

    it "defaults output_type to Types::Hash when schema is present" do
      expect(schema_step.output_type).to eq(RubyLLM::Contract::Types::Hash)
    end
  end

  describe "with RubyLLM adapter" do
    before { allow(RubyLLM).to receive(:chat).and_return(mock_chat) }

    let(:adapter) { RubyLLM::Contract::Adapters::RubyLLM.new }

    it "passes schema to adapter and calls with_schema" do
      schema_step.run("test", context: { adapter: adapter, model: "gpt-4.1-mini" })

      expect(mock_chat).to have_received(:with_schema)
    end

    it "returns :ok with parsed Hash from auto-parsed response" do
      result = schema_step.run("test", context: { adapter: adapter, model: "gpt-4.1-mini" })

      expect(result.status).to eq(:ok)
      expect(result.parsed_output).to eq({ intent: "sales", confidence: 0.95 })
    end

    it "skips output_type validation when schema present" do
      # If output_type validation ran on a Hash, it would try dry-types coercion
      # which could fail. Schema steps skip this.
      result = schema_step.run("test", context: { adapter: adapter, model: "gpt-4.1-mini" })

      expect(result.status).to eq(:ok)
    end

    it "still evaluates invariants on schema steps" do
      result = schema_step_with_invariants.run("test", context: { adapter: adapter, model: "gpt-4.1-mini" })

      expect(result.status).to eq(:ok)
    end

    it "reports invariant failures on schema steps" do
      low_confidence = instance_double(
        "RubyLLM::Message",
        content: { "intent" => "sales", "confidence" => 0.2 },
        input_tokens: 30,
        output_tokens: 10
      )
      allow(mock_chat).to receive(:ask).and_return(low_confidence)

      result = schema_step_with_invariants.run("test", context: { adapter: adapter, model: "gpt-4.1-mini" })

      expect(result.status).to eq(:validation_failed)
      expect(result.validation_errors).to include("high confidence required")
    end
  end

  describe "with Test adapter" do
    it "auto-infers parse :json and parses string response" do
      adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"intent": "sales", "confidence": 0.9}')
      result = schema_step.run("test", context: { adapter: adapter })

      expect(result.status).to eq(:ok)
      expect(result.parsed_output).to eq({ intent: "sales", confidence: 0.9 })
    end

    it "returns :parse_error for non-JSON with schema step" do
      adapter = RubyLLM::Contract::Adapters::Test.new(response: "not json")
      result = schema_step.run("test", context: { adapter: adapter })

      expect(result.status).to eq(:parse_error)
    end

    it "evaluates invariants with Test adapter too" do
      adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"intent": "sales", "confidence": 0.2}')
      result = schema_step_with_invariants.run("test", context: { adapter: adapter })

      expect(result.status).to eq(:validation_failed)
      expect(result.validation_errors).to include("high confidence required")
    end
  end

  describe "backward compatibility" do
    it "steps without schema work exactly as before" do
      step = Class.new(RubyLLM::Contract::Step::Base) do
        input_type RubyLLM::Contract::Types::String
        output_type RubyLLM::Contract::Types::Hash

        prompt { user "{input}" }

        contract do
          parse :json
          invariant("has key") { |o| o[:key].to_s != "" }
        end
      end

      adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"key": "value"}')
      result = step.run("test", context: { adapter: adapter })

      expect(result.status).to eq(:ok)
      expect(result.parsed_output).to eq({ key: "value" })
    end
  end
end
