# frozen_string_literal: true

# Adversarial QA round 6 -- behavioral correctness bugs.
# Rounds 1-5 found 30 bugs (mostly crashes and missing validation).
# Round 6 focuses on cases where the code runs without error but produces
# a WRONG RESULT -- silent data corruption, lost observability, shifted
# responses, and discarded coercions.

RSpec.describe "Adversarial QA round 6 -- behavioral correctness bugs" do
  before { RubyLLM::Contract.reset_configuration! }

  # ---------------------------------------------------------------------------
  # BUG 33: validate_type discards coerced value from Dry::Types.
  #
  # When output_type is a Dry::Types coercible type (e.g.,
  # Types::Coercible::Integer), validate_type calls output_type[parsed_output]
  # to check for errors. If coercion succeeds, no error is raised. But the
  # COERCED return value is discarded -- parsed_output stays as the original
  # pre-coercion value.
  #
  # Example: output_type is Types::Coercible::Integer, raw output is "42".
  # - Parser returns "42" (String)
  # - validate_type calls Types::Coercible::Integer["42"] -> returns 42 (Integer)
  # - But parsed_output stays "42" (String)
  # - Invariants see "42" (String), not 42 (Integer)
  # - Caller receives "42" (String) as parsed_output
  #
  # This is a WRONG RESULT because the type system says "this is an Integer"
  # but the actual output is a String. The coercion contract is honored for
  # validation but violated for the actual value.
  #
  # Fix: If output_type supports [] and produces a different value, use the
  # coerced value as parsed_output going forward.
  # ---------------------------------------------------------------------------
  describe "BUG 33: validate_type discards coerced value from Dry::Types" do
    it "returns the coerced value when using Coercible types" do
      result = RubyLLM::Contract::Validator.validate(
        raw_output: "42",
        definition: RubyLLM::Contract::Definition.new { parse :text },
        output_type: RubyLLM::Contract::Types::Coercible::Integer
      )

      expect(result[:status]).to eq(:ok)
      expect(result[:parsed_output]).to eq(42),
                                        "Expected parsed_output to be Integer 42 (coerced), " \
                                        "got #{result[:parsed_output].class} #{result[:parsed_output].inspect}. " \
                                        "The coerced value is silently discarded."
      actual_class = result[:parsed_output].class
      expect(result[:parsed_output]).to be_a(Integer),
                                        "parsed_output should be Integer after coercion, got #{actual_class}"
    end

    it "returns the coerced value when using Coercible::String" do
      result = RubyLLM::Contract::Validator.validate(
        raw_output: "42",
        definition: RubyLLM::Contract::Definition.new { parse :text },
        output_type: RubyLLM::Contract::Types::Coercible::String
      )

      expect(result[:status]).to eq(:ok)
      # String to String coercion is identity, should still work
      expect(result[:parsed_output]).to be_a(String)
    end

    it "makes coerced value available to invariants" do
      invariant_saw_type = nil

      definition = RubyLLM::Contract::Definition.new do
        parse :text
        invariant("is integer") do |output|
          invariant_saw_type = output.class
          output.is_a?(Integer)
        end
      end

      result = RubyLLM::Contract::Validator.validate(
        raw_output: "42",
        definition: definition,
        output_type: RubyLLM::Contract::Types::Coercible::Integer
      )

      expect(result[:status]).to eq(:ok),
                                 "Invariant should pass because it sees the coerced Integer, " \
                                 "got: #{result[:errors].inspect}"
      expect(invariant_saw_type).to eq(Integer),
                                    "Invariant should see Integer (coerced), but saw #{invariant_saw_type}"
    end

    it "works end-to-end: step with Coercible::Integer output_type" do
      step = Class.new(RubyLLM::Contract::Step::Base) do
        input_type String
        output_type RubyLLM::Contract::Types::Coercible::Integer
        prompt { |i| user "give me a number for: #{i}" }
        contract { parse :text }
        validate("is positive") { |o| o.is_a?(Integer) && o > 0 }
      end

      adapter = RubyLLM::Contract::Adapters::Test.new(response: "42")
      result = step.run("test", context: { adapter: adapter })

      expect(result.status).to eq(:ok),
                               "Step with Coercible::Integer should coerce '42' to 42 and pass validation, " \
                               "got: #{result.status} -- #{result.validation_errors}"
      expect(result.parsed_output).to eq(42)
      expect(result.parsed_output).to be_a(Integer)
    end
  end

  # ---------------------------------------------------------------------------
  # BUG 34: Pipeline#test compact shifts responses when middle steps are missing.
  #
  # Pipeline::Base.test does:
  #   ordered_responses = steps.map { |s| responses[s[:alias]] }
  #   adapter = Adapters::Test.new(responses: ordered_responses.compact)
  #
  # When a step's alias is not in the responses hash, it contributes nil to
  # ordered_responses. The .compact removes these nils, SHIFTING all
  # subsequent responses forward. This means step N+1 silently receives
  # step N's response.
  #
  # Example: 3 steps (:first, :second, :third), responses only for :first
  # and :third.
  #   ordered_responses = [resp1, nil, resp3]
  #   After compact:     [resp1, resp3]
  #   Step :first gets resp1    (correct)
  #   Step :second gets resp3   (WRONG -- shifted from :third)
  #   Step :third gets resp3    (falls back to last, happens to be right)
  #
  # This is a WRONG RESULT because step :second silently receives step
  # :third's response. Tests pass with wrong data, hiding bugs.
  #
  # Fix: Replace nil with a sensible default (empty string) instead of
  # compacting, OR raise an error when a step has no response mapping.
  # ---------------------------------------------------------------------------
  describe "BUG 34: Pipeline#test compact shifts responses for missing middle steps" do
    it "does not shift responses when a middle step has no mapping" do
      step1 = Class.new(RubyLLM::Contract::Step::Base) do
        input_type String
        output_type RubyLLM::Contract::Types::Hash
        contract { parse :json }
        prompt { |i| user "step1: #{i}" }
      end

      step2 = Class.new(RubyLLM::Contract::Step::Base) do
        input_type RubyLLM::Contract::Types::Hash
        output_type RubyLLM::Contract::Types::Hash
        contract { parse :json }
        prompt { |i| user "step2: #{i}" }
      end

      step3 = Class.new(RubyLLM::Contract::Step::Base) do
        input_type RubyLLM::Contract::Types::Hash
        output_type RubyLLM::Contract::Types::Hash
        contract { parse :json }
        prompt { |i| user "step3: #{i}" }
      end

      pipeline = Class.new(RubyLLM::Contract::Pipeline::Base) do
        step step1, as: :first
        step step2, as: :second
        step step3, as: :third
      end

      result = pipeline.test("hello", responses: {
                               first: '{"from": "step1"}',
                               second: '{"from": "step2"}',
                               third: '{"from": "step3"}'
                             })

      # Baseline: all responses provided, each step gets its own
      expect(result.status).to eq(:ok)
      expect(result.outputs_by_step[:first]).to eq({ from: "step1" })
      expect(result.outputs_by_step[:second]).to eq({ from: "step2" })
      expect(result.outputs_by_step[:third]).to eq({ from: "step3" })

      # Now test with missing middle step response
      result2 = pipeline.test("hello", responses: {
                                first: '{"from": "step1"}',
                                third: '{"from": "step3"}'
                              })

      # Step :second should NOT receive step :third's response
      second_output = result2.outputs_by_step[:second]
      if result2.ok? && second_output
        expect(second_output).not_to eq({ from: "step3" }),
                                     "Step :second received step :third's response due to compact shifting. " \
                                     "Missing middle step responses cause silent data corruption."
      end
    end
  end

  # ---------------------------------------------------------------------------
  # BUG 36: Schema + invariant errors are both reported (correctness check).
  #
  # Verify that when BOTH schema validation and invariant validation produce
  # errors, ALL errors are reported. This is a behavioral correctness guard
  # to ensure neither error source masks the other.
  # ---------------------------------------------------------------------------
  describe "BUG 36 (guard): Schema errors and invariant errors are both reported" do
    it "returns errors from both schema and invariants" do
      schema = Class.new do
        def to_json_schema
          {
            schema: {
              type: "object",
              required: %w[x],
              properties: {
                x: { type: "string", enum: %w[a b] }
              }
            }
          }
        end
      end

      definition = RubyLLM::Contract::Definition.new do
        parse :json
        invariant("x must be a") { |o| o[:x] == "a" }
      end

      result = RubyLLM::Contract::Validator.validate(
        raw_output: '{"x": "c"}',
        definition: definition,
        output_type: RubyLLM::Contract::Types::Hash,
        schema: schema.new
      )

      expect(result[:status]).to eq(:validation_failed)
      # Should have BOTH: schema enum error AND invariant error
      expect(result[:errors].length).to be >= 2,
                                        "Expected at least 2 errors (schema enum + invariant), " \
                                        "got #{result[:errors].length}: #{result[:errors].inspect}"

      schema_error = result[:errors].any? { |e| e.include?("enum") }
      invariant_error = result[:errors].any? { |e| e.include?("x must be a") }

      expect(schema_error).to be(true),
                              "Schema enum error should be present in: #{result[:errors].inspect}"
      expect(invariant_error).to be(true),
                                 "Invariant error should be present in: #{result[:errors].inspect}"
    end
  end

  # ---------------------------------------------------------------------------
  # BUG 37: Invariant that raises does not mask a preceding invariant failure.
  #
  # If invariant 1 passes, invariant 2 fails, invariant 3 raises, the
  # validation_errors should contain BOTH invariant 2's failure AND
  # invariant 3's raise. Verify no masking occurs.
  # ---------------------------------------------------------------------------
  describe "BUG 37 (guard): Raising invariant does not mask earlier failure" do
    it "reports both the failure and the raise" do
      definition = RubyLLM::Contract::Definition.new do
        parse :json
        invariant("always passes") { |_o| true }
        invariant("always fails") { |_o| false }
        invariant("always raises") { |_o| raise "kaboom" }
      end

      result = RubyLLM::Contract::Validator.validate(
        raw_output: '{"x": 1}',
        definition: definition,
        output_type: RubyLLM::Contract::Types::Hash
      )

      expect(result[:status]).to eq(:validation_failed)
      expect(result[:errors].length).to eq(2),
                                        "Expected 2 errors (1 failure + 1 raise), got: #{result[:errors].inspect}"

      expect(result[:errors]).to include("always fails")
      has_raise_error = result[:errors].any? do |e|
        e.include?("always raises") && e.include?("kaboom")
      end
      expect(has_raise_error).to be(true),
                                 "Raising invariant should be captured: #{result[:errors].inspect}"
    end
  end
end
