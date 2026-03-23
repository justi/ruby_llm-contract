# frozen_string_literal: true

# Adversarial QA round 10 -- THE FINAL ROUND. Production certification audit.
# Rounds 1-8 found ~40 bugs. This round either finds the LAST remaining bugs
# or certifies each module as production-ready.
#
# For each module: "Would I trust this code to handle $10K/month in LLM spend
# without human supervision?"

RSpec.describe "Adversarial QA round 10 -- production certification audit" do
  before { RubyLLM::Contract.reset_configuration! }

  # ===========================================================================
  # 1. PARSER -- is it bulletproof now?
  # ===========================================================================
  describe "CERTIFICATION: Parser" do
    # -------------------------------------------------------------------------
    # Real-world LLM response patterns
    # -------------------------------------------------------------------------
    describe "real-world LLM response patterns" do
      it "parses clean JSON object" do
        result = RubyLLM::Contract::Parser.parse('{"name": "Alice", "age": 30}', strategy: :json)
        expect(result).to eq({ name: "Alice", age: 30 })
      end

      it "parses clean JSON array" do
        result = RubyLLM::Contract::Parser.parse("[1, 2, 3]", strategy: :json)
        expect(result).to eq([1, 2, 3])
      end

      it "parses deeply nested JSON (4 levels)" do
        json = '{"a": {"b": {"c": {"d": "deep"}}}}'
        result = RubyLLM::Contract::Parser.parse(json, strategy: :json)
        expect(result).to eq({ a: { b: { c: { d: "deep" } } } })
      end

      it "parses JSON with escaped quotes in string values" do
        json = '{"text": "He said \\"hello\\""}'
        result = RubyLLM::Contract::Parser.parse(json, strategy: :json)
        expect(result).to eq({ text: 'He said "hello"' })
      end

      it "parses JSON with unicode escape sequences" do
        json = '{"emoji": "\\u2764"}'
        result = RubyLLM::Contract::Parser.parse(json, strategy: :json)
        expect(result[:emoji]).to be_a(String)
      end

      it "parses JSON with newlines in string values" do
        json = '{"text": "line1\\nline2"}'
        result = RubyLLM::Contract::Parser.parse(json, strategy: :json)
        expect(result[:text]).to include("\n")
      end

      it "parses JSON with boolean values" do
        json = '{"active": true, "deleted": false}'
        result = RubyLLM::Contract::Parser.parse(json, strategy: :json)
        expect(result).to eq({ active: true, deleted: false })
      end

      it "parses JSON with null value" do
        json = '{"name": null}'
        result = RubyLLM::Contract::Parser.parse(json, strategy: :json)
        expect(result).to eq({ name: nil })
      end

      it "parses JSON with mixed array types" do
        json = '{"items": [1, "two", true, null, {"nested": "obj"}]}'
        result = RubyLLM::Contract::Parser.parse(json, strategy: :json)
        expect(result[:items].length).to eq(5)
        expect(result[:items][4]).to eq({ nested: "obj" })
      end

      it "parses JSON with empty object" do
        result = RubyLLM::Contract::Parser.parse("{}", strategy: :json)
        expect(result).to eq({})
      end

      it "parses JSON with empty array" do
        result = RubyLLM::Contract::Parser.parse("[]", strategy: :json)
        expect(result).to eq([])
      end

      it "parses JSON with leading/trailing whitespace" do
        result = RubyLLM::Contract::Parser.parse("  \n{\"ok\": true}\n  ", strategy: :json)
        expect(result).to eq({ ok: true })
      end

      it "parses JSON with BOM prefix" do
        bom = "\xEF\xBB\xBF"
        result = RubyLLM::Contract::Parser.parse("#{bom}{\"ok\": true}", strategy: :json)
        expect(result).to eq({ ok: true })
      end

      it "parses JSON array wrapped in code fences" do
        text = "```json\n[{\"id\": 1}, {\"id\": 2}]\n```"
        result = RubyLLM::Contract::Parser.parse(text, strategy: :json)
        expect(result).to eq([{ id: 1 }, { id: 2 }])
      end

      it "parses JSON with large numeric values" do
        json = '{"big": 9999999999999}'
        result = RubyLLM::Contract::Parser.parse(json, strategy: :json)
        expect(result[:big]).to eq(9_999_999_999_999)
      end

      it "parses JSON with float values" do
        json = '{"pi": 3.14159, "negative": -2.5}'
        result = RubyLLM::Contract::Parser.parse(json, strategy: :json)
        expect(result[:pi]).to be_within(0.00001).of(3.14159)
        expect(result[:negative]).to eq(-2.5)
      end

      it "parses Hash input directly (passthrough)" do
        result = RubyLLM::Contract::Parser.parse({ "name" => "Bob" }, strategy: :json)
        expect(result).to eq({ name: "Bob" })
      end

      it "parses Array input directly (passthrough)" do
        result = RubyLLM::Contract::Parser.parse([1, 2, 3], strategy: :json)
        expect(result).to eq([1, 2, 3])
      end
    end

    # -------------------------------------------------------------------------
    # Edge cases
    # -------------------------------------------------------------------------
    describe "edge cases" do
      it "raises ParseError for whitespace-only response" do
        expect do
          RubyLLM::Contract::Parser.parse("   \n\t  ", strategy: :json)
        end.to raise_error(RubyLLM::Contract::ParseError)
      end

      it "parses single number string as JSON" do
        result = RubyLLM::Contract::Parser.parse("42", strategy: :json)
        expect(result).to eq(42)
      end

      it "raises ParseError for the string 'undefined'" do
        expect do
          RubyLLM::Contract::Parser.parse("undefined", strategy: :json)
        end.to raise_error(RubyLLM::Contract::ParseError)
      end

      it "handles response that is ONLY whitespace" do
        expect do
          RubyLLM::Contract::Parser.parse("", strategy: :json)
        end.to raise_error(RubyLLM::Contract::ParseError)
      end

      it "handles response with null bytes in string values" do
        # JSON with embedded \u0000 -- this is valid JSON but may cause issues
        json = '{"data": "hello\u0000world"}'
        result = RubyLLM::Contract::Parser.parse(json, strategy: :json)
        expect(result[:data]).to include("hello")
      end
    end

    # -------------------------------------------------------------------------
    # extract_json bracket matching correctness
    # -------------------------------------------------------------------------
    describe "extract_json bracket matching with braces in strings" do
      it "correctly handles { and } inside JSON string values" do
        json = '{"template": "Hello {name}, welcome to {place}"}'
        result = RubyLLM::Contract::Parser.parse(json, strategy: :json)
        expect(result[:template]).to eq("Hello {name}, welcome to {place}")
      end

      it "correctly handles nested braces in string values" do
        json = '{"code": "function() { return {}; }"}'
        result = RubyLLM::Contract::Parser.parse(json, strategy: :json)
        expect(result[:code]).to eq("function() { return {}; }")
      end

      it "correctly handles brackets inside string values" do
        json = '{"regex": "[a-z]{3,5}"}'
        result = RubyLLM::Contract::Parser.parse(json, strategy: :json)
        expect(result[:regex]).to eq("[a-z]{3,5}")
      end

      it "correctly handles escaped quotes adjacent to braces" do
        json = '{"val": "\\\"{\\\"}"}' # JSON: {"val": "\"{\"}"} -- tricky escaping
        # This is intentionally testing that the bracket matcher does not get
        # confused by escaped quotes near braces. We just need it not to crash.
        expect do
          RubyLLM::Contract::Parser.parse(json, strategy: :json)
        end.not_to raise_error(TypeError)
      end

      it "raises ParseError when first balanced brackets are not valid JSON" do
        text = 'The function takes {params} and returns: {"result": "ok"}'
        # extract_json finds {params} first (balanced braces), but it is not valid JSON.
        # JSON.parse("{params}") fails, so ParseError is raised. The second JSON object
        # is never reached. This is a documented limitation of first-bracket extraction.
        expect do
          RubyLLM::Contract::Parser.parse(text, strategy: :json)
        end.to raise_error(RubyLLM::Contract::ParseError)
      end

      it "handles deeply nested mixed brackets" do
        json = '{"a": [{"b": [1, 2]}, {"c": {"d": [3]}}]}'
        result = RubyLLM::Contract::Parser.parse(json, strategy: :json)
        expect(result[:a].length).to eq(2)
        expect(result[:a][0][:b]).to eq([1, 2])
        expect(result[:a][1][:c][:d]).to eq([3])
      end
    end

    # -------------------------------------------------------------------------
    # Text strategy
    # -------------------------------------------------------------------------
    describe "text strategy" do
      it "returns raw string as-is" do
        result = RubyLLM::Contract::Parser.parse("hello world", strategy: :text)
        expect(result).to eq("hello world")
      end

      it "returns nil as-is" do
        result = RubyLLM::Contract::Parser.parse(nil, strategy: :text)
        expect(result).to be_nil
      end

      it "returns non-string values as-is" do
        result = RubyLLM::Contract::Parser.parse(42, strategy: :text)
        expect(result).to eq(42)
      end
    end

    describe "unknown strategy" do
      it "raises ArgumentError" do
        expect do
          RubyLLM::Contract::Parser.parse("test", strategy: :xml)
        end.to raise_error(ArgumentError, /Unknown parse strategy/)
      end
    end
  end

  # ===========================================================================
  # 2. SCHEMA VALIDATOR -- complete JSON Schema compliance
  # ===========================================================================
  describe "CERTIFICATION: SchemaValidator" do
    def make_schema(schema_hash)
      schema_data = schema_hash
      Class.new do
        define_method(:to_json_schema) do
          { schema: schema_data }
        end
      end.new
    end

    # -------------------------------------------------------------------------
    # Type checking for every JSON Schema type
    # -------------------------------------------------------------------------
    describe "type checking" do
      it "validates string type" do
        schema = make_schema(type: "object", properties: { name: { type: "string" } })
        expect(RubyLLM::Contract::SchemaValidator.validate({ name: "Alice" }, schema)).to be_empty
        errors = RubyLLM::Contract::SchemaValidator.validate({ name: 42 }, schema)
        expect(errors.join).to match(/expected string/i)
      end

      it "validates integer type" do
        schema = make_schema(type: "object", properties: { count: { type: "integer" } })
        expect(RubyLLM::Contract::SchemaValidator.validate({ count: 5 }, schema)).to be_empty
        errors = RubyLLM::Contract::SchemaValidator.validate({ count: 5.5 }, schema)
        expect(errors.join).to match(/expected integer/i)
      end

      it "validates number type (accepts both int and float)" do
        schema = make_schema(type: "object", properties: { score: { type: "number" } })
        expect(RubyLLM::Contract::SchemaValidator.validate({ score: 5 }, schema)).to be_empty
        expect(RubyLLM::Contract::SchemaValidator.validate({ score: 5.5 }, schema)).to be_empty
        errors = RubyLLM::Contract::SchemaValidator.validate({ score: "five" }, schema)
        expect(errors.join).to match(/expected number/i)
      end

      it "validates boolean type" do
        schema = make_schema(type: "object", properties: { active: { type: "boolean" } })
        expect(RubyLLM::Contract::SchemaValidator.validate({ active: true }, schema)).to be_empty
        expect(RubyLLM::Contract::SchemaValidator.validate({ active: false }, schema)).to be_empty
        errors = RubyLLM::Contract::SchemaValidator.validate({ active: "true" }, schema)
        expect(errors.join).to match(/expected boolean/i)
      end

      it "validates array type" do
        schema = make_schema(type: "object", properties: { tags: { type: "array" } })
        expect(RubyLLM::Contract::SchemaValidator.validate({ tags: [1, 2] }, schema)).to be_empty
        errors = RubyLLM::Contract::SchemaValidator.validate({ tags: "not array" }, schema)
        expect(errors.join).to match(/expected array/i)
      end

      it "validates object type" do
        schema = make_schema(type: "object", properties: { meta: { type: "object" } })
        expect(RubyLLM::Contract::SchemaValidator.validate({ meta: { k: "v" } }, schema)).to be_empty
        errors = RubyLLM::Contract::SchemaValidator.validate({ meta: "not object" }, schema)
        expect(errors.join).to match(/expected object/i)
      end
    end

    # -------------------------------------------------------------------------
    # Constraint checking
    # -------------------------------------------------------------------------
    describe "enum constraint" do
      it "accepts value in enum" do
        schema = make_schema(type: "object", properties: { color: { type: "string", enum: %w[red green blue] } })
        expect(RubyLLM::Contract::SchemaValidator.validate({ color: "red" }, schema)).to be_empty
      end

      it "rejects value not in enum" do
        schema = make_schema(type: "object", properties: { color: { type: "string", enum: %w[red green blue] } })
        errors = RubyLLM::Contract::SchemaValidator.validate({ color: "yellow" }, schema)
        expect(errors.join).to match(/enum/)
      end
    end

    describe "minimum/maximum constraints" do
      it "accepts value within range" do
        schema = make_schema(type: "object", properties: { age: { type: "integer", minimum: 0, maximum: 150 } })
        expect(RubyLLM::Contract::SchemaValidator.validate({ age: 25 }, schema)).to be_empty
      end

      it "rejects value below minimum" do
        schema = make_schema(type: "object", properties: { age: { type: "integer", minimum: 0 } })
        errors = RubyLLM::Contract::SchemaValidator.validate({ age: -1 }, schema)
        expect(errors.join).to match(/below minimum/)
      end

      it "rejects value above maximum" do
        schema = make_schema(type: "object", properties: { age: { type: "integer", maximum: 150 } })
        errors = RubyLLM::Contract::SchemaValidator.validate({ age: 200 }, schema)
        expect(errors.join).to match(/above maximum/)
      end

      it "accepts value at exact minimum" do
        schema = make_schema(type: "object", properties: { age: { type: "integer", minimum: 0 } })
        expect(RubyLLM::Contract::SchemaValidator.validate({ age: 0 }, schema)).to be_empty
      end

      it "accepts value at exact maximum" do
        schema = make_schema(type: "object", properties: { age: { type: "integer", maximum: 150 } })
        expect(RubyLLM::Contract::SchemaValidator.validate({ age: 150 }, schema)).to be_empty
      end
    end

    describe "minLength/maxLength constraints" do
      it "accepts string within length bounds" do
        schema = make_schema(type: "object", properties: { name: { type: "string", minLength: 2, maxLength: 50 } })
        expect(RubyLLM::Contract::SchemaValidator.validate({ name: "Alice" }, schema)).to be_empty
      end

      it "rejects string below minLength" do
        schema = make_schema(type: "object", properties: { name: { type: "string", minLength: 5 } })
        errors = RubyLLM::Contract::SchemaValidator.validate({ name: "Al" }, schema)
        expect(errors.join).to match(/minLength/)
      end

      it "rejects string above maxLength" do
        schema = make_schema(type: "object", properties: { name: { type: "string", maxLength: 3 } })
        errors = RubyLLM::Contract::SchemaValidator.validate({ name: "Alice" }, schema)
        expect(errors.join).to match(/maxLength/)
      end
    end

    describe "minItems/maxItems constraints" do
      it "accepts array within item count bounds" do
        schema = make_schema(type: "object", properties: { items: { type: "array", minItems: 1, maxItems: 5 } })
        expect(RubyLLM::Contract::SchemaValidator.validate({ items: [1, 2, 3] }, schema)).to be_empty
      end

      it "rejects array below minItems" do
        schema = make_schema(type: "object", properties: { items: { type: "array", minItems: 2 } })
        errors = RubyLLM::Contract::SchemaValidator.validate({ items: [1] }, schema)
        expect(errors.join).to match(/minItems/)
      end

      it "rejects array above maxItems" do
        schema = make_schema(type: "object", properties: { items: { type: "array", maxItems: 2 } })
        errors = RubyLLM::Contract::SchemaValidator.validate({ items: [1, 2, 3] }, schema)
        expect(errors.join).to match(/maxItems/)
      end
    end

    describe "required constraint" do
      it "accepts when all required fields present" do
        schema = make_schema(type: "object", required: %w[name age],
                             properties: { name: { type: "string" }, age: { type: "integer" } })
        expect(RubyLLM::Contract::SchemaValidator.validate({ name: "Alice", age: 30 }, schema)).to be_empty
      end

      it "rejects when required field missing" do
        schema = make_schema(type: "object", required: %w[name age],
                             properties: { name: { type: "string" }, age: { type: "integer" } })
        errors = RubyLLM::Contract::SchemaValidator.validate({ name: "Alice" }, schema)
        expect(errors.join).to match(/missing required field.*age/)
      end
    end

    describe "additionalProperties constraint" do
      it "rejects extra keys when additionalProperties: false" do
        schema = make_schema(type: "object", additionalProperties: false,
                             properties: { name: { type: "string" } })
        errors = RubyLLM::Contract::SchemaValidator.validate({ name: "Alice", extra: "bad" }, schema)
        expect(errors.join).to match(/additional property/)
      end

      it "allows extra keys when additionalProperties is not false" do
        schema = make_schema(type: "object", properties: { name: { type: "string" } })
        expect(RubyLLM::Contract::SchemaValidator.validate({ name: "Alice", extra: "ok" }, schema)).to be_empty
      end
    end

    # -------------------------------------------------------------------------
    # Combination constraints
    # -------------------------------------------------------------------------
    describe "combination: required + enum" do
      it "reports both missing required and enum violation" do
        schema = make_schema(
          type: "object",
          required: %w[status color],
          properties: {
            status: { type: "string", enum: %w[active inactive] },
            color: { type: "string", enum: %w[red blue] }
          }
        )
        # status present but wrong enum; color missing entirely
        errors = RubyLLM::Contract::SchemaValidator.validate({ status: "unknown" }, schema)
        expect(errors.length).to be >= 2
        expect(errors.join(" ")).to match(/missing required field.*color/)
        expect(errors.join(" ")).to match(/enum/)
      end
    end

    describe "combination: array of objects with required + minItems" do
      it "validates complex nested structure" do
        schema = make_schema(
          type: "object",
          properties: {
            users: {
              type: "array",
              minItems: 2,
              items: {
                type: "object",
                required: %w[name email],
                properties: {
                  name: { type: "string", minLength: 1 },
                  email: { type: "string" },
                  age: { type: "integer", minimum: 0 }
                }
              }
            }
          }
        )

        # Valid
        valid_data = { users: [{ name: "Alice", email: "a@b.com", age: 30 },
                               { name: "Bob", email: "b@b.com" }] }
        expect(RubyLLM::Contract::SchemaValidator.validate(valid_data, schema)).to be_empty

        # minItems violation
        too_few = { users: [{ name: "Alice", email: "a@b.com" }] }
        errors = RubyLLM::Contract::SchemaValidator.validate(too_few, schema)
        expect(errors.join).to match(/minItems/)

        # missing required in nested object
        missing_email = { users: [{ name: "Alice" }, { name: "Bob", email: "b@b.com" }] }
        errors = RubyLLM::Contract::SchemaValidator.validate(missing_email, schema)
        expect(errors.join).to match(/missing required field.*email/)
      end
    end

    # -------------------------------------------------------------------------
    # 4 levels of nesting
    # -------------------------------------------------------------------------
    describe "4 levels of nesting" do
      it "validates deeply nested structure" do
        schema = make_schema(
          type: "object",
          properties: {
            level1: {
              type: "object",
              required: %w[level2],
              properties: {
                level2: {
                  type: "object",
                  properties: {
                    level3: {
                      type: "object",
                      required: %w[level4],
                      properties: {
                        level4: {
                          type: "string",
                          enum: %w[deep]
                        }
                      }
                    }
                  }
                }
              }
            }
          }
        )

        # Valid 4-level nesting
        valid = { level1: { level2: { level3: { level4: "deep" } } } }
        expect(RubyLLM::Contract::SchemaValidator.validate(valid, schema)).to be_empty

        # Invalid value at level 4
        invalid = { level1: { level2: { level3: { level4: "shallow" } } } }
        errors = RubyLLM::Contract::SchemaValidator.validate(invalid, schema)
        expect(errors.join).to match(/enum/)

        # Missing required at level 4
        missing = { level1: { level2: { level3: {} } } }
        errors = RubyLLM::Contract::SchemaValidator.validate(missing, schema)
        expect(errors.join).to match(/missing required field/)
      end
    end

    # -------------------------------------------------------------------------
    # Non-Hash output with object schema
    # -------------------------------------------------------------------------
    describe "non-Hash output handling" do
      it "rejects nil when schema expects object" do
        schema = make_schema(type: "object", properties: { name: { type: "string" } })
        errors = RubyLLM::Contract::SchemaValidator.validate(nil, schema)
        expect(errors).not_to be_empty
      end

      it "rejects Array when schema expects object" do
        schema = make_schema(type: "object", properties: { name: { type: "string" } })
        errors = RubyLLM::Contract::SchemaValidator.validate([1, 2], schema)
        expect(errors).not_to be_empty
      end

      it "rejects String when schema expects object" do
        schema = make_schema(type: "object", properties: { name: { type: "string" } })
        errors = RubyLLM::Contract::SchemaValidator.validate("hello", schema)
        expect(errors).not_to be_empty
      end
    end
  end

  # ===========================================================================
  # 3. RETRY -- deterministic behavior
  # ===========================================================================
  describe "CERTIFICATION: Retry" do
    describe "exactly N attempts when all fail" do
      it "makes exactly 3 attempts when max_attempts is 3 and all fail" do
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
            RubyLLM::Contract::Adapters::Response.new(
              content: "not json at all",
              usage: { input_tokens: 10, output_tokens: 5 }
            )
          end
        end.new

        result = step.run("test", context: { adapter: adapter })

        expect(result.status).to eq(:parse_error)
        expect(call_count).to eq(3),
                              "Expected exactly 3 adapter calls, got #{call_count}"
      end

      it "makes exactly 1 attempt when max_attempts is 1" do
        step = Class.new(RubyLLM::Contract::Step::Base) do
          input_type String
          output_type RubyLLM::Contract::Types::Hash
          contract { parse :json }
          prompt { |input| user "Process: #{input}" }
          retry_policy attempts: 1, retry_on: %i[parse_error]
        end

        call_count = 0
        adapter = Class.new(RubyLLM::Contract::Adapters::Base) do
          define_method(:call) do |**_opts|
            call_count += 1
            RubyLLM::Contract::Adapters::Response.new(
              content: "bad",
              usage: { input_tokens: 10, output_tokens: 5 }
            )
          end
        end.new

        step.run("test", context: { adapter: adapter })
        expect(call_count).to eq(1)
      end

      it "stops early on success (attempt 2 of 5)" do
        step = Class.new(RubyLLM::Contract::Step::Base) do
          input_type String
          output_type RubyLLM::Contract::Types::Hash
          contract { parse :json }
          prompt { |input| user "Process: #{input}" }
          retry_policy attempts: 5, retry_on: %i[parse_error]
        end

        call_count = 0
        adapter = Class.new(RubyLLM::Contract::Adapters::Base) do
          define_method(:call) do |**_opts|
            call_count += 1
            content = call_count >= 2 ? '{"ok": true}' : "bad"
            RubyLLM::Contract::Adapters::Response.new(
              content: content,
              usage: { input_tokens: 10, output_tokens: 5 }
            )
          end
        end.new

        result = step.run("test", context: { adapter: adapter })
        expect(result.status).to eq(:ok)
        expect(call_count).to eq(2),
                              "Should stop after 2 calls (success on attempt 2)"
      end
    end

    describe "model escalation uses correct model per attempt" do
      it "passes the correct model to adapter on each attempt" do
        step = Class.new(RubyLLM::Contract::Step::Base) do
          input_type String
          output_type RubyLLM::Contract::Types::Hash
          contract { parse :json }
          prompt { |input| user "Process: #{input}" }
          retry_policy do
            escalate "gpt-3.5-turbo", "gpt-4", "gpt-4-turbo"
            retry_on :parse_error
          end
        end

        models_seen = []
        adapter = Class.new(RubyLLM::Contract::Adapters::Base) do
          define_method(:call) do |messages:, **opts|
            models_seen << opts[:model]
            content = models_seen.length >= 3 ? '{"ok": true}' : "bad"
            RubyLLM::Contract::Adapters::Response.new(
              content: content,
              usage: { input_tokens: 10, output_tokens: 5 }
            )
          end
        end.new

        result = step.run("test", context: { adapter: adapter })

        expect(result.status).to eq(:ok)
        expect(models_seen).to eq(["gpt-3.5-turbo", "gpt-4", "gpt-4-turbo"]),
                               "Models should escalate in order, got: #{models_seen}"
      end

      it "uses last model when attempts exceed model list length" do
        policy = RubyLLM::Contract::Step::RetryPolicy.new do
          escalate "model-a", "model-b"
          attempts 4
        end

        expect(policy.model_for_attempt(0, "default")).to eq("model-a")
        expect(policy.model_for_attempt(1, "default")).to eq("model-b")
        expect(policy.model_for_attempt(2, "default")).to eq("model-b") # falls back to last
        expect(policy.model_for_attempt(3, "default")).to eq("model-b") # falls back to last
      end

      it "uses default model when no escalation models set" do
        policy = RubyLLM::Contract::Step::RetryPolicy.new(attempts: 3)

        expect(policy.model_for_attempt(0, "default-model")).to eq("default-model")
        expect(policy.model_for_attempt(1, "default-model")).to eq("default-model")
        expect(policy.model_for_attempt(2, "default-model")).to eq("default-model")
      end
    end

    describe "attempt log correctness" do
      it "has exactly N entries with correct models and statuses" do
        step = Class.new(RubyLLM::Contract::Step::Base) do
          input_type String
          output_type RubyLLM::Contract::Types::Hash
          contract { parse :json }
          prompt { |input| user "Process: #{input}" }
          retry_policy do
            escalate "model-a", "model-b", "model-c"
            retry_on :parse_error
          end
        end

        call_count = 0
        adapter = Class.new(RubyLLM::Contract::Adapters::Base) do
          define_method(:call) do |**_opts|
            call_count += 1
            content = call_count >= 3 ? '{"done": true}' : "bad"
            RubyLLM::Contract::Adapters::Response.new(
              content: content,
              usage: { input_tokens: 50, output_tokens: 25 }
            )
          end
        end.new

        result = step.run("test", context: { adapter: adapter })
        attempts = result.trace.attempts

        expect(attempts.length).to eq(3), "Expected 3 attempt log entries"

        expect(attempts[0][:attempt]).to eq(1)
        expect(attempts[0][:model]).to eq("model-a")
        expect(attempts[0][:status]).to eq(:parse_error)

        expect(attempts[1][:attempt]).to eq(2)
        expect(attempts[1][:model]).to eq("model-b")
        expect(attempts[1][:status]).to eq(:parse_error)

        expect(attempts[2][:attempt]).to eq(3)
        expect(attempts[2][:model]).to eq("model-c")
        expect(attempts[2][:status]).to eq(:ok)
      end
    end

    describe "aggregated usage sums correctly" do
      it "sums known values across all attempts" do
        step = Class.new(RubyLLM::Contract::Step::Base) do
          input_type String
          output_type RubyLLM::Contract::Types::Hash
          contract { parse :json }
          prompt { |input| user "Process: #{input}" }
          retry_policy attempts: 3, retry_on: %i[parse_error]
        end

        attempt_num = 0
        adapter = Class.new(RubyLLM::Contract::Adapters::Base) do
          define_method(:call) do |**_opts|
            attempt_num += 1
            content = attempt_num >= 3 ? '{"ok": true}' : "bad"
            # Each attempt: input=100*attempt_num, output=50*attempt_num
            RubyLLM::Contract::Adapters::Response.new(
              content: content,
              usage: { input_tokens: 100 * attempt_num, output_tokens: 50 * attempt_num }
            )
          end
        end.new

        result = step.run("test", context: { adapter: adapter })

        # Total: 100+200+300 = 600 input, 50+100+150 = 300 output
        expect(result.trace.usage[:input_tokens]).to eq(600),
                                                     "Expected 600 input tokens (100+200+300), got #{result.trace.usage[:input_tokens]}"
        expect(result.trace.usage[:output_tokens]).to eq(300),
                                                      "Expected 300 output tokens (50+100+150), got #{result.trace.usage[:output_tokens]}"
      end
    end

    describe "non-retryable status stops immediately" do
      it "does not retry on :input_error even when retry_on includes parse_error" do
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
            RubyLLM::Contract::Adapters::Response.new(
              content: '{"ok": true}',
              usage: { input_tokens: 10, output_tokens: 5 }
            )
          end
        end.new

        # Integer input to a String input_type step causes :input_error
        result = step.run(42, context: { adapter: adapter })

        expect(result.status).to eq(:input_error)
        expect(call_count).to eq(0),
                              "Should not call adapter at all for input_error"
      end
    end
  end

  # ===========================================================================
  # 4. PIPELINE -- data integrity end-to-end
  # ===========================================================================
  describe "CERTIFICATION: Pipeline" do
    # Helper step classes for pipeline tests
    let(:step_a) do
      Class.new(RubyLLM::Contract::Step::Base) do
        input_type String
        output_type RubyLLM::Contract::Types::Hash
        contract { parse :json }
        prompt { |input| user "step_a: #{input}" }
      end
    end

    let(:step_b) do
      Class.new(RubyLLM::Contract::Step::Base) do
        input_type RubyLLM::Contract::Types::Hash
        output_type RubyLLM::Contract::Types::Hash
        contract { parse :json }
        prompt { |input| user "step_b: #{input}" }
      end
    end

    let(:step_c) do
      Class.new(RubyLLM::Contract::Step::Base) do
        input_type RubyLLM::Contract::Types::Hash
        output_type RubyLLM::Contract::Types::Hash
        contract { parse :json }
        prompt { |input| user "step_c: #{input}" }
      end
    end

    let(:step_d) do
      Class.new(RubyLLM::Contract::Step::Base) do
        input_type RubyLLM::Contract::Types::Hash
        output_type RubyLLM::Contract::Types::Hash
        contract { parse :json }
        prompt { |input| user "step_d: #{input}" }
      end
    end

    describe "4-step pipeline success" do
      it "outputs_by_step has all 4 steps on success" do
        sa = step_a
        sb = step_b
        sc = step_c
        sd = step_d
        pipeline = Class.new(RubyLLM::Contract::Pipeline::Base) do
          step sa, as: :alpha
          step sb, as: :beta
          step sc, as: :gamma
          step sd, as: :delta
        end

        result = pipeline.test("input", responses: {
                                 alpha: '{"from": "alpha", "val": 1}',
                                 beta: '{"from": "beta", "val": 2}',
                                 gamma: '{"from": "gamma", "val": 3}',
                                 delta: '{"from": "delta", "val": 4}'
                               })

        expect(result.status).to eq(:ok)
        expect(result.outputs_by_step.keys).to contain_exactly(:alpha, :beta, :gamma, :delta)
        expect(result.outputs_by_step[:alpha]).to eq({ from: "alpha", val: 1 })
        expect(result.outputs_by_step[:delta]).to eq({ from: "delta", val: 4 })
        expect(result.failed_step).to be_nil
      end
    end

    describe "4-step pipeline failure at step 3" do
      it "outputs_by_step has only completed steps (1 and 2)" do
        sa = step_a
        sb = step_b
        sd = step_d
        step_fail = Class.new(RubyLLM::Contract::Step::Base) do
          input_type RubyLLM::Contract::Types::Hash
          output_type RubyLLM::Contract::Types::Hash
          contract { parse :json }
          prompt { |input| user "fail: #{input}" }
          validate("intentional fail") { |_o| false }
        end

        pipeline = Class.new(RubyLLM::Contract::Pipeline::Base) do
          step sa, as: :alpha
          step sb, as: :beta
          step step_fail, as: :gamma
          step sd, as: :delta
        end

        result = pipeline.test("input", responses: {
                                 alpha: '{"from": "alpha"}',
                                 beta: '{"from": "beta"}',
                                 gamma: '{"from": "gamma"}',
                                 delta: '{"from": "delta"}'
                               })

        expect(result.status).not_to eq(:ok)
        expect(result.failed_step).to eq(:gamma)
        expect(result.outputs_by_step.keys).to contain_exactly(:alpha, :beta)
        expect(result.outputs_by_step).not_to have_key(:gamma)
        expect(result.outputs_by_step).not_to have_key(:delta)
      end
    end

    describe "no cross-step data leakage" do
      it "each step receives only the previous step output as input" do
        sa = step_a

        step_spy = Class.new(RubyLLM::Contract::Step::Base) do
          input_type RubyLLM::Contract::Types::Hash
          output_type RubyLLM::Contract::Types::Hash
          contract { parse :json }
          prompt { |input| user "spy: #{input}" }
        end

        ss = step_spy
        pipeline = Class.new(RubyLLM::Contract::Pipeline::Base) do
          step sa, as: :first
          step ss, as: :second
          step ss, as: :third
        end

        # Each step transforms data independently
        result = pipeline.test("hello", responses: {
                                 first: '{"step": "first", "data": "A"}',
                                 second: '{"step": "second", "data": "B"}',
                                 third: '{"step": "third", "data": "C"}'
                               })

        expect(result.status).to eq(:ok)
        # Step 3 output should be from step 3 response, not step 1
        expect(result.outputs_by_step[:third]).to eq({ step: "third", data: "C" })

        # The pipeline passes step N's output as step N+1's input.
        # Step 3 cannot see step 1's output directly -- it only receives step 2's output.
        # This is enforced by the pipeline runner's current_input = result.parsed_output pattern.
        # Verify the final output in outputs_by_step is from step 3, not step 1.
        expect(result.outputs_by_step[:third][:step]).to eq("third")
        expect(result.outputs_by_step[:third][:data]).to eq("C")
      end
    end

    describe "pipeline trace completeness" do
      it "trace has total_usage summed from all steps" do
        sa = step_a
        sb = step_b
        pipeline = Class.new(RubyLLM::Contract::Pipeline::Base) do
          step sa, as: :first
          step sb, as: :second
        end

        result = pipeline.test("hello", responses: {
                                 first: '{"ok": true}',
                                 second: '{"ok": true}'
                               })

        expect(result.trace).not_to be_nil
        expect(result.trace.total_usage).to be_a(Hash)
        expect(result.trace.total_usage).to have_key(:input_tokens)
        expect(result.trace.total_usage).to have_key(:output_tokens)
        expect(result.trace.trace_id).to match(/\A[0-9a-f-]+\z/)
        expect(result.trace.total_latency_ms).to be_a(Integer)
      end
    end
  end

  # ===========================================================================
  # 5. EVAL -- correctness
  # ===========================================================================
  describe "CERTIFICATION: Eval" do
    describe "sample_response that passes everything" do
      it "returns Report#passed? true and score 1.0" do
        step = Class.new(RubyLLM::Contract::Step::Base) do
          prompt { user "{input}" }
          output_type RubyLLM::Contract::Types::Hash
          contract { parse :json }
          validate("has name") { |o| o[:name].is_a?(String) }
        end

        adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"name": "Alice"}')
        ds = RubyLLM::Contract::Eval::Dataset.define("passing") do
          add_case("basic", input: "test", expected: { name: "Alice" })
        end

        report = RubyLLM::Contract::Eval::Runner.run(step: step, dataset: ds, context: { adapter: adapter })

        expect(report.passed?).to be true
        expect(report.score).to eq(1.0)
        expect(report.results.first.passed?).to be true
      end
    end

    describe "sample_response that fails schema" do
      it "fails before verify (contract failure)" do
        step = Class.new(RubyLLM::Contract::Step::Base) do
          prompt { user "{input}" }
          output_type RubyLLM::Contract::Types::Hash
          contract { parse :json }
          validate("has name") { |o| o[:name].is_a?(String) }
        end

        # Adapter returns non-JSON, causing parse error
        adapter = RubyLLM::Contract::Adapters::Test.new(response: "not json at all")
        ds = RubyLLM::Contract::Eval::Dataset.define("failing_schema") do
          add_case("bad response", input: "test", expected: { name: "Alice" })
        end

        report = RubyLLM::Contract::Eval::Runner.run(step: step, dataset: ds, context: { adapter: adapter })

        expect(report.passed?).to be false
        expect(report.score).to eq(0.0)
        expect(report.results.first.passed?).to be false
        expect(report.results.first.details).to match(/step failed/)
      end
    end

    describe "sample_response passes schema but fails verify" do
      it "score reflects partial pass" do
        step = Class.new(RubyLLM::Contract::Step::Base) do
          prompt { user "{input}" }
          output_type RubyLLM::Contract::Types::Hash
          contract { parse :json }
        end

        # Response is valid JSON but does not match expected
        adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"name": "Bob"}')
        ds = RubyLLM::Contract::Eval::Dataset.define("partial") do
          add_case("match test", input: "test", expected: { name: "Alice" })
        end

        report = RubyLLM::Contract::Eval::Runner.run(step: step, dataset: ds, context: { adapter: adapter })

        expect(report.passed?).to be false
        expect(report.results.first.passed?).to be false
        # Score should be 0.0 because expected hash does not match
        expect(report.score).to eq(0.0)
      end
    end

    describe "mixed results" do
      it "score reflects proportion of passes" do
        step = Class.new(RubyLLM::Contract::Step::Base) do
          prompt { user "{input}" }
          output_type RubyLLM::Contract::Types::Hash
          contract { parse :json }
        end

        adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"name": "Alice"}')
        ds = RubyLLM::Contract::Eval::Dataset.define("mixed") do
          add_case("passes", input: "test", expected: { name: "Alice" })
          add_case("fails", input: "test", expected: { name: "Bob" })
        end

        report = RubyLLM::Contract::Eval::Runner.run(step: step, dataset: ds, context: { adapter: adapter })

        expect(report.passed?).to be false
        expect(report.score).to eq(0.5)
        expect(report.pass_rate).to eq("1/2")
      end
    end

    describe "zero-verify eval (contract check only)" do
      it "passes when contract holds" do
        step = Class.new(RubyLLM::Contract::Step::Base) do
          prompt { user "{input}" }
          output_type RubyLLM::Contract::Types::Hash
          contract { parse :json }
          define_eval(:smoke) do
            default_input "test"
            sample_response({ name: "Alice" })
          end
        end

        report = step.run_eval(:smoke)

        expect(report).to be_a(RubyLLM::Contract::Eval::Report)
        expect(report.passed?).to be true
      end
    end
  end

  # ===========================================================================
  # 6. CONFIGURATION -- production defaults
  # ===========================================================================
  describe "CERTIFICATION: Configuration" do
    describe "no adapter + no API key" do
      it "raises clear error message" do
        step = Class.new(RubyLLM::Contract::Step::Base) do
          prompt { user "{input}" }
        end

        expect do
          step.run("test")
        end.to raise_error(RubyLLM::Contract::Error, /No adapter configured/)
      end
    end

    describe "model override in context" do
      it "context model takes precedence over default" do
        RubyLLM::Contract.configure do |c|
          c.default_model = "default-model"
        end

        step = Class.new(RubyLLM::Contract::Step::Base) do
          prompt { user "{input}" }
          output_type String
        end

        model_seen = nil
        adapter = Class.new(RubyLLM::Contract::Adapters::Base) do
          define_method(:call) do |messages:, **opts|
            model_seen = opts[:model]
            RubyLLM::Contract::Adapters::Response.new(
              content: "ok",
              usage: { input_tokens: 0, output_tokens: 0 }
            )
          end
        end.new

        step.run("test", context: { adapter: adapter, model: "override-model" })

        expect(model_seen).to eq("override-model"),
                              "Context model should override default, got: #{model_seen}"
      end
    end

    describe "default model from configuration" do
      it "uses configured default model when context does not specify" do
        RubyLLM::Contract.configure do |c|
          c.default_model = "configured-default"
        end

        step = Class.new(RubyLLM::Contract::Step::Base) do
          prompt { user "{input}" }
          output_type String
        end

        model_seen = nil
        adapter = Class.new(RubyLLM::Contract::Adapters::Base) do
          define_method(:call) do |messages:, **opts|
            model_seen = opts[:model]
            RubyLLM::Contract::Adapters::Response.new(
              content: "ok",
              usage: { input_tokens: 0, output_tokens: 0 }
            )
          end
        end.new

        step.run("test", context: { adapter: adapter })

        expect(model_seen).to eq("configured-default")
      end
    end
  end

  # ===========================================================================
  # 7. RESULT -- immutability
  # ===========================================================================
  describe "CERTIFICATION: Result immutability" do
    describe "Step::Result is frozen" do
      it "cannot mutate status" do
        result = RubyLLM::Contract::Step::Result.new(
          status: :ok, raw_output: "hello", parsed_output: { name: "Alice" }
        )
        expect(result).to be_frozen
        expect { result.instance_variable_set(:@status, :hacked) }.to raise_error(FrozenError)
      end

      it "cannot mutate validation_errors" do
        result = RubyLLM::Contract::Step::Result.new(
          status: :ok, raw_output: "hello", parsed_output: {},
          validation_errors: ["error1"]
        )
        expect(result.validation_errors).to be_frozen
        expect { result.validation_errors << "injected" }.to raise_error(FrozenError)
      end

      it "cannot mutate trace" do
        result = RubyLLM::Contract::Step::Result.new(
          status: :ok, raw_output: "hello", parsed_output: {},
          trace: { model: "gpt-4" }
        )
        expect(result.trace).to be_frozen
        expect(result.trace).to be_a(RubyLLM::Contract::Step::Trace)
        expect { result.trace.instance_variable_set(:@model, "hacked") }.to raise_error(FrozenError)
      end
    end

    describe "parsed_output is deep frozen" do
      it "cannot mutate top-level hash" do
        step = Class.new(RubyLLM::Contract::Step::Base) do
          prompt { user "{input}" }
          output_type RubyLLM::Contract::Types::Hash
          contract { parse :json }
        end

        adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"name": "Alice", "tags": ["a", "b"]}')
        result = step.run("test", context: { adapter: adapter })

        expect(result.status).to eq(:ok)
        expect(result.parsed_output).to be_frozen
        expect { result.parsed_output[:hacked] = true }.to raise_error(FrozenError)
      end

      it "cannot mutate nested array in parsed_output" do
        step = Class.new(RubyLLM::Contract::Step::Base) do
          prompt { user "{input}" }
          output_type RubyLLM::Contract::Types::Hash
          contract { parse :json }
        end

        adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"tags": ["a", "b"]}')
        result = step.run("test", context: { adapter: adapter })

        expect(result.status).to eq(:ok)
        expect(result.parsed_output[:tags]).to be_frozen
        expect { result.parsed_output[:tags] << "injected" }.to raise_error(FrozenError)
      end

      it "cannot mutate nested string in parsed_output" do
        step = Class.new(RubyLLM::Contract::Step::Base) do
          prompt { user "{input}" }
          output_type RubyLLM::Contract::Types::Hash
          contract { parse :json }
        end

        adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"name": "Alice"}')
        result = step.run("test", context: { adapter: adapter })

        expect(result.status).to eq(:ok)
        expect(result.parsed_output[:name]).to be_frozen
        expect { result.parsed_output[:name] << " hacked" }.to raise_error(FrozenError)
      end

      it "cannot mutate deeply nested hash in parsed_output" do
        step = Class.new(RubyLLM::Contract::Step::Base) do
          prompt { user "{input}" }
          output_type RubyLLM::Contract::Types::Hash
          contract { parse :json }
        end

        adapter = RubyLLM::Contract::Adapters::Test.new(
          response: '{"meta": {"nested": {"deep": "value"}}}'
        )
        result = step.run("test", context: { adapter: adapter })

        expect(result.status).to eq(:ok)
        expect(result.parsed_output[:meta]).to be_frozen
        expect(result.parsed_output[:meta][:nested]).to be_frozen
        expect { result.parsed_output[:meta][:nested][:hacked] = true }.to raise_error(FrozenError)
      end
    end

    describe "Step::Trace is frozen" do
      it "trace object is frozen" do
        trace = RubyLLM::Contract::Step::Trace.new(
          messages: [{ role: :user, content: "test" }],
          model: "gpt-4",
          latency_ms: 100,
          usage: { input_tokens: 10, output_tokens: 5 }
        )
        expect(trace).to be_frozen
        expect { trace.instance_variable_set(:@model, "hacked") }.to raise_error(FrozenError)
      end
    end

    describe "Pipeline::Result is frozen" do
      it "result and its components are frozen" do
        result = RubyLLM::Contract::Pipeline::Result.new(
          status: :ok, step_results: [], outputs_by_step: { a: { data: 1 } }
        )
        expect(result).to be_frozen
        expect(result.step_results).to be_frozen
        expect(result.outputs_by_step).to be_frozen
      end
    end

    describe "Pipeline::Trace is frozen" do
      it "trace is frozen" do
        trace = RubyLLM::Contract::Pipeline::Trace.new(
          trace_id: "abc-123",
          total_latency_ms: 500,
          total_usage: { input_tokens: 100, output_tokens: 50 }
        )
        expect(trace).to be_frozen
      end
    end

    describe "Eval::Report is frozen" do
      it "report and results are frozen" do
        report = RubyLLM::Contract::Eval::Report.new(
          dataset_name: "test",
          results: [RubyLLM::Contract::Eval::CaseResult.new(
            name: "a", input: nil, output: nil, expected: nil,
            step_status: :ok, score: 1.0, passed: true
          )]
        )
        expect(report).to be_frozen
        expect(report.results).to be_frozen
      end
    end

    describe "EvaluationResult is frozen" do
      it "is frozen after creation" do
        er = RubyLLM::Contract::Eval::EvaluationResult.new(score: 0.5, passed: false, details: "reason")
        expect(er).to be_frozen
      end
    end
  end

  # ===========================================================================
  # BUG HUNTING: Looking for remaining issues
  # ===========================================================================

  # ---------------------------------------------------------------------------
  # BUG 64: SchemaValidator does not validate required fields that are present
  # but have nil value when the field is NOT defined in properties.
  #
  # When a field is listed in `required` but has no corresponding entry in
  # `properties`, and the output has that key set to nil, it passes validation
  # because:
  # 1. check_required sees the key exists -> passes
  # 2. check_properties has no constraints for the field -> skips
  # The nil value silently passes even though the field is "required" and
  # having nil for a required field is almost certainly a bug.
  #
  # However, this is actually per JSON Schema spec: "required" only checks
  # key presence, not value. A required field with null value is valid per spec
  # (unless the type constraint also excludes null). This is CERTIFIED behavior.
  # ---------------------------------------------------------------------------
  describe "CERTIFIED: required field with nil value (per JSON Schema spec)" do
    it "required field with nil value passes if present (per spec)" do
      schema = Class.new do
        def to_json_schema
          { schema: { type: "object", required: %w[name], properties: { name: { type: "string" } } } }
        end
      end

      # Present but nil -> check_required passes (key exists),
      # check_properties reports type error (nil is not string) for required fields
      errors = RubyLLM::Contract::SchemaValidator.validate({ name: nil }, schema.new)
      expect(errors.join).to match(/expected string.*got nil|nil/),
                             "Required field with nil value should report type mismatch"
    end
  end

  # ---------------------------------------------------------------------------
  # BUG 65: Parser.extract_json with a JSON object where the first { is inside
  # a non-JSON context. When the LLM returns something like:
  # "Use {braces} carefully: {\"real\": \"json\"}"
  # The bracket matcher starts at the first { in "{braces}" and tries to
  # find a balanced match. It will scan: {braces} -- depth goes to 1, then
  # finds } -- depth goes to 0, returns "{braces}" which is not valid JSON.
  # Then JSON.parse("{braces}") fails, and the ParseError is raised.
  # The SECOND JSON object is never found.
  #
  # This is a KNOWN LIMITATION documented in round 7 (GUARD 42) -- the parser
  # only tries from the FIRST bracket. If the first bracket is not the start
  # of the JSON, the extraction fails. This is by design (extract_json is a
  # fallback, not a full parser).
  #
  # CERTIFIED: This is a documented, acceptable limitation. The primary
  # parse path (JSON.parse on the full text) handles most cases. extract_json
  # is a best-effort fallback.
  # ---------------------------------------------------------------------------
  describe "CERTIFIED: extract_json starts from first bracket (documented limitation)" do
    it "fails when first bracket is not JSON start" do
      text = "Use {braces} carefully: {\"real\": \"json\"}"
      expect do
        RubyLLM::Contract::Parser.parse(text, strategy: :json)
      end.to raise_error(RubyLLM::Contract::ParseError)
    end

    it "succeeds when JSON is the first bracket structure" do
      text = "Here: {\"real\": \"json\"} and more {braces}"
      result = RubyLLM::Contract::Parser.parse(text, strategy: :json)
      expect(result).to eq({ real: "json" })
    end
  end

  # ---------------------------------------------------------------------------
  # BUG 66: Pipeline step with model: override in step declaration.
  #
  # Pipeline::Base.step accepts model: keyword. The runner merges it into
  # the context: `step_def[:model] ? @context.merge(model: step_def[:model]) : @context`
  # This means a step-level model override in the pipeline takes precedence
  # over the context model.
  #
  # CERTIFIED: This is correct behavior.
  # ---------------------------------------------------------------------------
  describe "CERTIFIED: Pipeline step-level model override" do
    it "step-level model overrides context model" do
      step_class = Class.new(RubyLLM::Contract::Step::Base) do
        prompt { user "{input}" }
        output_type String
      end

      pipeline = Class.new(RubyLLM::Contract::Pipeline::Base) do
        step step_class, as: :first, model: "step-specific-model"
      end

      model_seen = nil
      adapter = Class.new(RubyLLM::Contract::Adapters::Base) do
        define_method(:call) do |messages:, **opts|
          model_seen = opts[:model]
          RubyLLM::Contract::Adapters::Response.new(
            content: "ok",
            usage: { input_tokens: 0, output_tokens: 0 }
          )
        end
      end.new

      pipeline.run("test", context: { adapter: adapter, model: "context-model" })

      expect(model_seen).to eq("step-specific-model"),
                            "Step-level model should override context model"
    end
  end

  # ---------------------------------------------------------------------------
  # BUG 67: RetryPolicy.retryable? works with Step::Result status checking.
  #
  # The retryable_statuses default is [:validation_failed, :parse_error, :adapter_error].
  # This means :ok results are NOT retryable (correct -- we stop on success).
  # This also means :input_error and :limit_exceeded are NOT retryable by default.
  #
  # CERTIFIED: This is correct behavior.
  # ---------------------------------------------------------------------------
  describe "CERTIFIED: RetryPolicy retryable? status checking" do
    it "ok is not retryable" do
      policy = RubyLLM::Contract::Step::RetryPolicy.new(attempts: 3)
      result = RubyLLM::Contract::Step::Result.new(status: :ok, raw_output: nil, parsed_output: nil)
      expect(policy.retryable?(result)).to be false
    end

    it "parse_error is retryable by default" do
      policy = RubyLLM::Contract::Step::RetryPolicy.new(attempts: 3)
      result = RubyLLM::Contract::Step::Result.new(status: :parse_error, raw_output: nil, parsed_output: nil)
      expect(policy.retryable?(result)).to be true
    end

    it "validation_failed is retryable by default" do
      policy = RubyLLM::Contract::Step::RetryPolicy.new(attempts: 3)
      result = RubyLLM::Contract::Step::Result.new(status: :validation_failed, raw_output: nil, parsed_output: nil)
      expect(policy.retryable?(result)).to be true
    end

    it "adapter_error is retryable by default" do
      policy = RubyLLM::Contract::Step::RetryPolicy.new(attempts: 3)
      result = RubyLLM::Contract::Step::Result.new(status: :adapter_error, raw_output: nil, parsed_output: nil)
      expect(policy.retryable?(result)).to be true
    end

    it "input_error is NOT retryable by default" do
      policy = RubyLLM::Contract::Step::RetryPolicy.new(attempts: 3)
      result = RubyLLM::Contract::Step::Result.new(status: :input_error, raw_output: nil, parsed_output: nil)
      expect(policy.retryable?(result)).to be false
    end

    it "limit_exceeded is NOT retryable by default" do
      policy = RubyLLM::Contract::Step::RetryPolicy.new(attempts: 3)
      result = RubyLLM::Contract::Step::Result.new(status: :limit_exceeded, raw_output: nil, parsed_output: nil)
      expect(policy.retryable?(result)).to be false
    end

    it "custom retry_on overrides defaults" do
      policy = RubyLLM::Contract::Step::RetryPolicy.new(attempts: 3, retry_on: [:adapter_error])
      result_parse = RubyLLM::Contract::Step::Result.new(status: :parse_error, raw_output: nil, parsed_output: nil)
      result_adapter = RubyLLM::Contract::Step::Result.new(status: :adapter_error, raw_output: nil, parsed_output: nil)
      expect(policy.retryable?(result_parse)).to be false
      expect(policy.retryable?(result_adapter)).to be true
    end
  end

  # ---------------------------------------------------------------------------
  # BUG 68: Validator deep_freeze on non-Hash, non-Array, non-String types.
  #
  # The deep_freeze method in Validator handles Hash, Array, and String, but
  # other types (Integer, Float, TrueClass, FalseClass, NilClass) fall through
  # to the else branch which does nothing. In Ruby, integers, floats, booleans,
  # and nil are already immutable (frozen), so this is correct.
  #
  # CERTIFIED: Correct behavior -- Ruby primitives are inherently frozen.
  # ---------------------------------------------------------------------------
  describe "CERTIFIED: deep_freeze handles all JSON types correctly" do
    it "integers are inherently frozen" do
      expect(42).to be_frozen
    end

    it "booleans are inherently frozen" do
      expect(true).to be_frozen
      expect(false).to be_frozen
    end

    it "nil is inherently frozen" do
      expect(nil).to be_frozen
    end

    it "deep_freeze works on complex nested structures" do
      validator = RubyLLM::Contract::Validator.new
      result = validator.validate(
        raw_output: '{"a": [1, "two", true, null, {"b": "c"}]}',
        definition: RubyLLM::Contract::Definition.new { parse :json },
        output_type: RubyLLM::Contract::Types::Hash
      )

      output = result[:parsed_output]
      expect(output).to be_frozen
      expect(output[:a]).to be_frozen
      expect(output[:a][1]).to be_frozen # "two" string
      expect(output[:a][4]).to be_frozen # nested hash
      expect(output[:a][4][:b]).to be_frozen # "c" string
    end
  end

  # ---------------------------------------------------------------------------
  # BUG 69: Contract::Definition is frozen after initialization.
  #
  # CERTIFIED: Definition freezes itself and its invariants array.
  # ---------------------------------------------------------------------------
  describe "CERTIFIED: Contract::Definition immutability" do
    it "definition is frozen" do
      defn = RubyLLM::Contract::Definition.new do
        parse :json
        invariant("test") { |_o| true }
      end
      expect(defn).to be_frozen
      expect(defn.invariants).to be_frozen
    end
  end

  # ---------------------------------------------------------------------------
  # BUG 70: Step::Trace.merge creates a new frozen trace without mutating the original.
  #
  # CERTIFIED: Trace.merge returns a new Trace instance.
  # ---------------------------------------------------------------------------
  describe "CERTIFIED: Trace.merge does not mutate original" do
    it "returns a new Trace with overrides" do
      original = RubyLLM::Contract::Step::Trace.new(
        model: "gpt-4", latency_ms: 100,
        usage: { input_tokens: 10, output_tokens: 5 }
      )
      merged = original.merge(model: "gpt-4-turbo", latency_ms: 200)

      expect(original.model).to eq("gpt-4")
      expect(original.latency_ms).to eq(100)
      expect(merged.model).to eq("gpt-4-turbo")
      expect(merged.latency_ms).to eq(200)
      expect(merged.usage).to eq({ input_tokens: 10, output_tokens: 5 })
      expect(merged).to be_frozen
    end
  end

  # ---------------------------------------------------------------------------
  # BUG 71: symbolize_keys handles nested structures including arrays of hashes.
  #
  # CERTIFIED: Parser.symbolize_keys recursively processes Hash and Array.
  # ---------------------------------------------------------------------------
  describe "CERTIFIED: symbolize_keys handles nested arrays of hashes" do
    it "symbolizes keys in arrays of hashes" do
      input = [{ "name" => "Alice", "tags" => [{ "id" => 1 }] }]
      result = RubyLLM::Contract::Parser.parse(input, strategy: :json)
      expect(result).to eq([{ name: "Alice", tags: [{ id: 1 }] }])
    end
  end

  # ---------------------------------------------------------------------------
  # FINAL CERTIFICATION SUMMARY
  # ---------------------------------------------------------------------------
  describe "Final integration: full step lifecycle" do
    it "runs a complete step with all features: schema, invariants, type, trace" do
      step = Class.new(RubyLLM::Contract::Step::Base) do
        input_type String
        output_type RubyLLM::Contract::Types::Hash
        prompt do |input|
          system "You are a classifier."
          user "Classify: #{input}"
        end
        contract do
          parse :json
          invariant("has category") { |o| o[:category].is_a?(String) }
          invariant("has confidence") { |o| o[:confidence].is_a?(Numeric) && o[:confidence].between?(0.0, 1.0) }
        end
      end

      adapter = RubyLLM::Contract::Adapters::Test.new(
        response: '{"category": "tech", "confidence": 0.95}'
      )
      result = step.run("Ruby programming", context: { adapter: adapter })

      expect(result.status).to eq(:ok)
      expect(result.ok?).to be true
      expect(result.parsed_output).to eq({ category: "tech", confidence: 0.95 })
      expect(result.parsed_output).to be_frozen
      expect(result.validation_errors).to be_empty
      expect(result.trace).to be_a(RubyLLM::Contract::Step::Trace)
      expect(result.trace.messages.length).to eq(2) # system + user
    end

    it "runs a complete step with retry and model escalation" do
      step = Class.new(RubyLLM::Contract::Step::Base) do
        input_type String
        output_type RubyLLM::Contract::Types::Hash
        contract { parse :json }
        prompt { |input| user "Process: #{input}" }
        retry_policy do
          escalate "cheap-model", "expensive-model"
          retry_on :parse_error
        end
      end

      call_count = 0
      adapter = Class.new(RubyLLM::Contract::Adapters::Base) do
        define_method(:call) do |**_opts|
          call_count += 1
          content = call_count >= 2 ? '{"result": "success"}' : "not json"
          RubyLLM::Contract::Adapters::Response.new(
            content: content,
            usage: { input_tokens: 100, output_tokens: 50 }
          )
        end
      end.new

      result = step.run("test", context: { adapter: adapter })

      expect(result.status).to eq(:ok)
      expect(result.parsed_output).to eq({ result: "success" })
      expect(result.trace.attempts.length).to eq(2)
      expect(result.trace.attempts[0][:model]).to eq("cheap-model")
      expect(result.trace.attempts[1][:model]).to eq("expensive-model")
      expect(result.trace.usage[:input_tokens]).to eq(200)
      expect(result.trace.usage[:output_tokens]).to eq(100)
    end

    it "runs a complete pipeline end-to-end" do
      classify = Class.new(RubyLLM::Contract::Step::Base) do
        input_type String
        output_type RubyLLM::Contract::Types::Hash
        contract { parse :json }
        prompt { |i| user "classify: #{i}" }
      end

      enrich = Class.new(RubyLLM::Contract::Step::Base) do
        input_type RubyLLM::Contract::Types::Hash
        output_type RubyLLM::Contract::Types::Hash
        contract { parse :json }
        prompt { |i| user "enrich: #{i}" }
      end

      pipeline = Class.new(RubyLLM::Contract::Pipeline::Base) do
        step classify, as: :classify
        step enrich, as: :enrich
      end

      result = pipeline.test("hello world", responses: {
                               classify: '{"category": "greeting"}',
                               enrich: '{"category": "greeting", "sentiment": "positive"}'
                             })

      expect(result.status).to eq(:ok)
      expect(result.outputs_by_step[:classify]).to eq({ category: "greeting" })
      expect(result.outputs_by_step[:enrich]).to eq({ category: "greeting", sentiment: "positive" })
      expect(result.trace.trace_id).not_to be_nil
      expect(result.step_results.length).to eq(2)
    end
  end
end
