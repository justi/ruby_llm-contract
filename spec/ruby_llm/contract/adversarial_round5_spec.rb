# frozen_string_literal: true

# Adversarial QA round 5 -- regression tests for deep production-scenario bugs.
# Rounds 1-4 found 24 bugs total (BUGs 1-30, with some meta/combination tests);
# these are NEW bugs that earlier rounds missed.
# Each describe block covers a specific bug, its fix, and regression guard.

RSpec.describe "Adversarial QA round 5 -- bug regressions" do
  before { RubyLLM::Contract.reset_configuration! }

  # ---------------------------------------------------------------------------
  # BUG 31: SchemaValidator does not enforce additionalProperties: false.
  #
  # When a JSON Schema specifies additionalProperties: false, any keys in the
  # output that are NOT listed in `properties` should be rejected. The current
  # SchemaValidator only checks required fields, type, enum, number range,
  # string length, and nested structures -- but it never looks at the
  # additionalProperties constraint. This means an LLM can return extra fields
  # that pollute downstream processing, violate data contracts, or leak
  # sensitive information through unexpected keys.
  #
  # Fix: Add check_additional_properties in validate_object that rejects
  # any keys not present in the properties map when additionalProperties is
  # explicitly false.
  # ---------------------------------------------------------------------------
  describe "BUG 31: SchemaValidator does not enforce additionalProperties: false" do
    it "rejects extra keys when additionalProperties: false" do
      schema = Class.new do
        def to_json_schema
          {
            schema: {
              type: "object",
              properties: {
                name: { type: "string" }
              },
              required: ["name"],
              additionalProperties: false
            }
          }
        end
      end

      errors = RubyLLM::Contract::SchemaValidator.validate(
        { name: "Alice", extra_field: "should be rejected", another: 42 },
        schema.new
      )

      expect(errors).not_to be_empty,
                            "Extra keys should be rejected when additionalProperties: false"
      expect(errors.join).to match(/extra_field/)
      expect(errors.join).to match(/another/)
    end

    it "allows extra keys when additionalProperties is not set (default)" do
      schema = Class.new do
        def to_json_schema
          {
            schema: {
              type: "object",
              properties: {
                name: { type: "string" }
              },
              required: ["name"]
            }
          }
        end
      end

      errors = RubyLLM::Contract::SchemaValidator.validate(
        { name: "Alice", extra_field: "allowed" },
        schema.new
      )

      expect(errors).to be_empty,
                        "Extra keys should be allowed when additionalProperties is not set"
    end

    it "allows extra keys when additionalProperties: true" do
      schema = Class.new do
        def to_json_schema
          {
            schema: {
              type: "object",
              properties: {
                name: { type: "string" }
              },
              additionalProperties: true
            }
          }
        end
      end

      errors = RubyLLM::Contract::SchemaValidator.validate(
        { name: "Alice", extra: "allowed" },
        schema.new
      )

      expect(errors).to be_empty,
                        "Extra keys should be allowed when additionalProperties: true"
    end

    it "enforces additionalProperties: false on nested objects" do
      schema = Class.new do
        def to_json_schema
          {
            schema: {
              type: "object",
              properties: {
                profile: {
                  type: "object",
                  properties: {
                    name: { type: "string" }
                  },
                  additionalProperties: false
                }
              }
            }
          }
        end
      end

      errors = RubyLLM::Contract::SchemaValidator.validate(
        { profile: { name: "Alice", secret: "leaked" } },
        schema.new
      )

      expect(errors).not_to be_empty,
                            "Extra keys in nested objects should be rejected"
      expect(errors.join).to match(/secret/)
    end

    it "enforces additionalProperties: false on objects inside arrays" do
      schema = Class.new do
        def to_json_schema
          {
            schema: {
              type: "object",
              properties: {
                items: {
                  type: "array",
                  items: {
                    type: "object",
                    properties: {
                      id: { type: "integer" }
                    },
                    additionalProperties: false
                  }
                }
              }
            }
          }
        end
      end

      errors = RubyLLM::Contract::SchemaValidator.validate(
        { items: [{ id: 1, leaked: true }] },
        schema.new
      )

      expect(errors).not_to be_empty,
                            "Extra keys in array item objects should be rejected"
      expect(errors.join).to match(/leaked/)
    end
  end

  # ---------------------------------------------------------------------------
  # BUG 32: Parser cannot extract JSON from common LLM prose-wrapped responses.
  #
  # LLMs frequently wrap JSON output in conversational prose, such as:
  #   "Here is the JSON:\n{\"key\": \"value\"}"
  #   "{\"key\": \"value\"}\n\nI hope this helps!"
  #   "json\n{\"key\": \"value\"}"
  #
  # The current parser only strips markdown code fences (``` blocks) and BOM.
  # When the LLM omits code fences and just wraps JSON in prose, the parser
  # raises a ParseError. This is one of the most common failure modes in
  # production -- a valid JSON response is embedded in the text but the parser
  # cannot find it.
  #
  # Fix: After strip_code_fences and strip_bom, if JSON.parse fails, attempt
  # to extract the first JSON object or array from the text using a regex
  # fallback before raising ParseError.
  # ---------------------------------------------------------------------------
  describe "BUG 32: Parser cannot extract JSON from prose-wrapped LLM responses" do
    it "extracts JSON object preceded by prose" do
      text = "Here is the JSON:\n{\"name\": \"Alice\"}"

      result = RubyLLM::Contract::Parser.parse(text, strategy: :json)

      expect(result).to eq({ name: "Alice" }),
                          "Parser should extract JSON from prose prefix"
    end

    it "extracts JSON object followed by prose" do
      text = "{\"name\": \"Bob\"}\n\nI hope this helps!"

      result = RubyLLM::Contract::Parser.parse(text, strategy: :json)

      expect(result).to eq({ name: "Bob" }),
                          "Parser should extract JSON ignoring trailing prose"
    end

    it "extracts JSON object surrounded by prose" do
      text = "Sure! Here you go:\n\n{\"count\": 42}\n\nLet me know if you need more."

      result = RubyLLM::Contract::Parser.parse(text, strategy: :json)

      expect(result).to eq({ count: 42 }),
                          "Parser should extract JSON from surrounding prose"
    end

    it "extracts JSON array from prose" do
      text = "Here are the items:\n[{\"id\": 1}, {\"id\": 2}]"

      result = RubyLLM::Contract::Parser.parse(text, strategy: :json)

      expect(result).to eq([{ id: 1 }, { id: 2 }]),
                          "Parser should extract JSON array from prose"
    end

    it "extracts JSON from 'json' prefix without backticks" do
      text = "json\n{\"status\": \"ok\"}"

      result = RubyLLM::Contract::Parser.parse(text, strategy: :json)

      expect(result).to eq({ status: "ok" }),
                          "Parser should handle 'json' prefix without backticks"
    end

    it "still raises ParseError when no valid JSON is present" do
      text = "I cannot generate JSON for that request."

      expect {
        RubyLLM::Contract::Parser.parse(text, strategy: :json)
      }.to raise_error(RubyLLM::Contract::ParseError)
    end

    it "prefers direct parse over extraction for clean JSON" do
      text = '{"name": "Direct"}'

      result = RubyLLM::Contract::Parser.parse(text, strategy: :json)

      expect(result).to eq({ name: "Direct" })
    end

    it "works end-to-end: step with prose-wrapped JSON response" do
      step = Class.new(RubyLLM::Contract::Step::Base) do
        prompt { user "{input}" }
        output_type RubyLLM::Contract::Types::Hash
        contract { parse :json }
      end

      adapter = RubyLLM::Contract::Adapters::Test.new(
        response: "Here is the result:\n{\"status\": \"complete\", \"count\": 5}"
      )
      result = step.run("test", context: { adapter: adapter })

      expect(result.status).to eq(:ok),
                               "Prose-wrapped JSON should parse successfully, not: #{result.status} " \
                               "-- #{result.validation_errors}"
      expect(result.parsed_output[:status]).to eq("complete")
      expect(result.parsed_output[:count]).to eq(5)
    end
  end

  # ---------------------------------------------------------------------------
  # BUG 33: Pipeline step_results inner hashes are not frozen.
  #
  # Pipeline::Result freezes the step_results array with .freeze (shallow),
  # but the individual hash entries ({ alias: ..., result: ... }) inside
  # the array are NOT frozen. This means external code (middleware, logging,
  # plugins) can:
  #   - Mutate the :alias key to hijack step identity
  #   - Inject arbitrary keys into step result hashes
  #   - Corrupt the immutability guarantee of Result objects
  #
  # The Pipeline::Result is supposed to be immutable (it calls freeze on
  # itself), but the step_results leak mutable references.
  #
  # Fix: Deep-freeze the step_results array by freezing each inner hash
  # before freezing the outer array.
  # ---------------------------------------------------------------------------
  describe "BUG 33: Pipeline step_results inner hashes are not frozen" do
    it "prevents mutation of step result alias" do
      step = Class.new(RubyLLM::Contract::Step::Base) do
        prompt { user "{input}" }
        output_type RubyLLM::Contract::Types::Hash
        contract { parse :json }
      end

      pipeline = Class.new(RubyLLM::Contract::Pipeline::Base) do
        step step, as: :analyze
      end

      adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"result": "ok"}')
      result = pipeline.run("test", context: { adapter: adapter })

      expect {
        result.step_results[0][:alias] = "hijacked"
      }.to raise_error(FrozenError),
           "Step result inner hashes should be frozen to prevent alias mutation"
    end

    it "prevents injection of arbitrary keys into step results" do
      step = Class.new(RubyLLM::Contract::Step::Base) do
        prompt { user "{input}" }
        output_type RubyLLM::Contract::Types::Hash
        contract { parse :json }
      end

      pipeline = Class.new(RubyLLM::Contract::Pipeline::Base) do
        step step, as: :analyze
      end

      adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"result": "ok"}')
      result = pipeline.run("test", context: { adapter: adapter })

      expect {
        result.step_results[0][:injected] = "malicious"
      }.to raise_error(FrozenError),
           "Step result inner hashes should be frozen to prevent key injection"
    end
  end

  # ---------------------------------------------------------------------------
  # BUG 34: Trace#[] leaks internal state via Object methods.
  #
  # The Trace#[] method uses public_send(key) to look up values, rescuing
  # NoMethodError and returning nil for unknown keys. The problem is that
  # public_send dispatches to ANY public method on the object, including
  # methods inherited from Object/Kernel:
  #
  #   trace[:class]              => RubyLLM::Contract::Step::Trace
  #   trace[:object_id]          => 1234 (internal Ruby object ID)
  #   trace[:instance_variables] => [:@messages, :@model, ...] (all ivars)
  #   trace[:freeze]             => the trace object itself
  #   trace[:hash]               => internal hash value
  #
  # This is an information leakage bug. The [] accessor should only return
  # values for the defined trace attributes (messages, model, latency_ms,
  # usage, attempts, cost), consistent with what key?() reports.
  #
  # Fix: Guard Trace#[] to only dispatch to the known attribute keys, and
  # return nil for anything else.
  # ---------------------------------------------------------------------------
  describe "BUG 34: Trace#[] leaks internal state via Object methods" do
    let(:trace) { RubyLLM::Contract::Step::Trace.new(model: "test-model", usage: { input_tokens: 10, output_tokens: 5 }) }

    it "returns nil for :class instead of leaking the class constant" do
      expect(trace[:class]).to be_nil,
                               "trace[:class] should return nil, not leak #{trace[:class].inspect}"
    end

    it "returns nil for :object_id instead of leaking internal ID" do
      expect(trace[:object_id]).to be_nil,
                                   "trace[:object_id] should return nil, not leak #{trace[:object_id].inspect}"
    end

    it "returns nil for :instance_variables instead of leaking ivar names" do
      expect(trace[:instance_variables]).to be_nil,
                                            "trace[:instance_variables] should return nil, not leak internal state"
    end

    it "returns nil for :freeze instead of returning the object itself" do
      # We cannot check the actual return value of :freeze because the object is already frozen,
      # so just verify it does not return a truthy Trace object
      result = trace[:freeze]
      expect(result).to be_nil,
                        "trace[:freeze] should return nil, not the trace object"
    end

    it "still returns correct values for known attributes" do
      expect(trace[:model]).to eq("test-model")
      expect(trace[:usage]).to eq({ input_tokens: 10, output_tokens: 5 })
      expect(trace[:messages]).to be_nil  # nil because not set
      expect(trace[:latency_ms]).to be_nil
      expect(trace[:attempts]).to be_nil
      # cost is nil because no RubyLLM pricing data
    end

    it "is consistent with key? for all lookups" do
      dangerous_keys = %i[class object_id instance_variables freeze hash send
                          respond_to? nil? is_a? equal? inspect to_s]

      dangerous_keys.each do |key|
        expect(trace.key?(key)).to be(false),
                                   "key?(#{key.inspect}) should be false"
        expect(trace[key]).to be_nil,
                              "trace[#{key.inspect}] should be nil, got #{trace[key].inspect}"
      end
    end
  end

  # ---------------------------------------------------------------------------
  # BUG 34b: Pipeline::Trace#[] has the same Object method leak as Step::Trace.
  #
  # Same bug pattern, different class.
  # ---------------------------------------------------------------------------
  describe "BUG 34b: Pipeline::Trace#[] has the same Object method leak" do
    let(:trace) { RubyLLM::Contract::Pipeline::Trace.new(trace_id: "abc-123") }

    it "returns nil for :class" do
      expect(trace[:class]).to be_nil,
                               "Pipeline trace[:class] should return nil"
    end

    it "returns nil for :object_id" do
      expect(trace[:object_id]).to be_nil,
                                   "Pipeline trace[:object_id] should return nil"
    end

    it "returns nil for :instance_variables" do
      expect(trace[:instance_variables]).to be_nil,
                                            "Pipeline trace[:instance_variables] should return nil"
    end

    it "still returns correct values for known attributes" do
      expect(trace[:trace_id]).to eq("abc-123")
      expect(trace[:total_latency_ms]).to be_nil
    end
  end
end
