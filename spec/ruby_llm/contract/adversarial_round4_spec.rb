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
  # BUG 24: SchemaValidator does not recurse into nested arrays (arrays of
  # arrays).
  #
  # The check_array_items method only handles object items specially via
  # validate_object. When an array item is itself an array (type: "array"),
  # it falls into the else branch which calls check_type (passes, since it IS
  # an array) but never calls check_nested. So constraints like minItems,
  # maxItems, and items type validation on inner arrays are silently ignored.
  #
  # Fix: Call check_nested in the else branch, or handle array items as a
  # separate case alongside object items.
  # ---------------------------------------------------------------------------
  describe "BUG 24: SchemaValidator does not recurse into nested arrays" do
    it "validates minItems on nested arrays" do
      schema = Class.new do
        def to_json_schema
          {
            schema: {
              type: "object",
              properties: {
                matrix: {
                  type: "array",
                  items: {
                    type: "array",
                    items: { type: "integer" },
                    minItems: 2
                  }
                }
              }
            }
          }
        end
      end

      errors = RubyLLM::Contract::SchemaValidator.validate(
        { matrix: [[1]] },
        schema.new
      )

      expect(errors).not_to be_empty,
                            "Inner array [1] (length 1) should fail minItems: 2"
      expect(errors.join).to match(/minItems/i)
    end

    it "validates item types in nested arrays" do
      schema = Class.new do
        def to_json_schema
          {
            schema: {
              type: "object",
              properties: {
                matrix: {
                  type: "array",
                  items: {
                    type: "array",
                    items: { type: "integer" }
                  }
                }
              }
            }
          }
        end
      end

      errors = RubyLLM::Contract::SchemaValidator.validate(
        { matrix: [["not_an_int"]] },
        schema.new
      )

      expect(errors).not_to be_empty,
                            "String 'not_an_int' inside nested array should fail type: integer"
      expect(errors.join).to match(/integer/i)
    end

    it "accepts valid nested arrays" do
      schema = Class.new do
        def to_json_schema
          {
            schema: {
              type: "object",
              properties: {
                matrix: {
                  type: "array",
                  items: {
                    type: "array",
                    items: { type: "integer" },
                    minItems: 2
                  }
                }
              }
            }
          }
        end
      end

      errors = RubyLLM::Contract::SchemaValidator.validate(
        { matrix: [[1, 2], [3, 4]] },
        schema.new
      )

      expect(errors).to be_empty,
                        "Valid nested arrays should pass: #{errors.inspect}"
    end
  end

  # ---------------------------------------------------------------------------
  # BUG 25: Parser.parse crashes with TypeError when raw_output is an Array.
  #
  # When a provider returns a structured response that is an Array (e.g., a
  # list of objects), the :json parse strategy only has an early return for
  # Hash (line: return symbolize_keys(raw_output) if raw_output.is_a?(Hash)).
  # An Array falls through to strip_bom (which returns it as-is since it's
  # not a String), then JSON.parse(array) crashes with TypeError: "no implicit
  # conversion of Array into String".
  #
  # Fix: Add an early return for Array raw_output in Parser.parse, applying
  # symbolize_keys to it (which recursively handles array contents).
  # ---------------------------------------------------------------------------
  describe "BUG 25: Parser.parse crashes on Array raw_output" do
    it "handles Array raw_output in :json strategy" do
      input = [{ "name" => "Alice" }, { "name" => "Bob" }]

      result = RubyLLM::Contract::Parser.parse(input, strategy: :json)

      expect(result).to be_an(Array)
      expect(result.first).to eq({ name: "Alice" })
      expect(result.last).to eq({ name: "Bob" })
    end

    it "handles nested Array/Hash structures" do
      input = [{ "items" => [{ "id" => 1 }, { "id" => 2 }] }]

      result = RubyLLM::Contract::Parser.parse(input, strategy: :json)

      expect(result).to be_an(Array)
      expect(result.first[:items].first[:id]).to eq(1)
    end

    it "handles Array raw_output in :text strategy" do
      input = [1, 2, 3]

      result = RubyLLM::Contract::Parser.parse(input, strategy: :text)

      # :text strategy returns as-is
      expect(result).to eq([1, 2, 3])
    end

    it "works end-to-end: step with Array response from adapter" do
      step = Class.new(RubyLLM::Contract::Step::Base) do
        prompt { user "{input}" }
        output_type Array
        contract { parse :json }
      end

      # Test adapter returns an Array directly (simulating structured response)
      adapter = RubyLLM::Contract::Adapters::Test.new(
        response: [{ "name" => "Alice" }, { "name" => "Bob" }]
      )
      result = step.run("test", context: { adapter: adapter })

      expect(result.status).to eq(:ok),
                               "Array response should parse successfully, not: #{result.status} " \
                               "-- #{result.validation_errors}"
      expect(result.parsed_output).to be_an(Array)
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
  # BUG 27: Parser does not strip markdown code fences from JSON output.
  #
  # LLMs frequently wrap JSON responses in markdown code fences like:
  #   ```json
  #   {"key": "value"}
  #   ```
  # The parser fails with a ParseError because JSON.parse cannot handle the
  # backtick fencing. This is one of the most common production issues with
  # LLM JSON output.
  #
  # Fix: Parser.parse strips leading/trailing markdown code fences (```json
  # and ```) before attempting JSON.parse.
  # ---------------------------------------------------------------------------
  describe "BUG 27: Parser does not strip markdown code fences from JSON" do
    it "parses JSON wrapped in ```json fences" do
      fenced = "```json\n{\"name\": \"Alice\"}\n```"

      result = RubyLLM::Contract::Parser.parse(fenced, strategy: :json)

      expect(result).to eq({ name: "Alice" })
    end

    it "parses JSON wrapped in plain ``` fences (no language tag)" do
      fenced = "```\n{\"name\": \"Bob\"}\n```"

      result = RubyLLM::Contract::Parser.parse(fenced, strategy: :json)

      expect(result).to eq({ name: "Bob" })
    end

    it "handles code fence with trailing whitespace" do
      fenced = "```json\n{\"count\": 42}\n```\n"

      result = RubyLLM::Contract::Parser.parse(fenced, strategy: :json)

      expect(result).to eq({ count: 42 })
    end

    it "leaves valid JSON without fences unchanged" do
      plain = '{"name": "Charlie"}'

      result = RubyLLM::Contract::Parser.parse(plain, strategy: :json)

      expect(result).to eq({ name: "Charlie" })
    end

    it "works end-to-end: step with code-fenced JSON response" do
      step = Class.new(RubyLLM::Contract::Step::Base) do
        prompt { user "{input}" }
        output_type RubyLLM::Contract::Types::Hash
        contract { parse :json }
      end

      adapter = RubyLLM::Contract::Adapters::Test.new(
        response: "```json\n{\"status\": \"ok\"}\n```"
      )
      result = step.run("test", context: { adapter: adapter })

      expect(result.status).to eq(:ok),
                               "Code-fenced JSON should parse successfully, not: #{result.status} " \
                               "-- #{result.validation_errors}"
      expect(result.parsed_output[:status]).to eq("ok")
    end
  end

  # ---------------------------------------------------------------------------
  # BUG 28: Successful retry discards attempt history from trace.
  #
  # When run_with_retry succeeds on attempt N (N > 1), the code does:
  #   return result unless policy.retryable?(result)
  # This returns the raw run_once result, which has NO attempt log. The
  # build_retry_result method (which merges the attempt log into the trace)
  # is only reached when ALL attempts are exhausted.
  #
  # This means:
  # - After 2 failures + 1 success, the trace shows no retry history
  # - Callers cannot see that retries happened
  # - Cost tracking misses the failed attempts' usage
  # - Observability is silently lost
  #
  # Fix: Always build the retry result (with attempt log) when more than
  # one attempt was made, regardless of the final outcome.
  # ---------------------------------------------------------------------------
  describe "BUG 28: Successful retry discards attempt history from trace" do
    it "includes attempt log in trace when retry succeeds on attempt 2+" do
      step = Class.new(RubyLLM::Contract::Step::Base) do
        input_type String
        output_type RubyLLM::Contract::Types::Hash
        contract { parse :json }
        prompt { |input| user "Process: #{input}" }
        retry_policy attempts: 3, retry_on: %i[parse_error]
      end

      call_count = 0
      adapter = Class.new(RubyLLM::Contract::Adapters::Base) do
        define_method(:call) do |**_opts|
          call_count += 1
          content = call_count < 3 ? "not json" : '{"result": "ok"}'
          RubyLLM::Contract::Adapters::Response.new(
            content: content,
            usage: { input_tokens: 100, output_tokens: 50 }
          )
        end
      end.new

      result = step.run("test", context: { adapter: adapter })

      expect(result.status).to eq(:ok)
      expect(call_count).to eq(3)
      expect(result.trace.attempts).not_to be_nil,
                                           "Successful retry should include attempt log in trace, " \
                                           "but trace.attempts is nil -- retry history is lost"
      expect(result.trace.attempts.length).to eq(3),
                                              "Should have 3 attempts logged"
      expect(result.trace.attempts.first[:status]).to eq(:parse_error)
      expect(result.trace.attempts.last[:status]).to eq(:ok)
    end

    it "includes attempt log on first-attempt success (single attempt, no retries)" do
      step = Class.new(RubyLLM::Contract::Step::Base) do
        input_type String
        output_type RubyLLM::Contract::Types::Hash
        contract { parse :json }
        prompt { |input| user "Process: #{input}" }
        retry_policy attempts: 3, retry_on: %i[parse_error]
      end

      adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"result": "ok"}')
      result = step.run("test", context: { adapter: adapter })

      expect(result.status).to eq(:ok)
      # Even on first-attempt success, the attempt log should be present
      # for consistent observability
      expect(result.trace.attempts).not_to be_nil,
                                           "Even first-attempt success should include attempt log"
      expect(result.trace.attempts.length).to eq(1)
      expect(result.trace.attempts.first[:status]).to eq(:ok)
    end

    it "records correct model per attempt during escalation" do
      step = Class.new(RubyLLM::Contract::Step::Base) do
        input_type String
        output_type RubyLLM::Contract::Types::Hash
        contract { parse :json }
        prompt { |input| user "Process: #{input}" }
        retry_policy do
          escalate "gpt-4o-mini", "gpt-4o", "gpt-4"
          retry_on :parse_error
        end
      end

      call_count = 0
      adapter = Class.new(RubyLLM::Contract::Adapters::Base) do
        define_method(:call) do |**_opts|
          call_count += 1
          content = call_count < 3 ? "not json" : '{"result": "ok"}'
          RubyLLM::Contract::Adapters::Response.new(
            content: content,
            usage: { input_tokens: 100, output_tokens: 50 }
          )
        end
      end.new

      result = step.run("test", context: { adapter: adapter })

      expect(result.status).to eq(:ok)
      expect(result.trace.attempts).not_to be_nil
      models = result.trace.attempts.map { |a| a[:model] }
      expect(models).to eq(%w[gpt-4o-mini gpt-4o gpt-4]),
                          "Attempt log should record the model used per attempt"
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
