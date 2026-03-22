# frozen_string_literal: true

# Regression tests for bugs found during adversarial code review.
# Each describe block covers a specific bug and its fix.
# These tests MUST be kept -- they guard against regressions.

RSpec.describe "Adversarial QA -- bug regressions" do
  before { RubyLLM::Contract.reset_configuration! }

  # ---------------------------------------------------------------------------
  # BUG 1: evaluate_traits Range expectation was checking value.to_s.length
  # instead of the numeric value itself.
  #
  # Fix: Range now compares value directly when value is Numeric,
  # and falls back to string length only for non-numeric values.
  # ---------------------------------------------------------------------------
  describe "BUG 1: Range trait compares numeric values directly, not string length" do
    let(:step) do
      Class.new(RubyLLM::Contract::Step::Base) do
        prompt { user "{input}" }
        output_type RubyLLM::Contract::Types::Hash
        contract { parse :json }
      end
    end

    it "passes when numeric value (95) is within range 80..100" do
      adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"score": 95}')
      ds = RubyLLM::Contract::Eval::Dataset.define("range_numeric") do
        add_case("in range", input: "test", expected_traits: { score: 80..100 })
      end

      report = RubyLLM::Contract::Eval::Runner.run(step: step, dataset: ds, context: { adapter: adapter })

      expect(report.results.first.passed?).to eq(true),
        "score 95 should be in 80..100 (numeric comparison, not string-length)"
    end

    it "fails when numeric value (50) is outside range 80..100" do
      adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"score": 50}')
      ds = RubyLLM::Contract::Eval::Dataset.define("range_out") do
        add_case("out of range", input: "test", expected_traits: { score: 80..100 })
      end

      report = RubyLLM::Contract::Eval::Runner.run(step: step, dataset: ds, context: { adapter: adapter })

      expect(report.results.first.passed?).to eq(false)
      expect(report.results.first.details).to include("score")
    end

    it "falls back to string length for non-numeric values" do
      adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"title": "ab"}')
      ds = RubyLLM::Contract::Eval::Dataset.define("range_strlen") do
        add_case("string length check", input: "test", expected_traits: { title: 1..5 })
      end

      report = RubyLLM::Contract::Eval::Runner.run(step: step, dataset: ds, context: { adapter: adapter })

      # "ab".length == 2, which is in 1..5
      expect(report.results.first.passed?).to eq(true)
    end
  end

  # ---------------------------------------------------------------------------
  # BUG 2: parsed_output was never deep-frozen. Validate blocks could mutate
  # it, causing silent data corruption across pipeline steps and stored results.
  #
  # Fix: parsed_output is now deep-frozen before invariants run.
  # ---------------------------------------------------------------------------
  describe "BUG 2: parsed_output is deep-frozen, preventing mutation" do
    it "catches mutation attempts in validate blocks as FrozenError" do
      mutating_step = Class.new(RubyLLM::Contract::Step::Base) do
        prompt { user "{input}" }
        output_type RubyLLM::Contract::Types::Hash
        contract { parse :json }

        validate("name present") do |output|
          result = output.key?(:name)
          output.delete(:extra_field) # mutation attempt
          result
        end
      end

      adapter = RubyLLM::Contract::Adapters::Test.new(
        response: '{"name": "Alice", "extra_field": "should_survive"}'
      )
      result = mutating_step.run("test", context: { adapter: adapter })

      expect(result.status).to eq(:validation_failed)
      expect(result.validation_errors.first).to include("FrozenError")
      expect(result.parsed_output).to have_key(:extra_field)
    end

    it "prevents external code from mutating parsed_output on a completed Result" do
      step = Class.new(RubyLLM::Contract::Step::Base) do
        prompt { user "{input}" }
        output_type RubyLLM::Contract::Types::Hash
        contract { parse :json }
      end

      adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"key": "original"}')
      result = step.run("test", context: { adapter: adapter })

      expect(result.status).to eq(:ok)
      expect { result.parsed_output[:key] = "CORRUPTED" }.to raise_error(FrozenError)
      expect(result.parsed_output[:key]).to eq("original")
    end
  end

  # ---------------------------------------------------------------------------
  # BUG 3: Pipeline data corruption via shared mutable references.
  # Pipeline::Runner stored result.parsed_output in outputs_by_step AND
  # passed it as current_input to the next step -- same object reference.
  #
  # Fix: Deep-freeze on parsed_output prevents any mutation.
  # ---------------------------------------------------------------------------
  describe "BUG 3: pipeline outputs_by_step entries are frozen" do
    it "mutation in validate block raises FrozenError, failing the step cleanly" do
      step_a = Class.new(RubyLLM::Contract::Step::Base) do
        prompt { user "{input}" }
        output_type RubyLLM::Contract::Types::Hash
        contract { parse :json }
      end

      step_b = Class.new(RubyLLM::Contract::Step::Base) do
        input_type RubyLLM::Contract::Types::Hash
        output_type RubyLLM::Contract::Types::Hash
        prompt { |input| user input.to_json }
        contract { parse :json }
        validate("mutating check") do |output|
          output[:injected] = "CORRUPTION" # mutation attempt
          true
        end
      end

      pipeline = Class.new(RubyLLM::Contract::Pipeline::Base) do
        step step_a, as: :step_a
        step step_b, as: :step_b
      end

      result = pipeline.test("hello", responses: { step_a: { data: "a" }, step_b: { result: "b" } })

      expect(result.status).to eq(:validation_failed)
      expect(result.failed_step).to eq(:step_b)
    end

    it "outputs_by_step entries are frozen and cannot be mutated externally" do
      step_a = Class.new(RubyLLM::Contract::Step::Base) do
        prompt { user "{input}" }
        output_type RubyLLM::Contract::Types::Hash
        contract { parse :json }
      end

      step_b = Class.new(RubyLLM::Contract::Step::Base) do
        input_type RubyLLM::Contract::Types::Hash
        output_type RubyLLM::Contract::Types::Hash
        prompt { |input| user input.to_json }
        contract { parse :json }
      end

      pipeline = Class.new(RubyLLM::Contract::Pipeline::Base) do
        step step_a, as: :step_a
        step step_b, as: :step_b
      end

      result = pipeline.test("hello", responses: { step_a: { data: "a" }, step_b: { result: "b" } })

      expect(result.status).to eq(:ok)
      expect(result.outputs_by_step[:step_a]).to be_frozen
      expect { result.outputs_by_step[:step_a][:hacked] = true }.to raise_error(FrozenError)
    end
  end

  # ---------------------------------------------------------------------------
  # BUG 4: RetryPolicy keyword `models:` shared the caller's array reference.
  # Array(already_an_array) returns the SAME object in Ruby.
  #
  # Fix: .dup.freeze on the models array in the keyword path.
  # ---------------------------------------------------------------------------
  describe "BUG 4: RetryPolicy models: keyword copies and freezes the array" do
    it "is not affected by external mutation of the models array" do
      models_array = %w[gpt-4 gpt-4-turbo]
      policy = RubyLLM::Contract::Step::RetryPolicy.new(models: models_array)

      models_array[0] = "CORRUPTED"

      expect(policy.model_for_attempt(0, "default")).to eq("gpt-4")
      expect(policy.model_for_attempt(1, "default")).to eq("gpt-4-turbo")
    end

    it "freezes the internal models array" do
      policy = RubyLLM::Contract::Step::RetryPolicy.new(models: %w[gpt-4 gpt-4-turbo])
      expect(policy.model_list).to be_frozen
    end
  end

  # ---------------------------------------------------------------------------
  # BUG 5: Pipeline::Base.steps returns the internal mutable array.
  # External code can inject steps into a pipeline.
  # ---------------------------------------------------------------------------
  describe "BUG 5 (FIXED): Pipeline.steps returns frozen array" do
    it "does not allow external code to push steps onto the internal array" do
      dummy_step = Class.new(RubyLLM::Contract::Step::Base) { prompt { user "{input}" } }

      pipeline = Class.new(RubyLLM::Contract::Pipeline::Base)
      pipeline.step(dummy_step, as: :first)

      expect { pipeline.steps.push({ step_class: dummy_step, alias: :injected, depends_on: nil, model: nil }) }
        .to raise_error(FrozenError)
    end
  end

  # ---------------------------------------------------------------------------
  # BUG 8: SchemaValidator skipped nested object validation entirely.
  # Only top-level properties were checked.
  #
  # Fix: Recursive validation of nested objects and array items.
  # ---------------------------------------------------------------------------
  describe "BUG 8: SchemaValidator validates nested object properties" do
    let(:schema_obj) { double("schema") }

    before do
      allow(schema_obj).to receive(:respond_to?).with(:to_json_schema).and_return(true)
    end

    it "catches invalid enum in nested object" do
      allow(schema_obj).to receive(:to_json_schema).and_return({
        schema: {
          type: "object",
          required: ["address"],
          properties: {
            address: {
              type: "object",
              required: ["city", "zip"],
              properties: {
                city: { type: "string" },
                zip: { type: "string", enum: ["10001", "10002", "10003"] }
              }
            }
          }
        }
      })

      errors = RubyLLM::Contract::SchemaValidator.validate(
        { address: { city: "NYC", zip: "INVALID" } }, schema_obj
      )

      expect(errors).not_to be_empty
      expect(errors.first).to include("zip")
      expect(errors.first).to include("INVALID")
    end

    it "catches missing required field in nested object" do
      allow(schema_obj).to receive(:to_json_schema).and_return({
        schema: {
          type: "object",
          properties: {
            address: {
              type: "object",
              required: ["city", "zip"],
              properties: {
                city: { type: "string" },
                zip: { type: "string" }
              }
            }
          }
        }
      })

      errors = RubyLLM::Contract::SchemaValidator.validate(
        { address: { city: "NYC" } }, schema_obj
      )

      expect(errors).not_to be_empty
      expect(errors.first).to include("address.zip")
    end

    it "validates array items against nested schema" do
      allow(schema_obj).to receive(:to_json_schema).and_return({
        schema: {
          type: "object",
          properties: {
            items: {
              type: "array",
              items: {
                type: "object",
                required: ["name"],
                properties: {
                  name: { type: "string" },
                  score: { type: "integer", minimum: 0, maximum: 100 }
                }
              }
            }
          }
        }
      })

      errors = RubyLLM::Contract::SchemaValidator.validate(
        { items: [{ name: "Alice", score: 95 }, { score: 150 }] }, schema_obj
      )

      expect(errors.length).to be >= 2
      expect(errors.any? { |e| e.include?("name") }).to eq(true),
        "Expected a missing-name error for items[1], got: #{errors.inspect}"
      expect(errors.any? { |e| e.include?("150") && e.include?("maximum") }).to eq(true),
        "Expected a maximum violation for score 150, got: #{errors.inspect}"
    end
  end
end
