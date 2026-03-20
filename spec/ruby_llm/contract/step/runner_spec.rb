# frozen_string_literal: true

RSpec.describe RubyLLM::Contract::Step::Runner do
  let(:input_type) { RubyLLM::Contract::Types::String }
  let(:output_type) { RubyLLM::Contract::Types::Hash }
  let(:prompt_block) do
    proc do
      system "Classify the user's intent."
      rule "Return JSON only."
      user "{input}"
    end
  end

  describe "#call" do
    context "with a successful run" do
      it "returns :ok with parsed output" do
        adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"intent":"sales"}')
        definition = RubyLLM::Contract::Definition.new do
          parse :json
          invariant("must include intent") { |o| o[:intent].to_s != "" }
        end

        runner = described_class.new(
          input_type: input_type,
          output_type: output_type,
          prompt_block: prompt_block,
          contract_definition: definition,
          adapter: adapter,
          model: "gpt-4"
        )

        result = runner.call("I need help")

        expect(result.status).to eq(:ok)
        expect(result.parsed_output).to eq({ intent: "sales" })
        expect(result.raw_output).to eq('{"intent":"sales"}')
      end
    end

    context "with input validation failure" do
      it "returns :input_error and never calls the adapter" do
        adapter = RubyLLM::Contract::Adapters::Test.new(response: "unused")
        definition = RubyLLM::Contract::Definition.new

        runner = described_class.new(
          input_type: input_type,
          output_type: output_type,
          prompt_block: prompt_block,
          contract_definition: definition,
          adapter: adapter,
          model: "gpt-4"
        )

        result = runner.call(123) # Integer, not String

        expect(result.status).to eq(:input_error)
        expect(result.validation_errors).not_to be_empty
        expect(result.raw_output).to be_nil
      end
    end

    context "with parse failure" do
      it "returns :parse_error" do
        adapter = RubyLLM::Contract::Adapters::Test.new(response: "not json at all")
        definition = RubyLLM::Contract::Definition.new do
          parse :json
        end

        runner = described_class.new(
          input_type: input_type,
          output_type: output_type,
          prompt_block: prompt_block,
          contract_definition: definition,
          adapter: adapter,
          model: "gpt-4"
        )

        result = runner.call("hello")

        expect(result.status).to eq(:parse_error)
        expect(result.raw_output).to eq("not json at all")
        expect(result.parsed_output).to be_nil
      end
    end

    context "with invariant failure" do
      it "returns :validation_failed with error descriptions" do
        adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"intent":"unknown"}')
        definition = RubyLLM::Contract::Definition.new do
          parse :json
          invariant("intent must be allowed") { |o| %w[sales support billing].include?(o[:intent]) }
        end

        runner = described_class.new(
          input_type: input_type,
          output_type: output_type,
          prompt_block: prompt_block,
          contract_definition: definition,
          adapter: adapter,
          model: "gpt-4"
        )

        result = runner.call("help")

        expect(result.status).to eq(:validation_failed)
        expect(result.validation_errors).to include("intent must be allowed")
        expect(result.raw_output).to eq('{"intent":"unknown"}')
        expect(result.parsed_output).to eq({ intent: "unknown" })
      end
    end

    context "with adapter error" do
      it "returns :adapter_error" do
        failing_adapter = Class.new(RubyLLM::Contract::Adapters::Base) do
          def call(messages:, **_options) # rubocop:disable Lint/UnusedMethodArgument
            raise StandardError, "connection timeout"
          end
        end.new
        definition = RubyLLM::Contract::Definition.new

        runner = described_class.new(
          input_type: input_type,
          output_type: output_type,
          prompt_block: prompt_block,
          contract_definition: definition,
          adapter: failing_adapter,
          model: "gpt-4"
        )

        result = runner.call("hello")

        expect(result.status).to eq(:adapter_error)
        expect(result.validation_errors).to include("connection timeout")
      end
    end

    context "with plain Ruby class input_type" do
      it "accepts input that is_a? the class" do
        adapter = RubyLLM::Contract::Adapters::Test.new(response: "hello")
        definition = RubyLLM::Contract::Definition.new

        runner = described_class.new(
          input_type: String,
          output_type: String,
          prompt_block: proc { user "{input}" },
          contract_definition: definition,
          adapter: adapter,
          model: "gpt-4"
        )

        result = runner.call("valid string")
        expect(result.status).to eq(:ok)
      end

      it "rejects input that is not the class" do
        adapter = RubyLLM::Contract::Adapters::Test.new(response: "hello")
        definition = RubyLLM::Contract::Definition.new

        runner = described_class.new(
          input_type: String,
          output_type: String,
          prompt_block: proc { user "{input}" },
          contract_definition: definition,
          adapter: adapter,
          model: "gpt-4"
        )

        result = runner.call(42)
        expect(result.status).to eq(:input_error)
        expect(result.validation_errors.first).to include("42")
        expect(result.validation_errors.first).to include("String")
      end
    end

    context "trace metadata" do
      it "includes messages, model, latency_ms, and usage" do
        adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"intent":"sales"}')
        definition = RubyLLM::Contract::Definition.new do
          parse :json
        end

        runner = described_class.new(
          input_type: input_type,
          output_type: output_type,
          prompt_block: prompt_block,
          contract_definition: definition,
          adapter: adapter,
          model: "gpt-4.1-mini"
        )

        result = runner.call("test input")

        expect(result.trace[:messages]).to be_an(Array)
        expect(result.trace[:messages].size).to eq(3)
        expect(result.trace[:model]).to eq("gpt-4.1-mini")
        expect(result.trace[:latency_ms]).to be_a(Integer)
        expect(result.trace[:usage]).to eq({ input_tokens: 0, output_tokens: 0 })
      end
    end
  end
end
