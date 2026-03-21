# frozen_string_literal: true

# Adversarial QA round 4 -- regression tests for combination and production-scenario bugs.
# Rounds 1-3 found 22 bugs total; these are NEW bugs that earlier rounds missed.
# Each describe block covers a specific bug, its fix, and regression guard.

RSpec.describe "Adversarial QA round 4 -- bug regressions" do
  before { RubyLLM::Contract.reset_configuration! }

  # ---------------------------------------------------------------------------
  # BUG 23: SchemaValidator ignores minLength/maxLength on string items inside
  # arrays.
  #
  # The check_array_items method has two branches: one for object items (which
  # calls validate_object for full recursive validation) and an else branch for
  # all other types. The else branch calls check_type, check_enum, and
  # check_number_range, but does NOT call check_string_length. So if the
  # items schema specifies minLength: 5 and an array item is "ab" (length 2),
  # the violation is silently ignored.
  #
  # Fix: Add check_string_length call in the else branch of check_array_items.
  # ---------------------------------------------------------------------------
  describe "BUG 23: SchemaValidator ignores minLength/maxLength on array string items" do
    it "rejects string array items shorter than minLength" do
      schema = Class.new do
        def to_json_schema
          {
            schema: {
              type: "object",
              properties: {
                tags: {
                  type: "array",
                  items: { type: "string", minLength: 3 }
                }
              }
            }
          }
        end
      end

      errors = RubyLLM::Contract::SchemaValidator.validate(
        { tags: ["ab"] },
        schema.new
      )

      expect(errors).not_to be_empty,
                            "String array item 'ab' (length 2) should fail minLength: 3"
      expect(errors.join).to match(/minLength/i)
    end

    it "rejects string array items longer than maxLength" do
      schema = Class.new do
        def to_json_schema
          {
            schema: {
              type: "object",
              properties: {
                codes: {
                  type: "array",
                  items: { type: "string", maxLength: 3 }
                }
              }
            }
          }
        end
      end

      errors = RubyLLM::Contract::SchemaValidator.validate(
        { codes: ["ABCDE"] },
        schema.new
      )

      expect(errors).not_to be_empty,
                            "String array item 'ABCDE' (length 5) should fail maxLength: 3"
      expect(errors.join).to match(/maxLength/i)
    end

    it "accepts string array items within length bounds" do
      schema = Class.new do
        def to_json_schema
          {
            schema: {
              type: "object",
              properties: {
                tags: {
                  type: "array",
                  items: { type: "string", minLength: 2, maxLength: 10 }
                }
              }
            }
          }
        end
      end

      errors = RubyLLM::Contract::SchemaValidator.validate(
        { tags: %w[hello world] },
        schema.new
      )

      expect(errors).to be_empty,
                        "String items within bounds should pass: #{errors.inspect}"
    end
  end

  # ---------------------------------------------------------------------------
  # BUG 26: Test adapter response:/responses: inconsistency for Array values.
  #
  # Same class of bug as BUG 7 (Hash inconsistency, fixed in round 1) but
  # for Arrays. When using response: [1,2,3], the Array is stored raw. When
  # using responses: [[1,2,3]], normalize_response calls .to_s on the inner
  # Array, producing the String "[1, 2, 3]" (Ruby's Array#to_s). This means
  # the same Array value produces different content types depending on the
  # constructor form.
  #
  # Fix: normalize_response should preserve Array values the same way it
  # preserves Hash values.
  # ---------------------------------------------------------------------------
  describe "BUG 26: Test adapter response:/responses: inconsistency for Arrays" do
    it "produces same content type regardless of constructor form" do
      adapter_single = RubyLLM::Contract::Adapters::Test.new(response: [1, 2, 3])
      adapter_multi = RubyLLM::Contract::Adapters::Test.new(responses: [[1, 2, 3]])

      r1 = adapter_single.call(messages: [])
      r2 = adapter_multi.call(messages: [])

      expect(r1.content.class).to eq(r2.content.class),
                                  "response: Array (#{r1.content.class}) and " \
                                  "responses: [Array] (#{r2.content.class}) should produce same type"
    end

    it "preserves Array as Array in responses: form" do
      adapter = RubyLLM::Contract::Adapters::Test.new(responses: [[1, 2, 3]])
      response = adapter.call(messages: [])

      expect(response.content).to be_an(Array),
                                  "Array in responses: should stay as Array, " \
                                  "got #{response.content.class}: #{response.content.inspect}"
    end
  end

  # ---------------------------------------------------------------------------
  # BUG 29: SchemaValidator does not validate enum on string items inside
  # arrays.
  #
  # While check_array_items DOES call check_enum for non-object items, it
  # is worth confirming this works correctly in combination with other
  # constraints (since bugs 23 and 24 showed missing validations in the same
  # code path). This test confirms enum works AND validates that the
  # combination of enum + minLength is handled correctly on array items.
  #
  # NOTE: This is a combination test, not a standalone bug. The enum check
  # works, but in combination with the missing check_string_length (BUG 23),
  # array item constraints were not fully validated.
  # ---------------------------------------------------------------------------
  describe "Combination: schema + retry + validate all at once" do
    it "validates schema, runs invariants, and retries on failure" do
      step = Class.new(RubyLLM::Contract::Step::Base) do
        input_type String
        output_type RubyLLM::Contract::Types::Hash
        prompt { |input| user "Analyze: #{input}" }

        output_schema do
          string :summary, required: true
          integer :score, required: true
        end

        contract do
          parse :json
          invariant("score in range") { |o| o[:score].is_a?(Integer) && o[:score].between?(0, 100) }
        end

        validate("summary not empty") { |o| o[:summary].is_a?(String) && !o[:summary].empty? }

        retry_policy attempts: 2, retry_on: %i[validation_failed parse_error]
      end

      # First response fails invariant (score out of range), second succeeds
      call_count = 0
      adapter = Class.new(RubyLLM::Contract::Adapters::Base) do
        define_method(:call) do |**_opts|
          call_count += 1
          content = if call_count == 1
                      { "summary" => "Analysis", "score" => 150 }
                    else
                      { "summary" => "Good analysis", "score" => 85 }
                    end
          RubyLLM::Contract::Adapters::Response.new(
            content: content,
            usage: { input_tokens: 50, output_tokens: 30 }
          )
        end
      end.new

      result = step.run("test data", context: { adapter: adapter })

      expect(result.status).to eq(:ok),
                               "Retry should recover from invariant failure. " \
                               "Got #{result.status}: #{result.validation_errors}"
      expect(call_count).to eq(2)
      expect(result.parsed_output[:score]).to eq(85)
    end
  end

  # ---------------------------------------------------------------------------
  # BUG 30: Three-level deep schema nesting (object > array > object) --
  # validate required fields and enum constraints at the deepest level.
  #
  # This is a combination test that verifies the recursive validation works
  # at 3 levels deep, specifically checking that required fields AND enum
  # constraints are properly enforced on objects nested inside arrays nested
  # inside objects.
  # ---------------------------------------------------------------------------
  describe "BUG 30: Three-level deep schema validation" do
    let(:deep_schema) do
      Class.new do
        def to_json_schema
          {
            schema: {
              type: "object",
              required: ["departments"],
              properties: {
                departments: {
                  type: "array",
                  items: {
                    type: "object",
                    required: %w[name employees],
                    properties: {
                      name: { type: "string" },
                      employees: {
                        type: "array",
                        items: {
                          type: "object",
                          required: %w[name role],
                          properties: {
                            name: { type: "string", minLength: 2 },
                            role: { type: "string", enum: %w[engineer manager director] }
                          }
                        }
                      }
                    }
                  }
                }
              }
            }
          }
        end
      end
    end

    it "accepts valid 3-level deep structure" do
      data = {
        departments: [
          {
            name: "Engineering",
            employees: [
              { name: "Alice", role: "engineer" },
              { name: "Bob", role: "manager" }
            ]
          }
        ]
      }

      errors = RubyLLM::Contract::SchemaValidator.validate(data, deep_schema.new)
      expect(errors).to be_empty, "Valid 3-level deep structure should pass: #{errors.inspect}"
    end

    it "catches invalid enum at 3rd level" do
      data = {
        departments: [
          {
            name: "Engineering",
            employees: [
              { name: "Alice", role: "intern" }
            ]
          }
        ]
      }

      errors = RubyLLM::Contract::SchemaValidator.validate(data, deep_schema.new)
      expect(errors).not_to be_empty,
                            "Invalid enum 'intern' at 3rd level should be caught"
      expect(errors.join).to match(/role/)
      expect(errors.join).to match(/intern/)
    end

    it "catches missing required field at 3rd level" do
      data = {
        departments: [
          {
            name: "Engineering",
            employees: [
              { name: "Alice" }
            ]
          }
        ]
      }

      errors = RubyLLM::Contract::SchemaValidator.validate(data, deep_schema.new)
      expect(errors).not_to be_empty,
                            "Missing required 'role' at 3rd level should be caught"
      expect(errors.join).to match(/role/)
    end
  end
end
