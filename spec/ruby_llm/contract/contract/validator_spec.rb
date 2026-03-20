# frozen_string_literal: true

RSpec.describe RubyLLM::Contract::Validator do
  let(:output_type) { RubyLLM::Contract::Types::Hash }

  describe ".validate" do
    context "when everything passes" do
      it "returns status :ok with parsed output" do
        definition = RubyLLM::Contract::Definition.new do
          parse :json
          invariant("must include intent") { |o| o[:intent].to_s != "" }
        end

        result = described_class.validate(
          raw_output: '{"intent":"sales"}',
          definition: definition,
          output_type: output_type
        )

        expect(result[:status]).to eq(:ok)
        expect(result[:parsed_output]).to eq({ intent: "sales" })
        expect(result[:errors]).to be_empty
      end
    end

    context "when parsing fails" do
      it "returns status :parse_error" do
        definition = RubyLLM::Contract::Definition.new do
          parse :json
        end

        result = described_class.validate(
          raw_output: "not json",
          definition: definition,
          output_type: output_type
        )

        expect(result[:status]).to eq(:parse_error)
        expect(result[:parsed_output]).to be_nil
        expect(result[:errors]).not_to be_empty
      end
    end

    context "when one invariant passes and one fails" do
      it "includes only the failing invariant description in errors" do
        definition = RubyLLM::Contract::Definition.new do
          parse :json
          invariant("must include intent") { |o| o[:intent].to_s != "" }
          invariant("intent must be allowed") { |o| %w[sales support].include?(o[:intent]) }
        end

        result = described_class.validate(
          raw_output: '{"intent":"billing"}',
          definition: definition,
          output_type: output_type
        )

        expect(result[:status]).to eq(:validation_failed)
        expect(result[:errors]).to include("intent must be allowed")
        expect(result[:errors]).not_to include("must include intent")
      end
    end

    context "when all invariants fail (no short-circuit)" do
      it "collects all failing invariant descriptions" do
        definition = RubyLLM::Contract::Definition.new do
          parse :json
          invariant("must include intent") { |o| o[:intent].to_s != "" }
          invariant("must include category") { |o| o[:category].to_s != "" }
          invariant("must include priority") { |o| o[:priority].to_s != "" }
        end

        result = described_class.validate(
          raw_output: "{}",
          definition: definition,
          output_type: output_type
        )

        expect(result[:status]).to eq(:validation_failed)
        expect(result[:errors]).to contain_exactly(
          "must include intent",
          "must include category",
          "must include priority"
        )
      end
    end

    context "when output_type schema validation fails" do
      it "includes the type error in errors" do
        definition = RubyLLM::Contract::Definition.new do
          parse :json
        end

        result = described_class.validate(
          raw_output: "[1, 2, 3]",
          definition: definition,
          output_type: RubyLLM::Contract::Types::Hash
        )

        expect(result[:status]).to eq(:validation_failed)
        expect(result[:errors]).not_to be_empty
      end
    end

    context "with 2-arity invariant receiving input" do
      it "passes input to the invariant block" do
        definition = RubyLLM::Contract::Definition.new do
          parse :json
          invariant("output must reference input language") do |output, input|
            output[:lang] == input[:lang]
          end
        end

        result = described_class.validate(
          raw_output: '{"lang":"fr"}',
          definition: definition,
          output_type: output_type,
          input: { lang: "fr" }
        )

        expect(result[:status]).to eq(:ok)
      end

      it "fails when 2-arity invariant returns false" do
        definition = RubyLLM::Contract::Definition.new do
          parse :json
          invariant("output language matches input") do |output, input|
            output[:lang] == input[:lang]
          end
        end

        result = described_class.validate(
          raw_output: '{"lang":"en"}',
          definition: definition,
          output_type: output_type,
          input: { lang: "fr" }
        )

        expect(result[:status]).to eq(:validation_failed)
        expect(result[:errors]).to include("output language matches input")
      end
    end
  end
end
