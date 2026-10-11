# frozen_string_literal: true

require "schematist"

RSpec.describe RubyLLM::Contract::SchemaValidator do
  let(:schema) do
    Schematist::Schema.create do
      string :intent, enum: %w[sales support billing]
      number :confidence, minimum: 0.0, maximum: 1.0
      string :summary
    end
  end

  describe ".validate" do
    context "valid output" do
      it "returns no errors" do
        output = { intent: "sales", confidence: 0.9, summary: "test" }
        errors = described_class.validate(output, schema)
        expect(errors).to be_empty
      end
    end

    context "missing required field" do
      it "catches missing field" do
        output = { intent: "sales", confidence: 0.9 }
        errors = described_class.validate(output, schema)
        expect(errors).to include("missing required field: summary")
      end

      it "catches multiple missing fields" do
        output = { intent: "sales" }
        errors = described_class.validate(output, schema)
        expect(errors).to include("missing required field: confidence")
        expect(errors).to include("missing required field: summary")
      end
    end

    context "enum violation" do
      it "catches invalid enum value" do
        output = { intent: "INVALID", confidence: 0.9, summary: "test" }
        errors = described_class.validate(output, schema)
        expect(errors).to include(match(/intent.*not in enum/))
      end
    end

    context "number range violation" do
      it "catches below minimum" do
        output = { intent: "sales", confidence: -0.5, summary: "test" }
        errors = described_class.validate(output, schema)
        expect(errors).to include(match(/confidence.*below minimum/))
      end

      it "catches above maximum" do
        output = { intent: "sales", confidence: 2.5, summary: "test" }
        errors = described_class.validate(output, schema)
        expect(errors).to include(match(/confidence.*above maximum/))
      end
    end

    context "type violation" do
      it "catches wrong type" do
        output = { intent: 42, confidence: 0.9, summary: "test" }
        errors = described_class.validate(output, schema)
        expect(errors).to include(match(/intent.*expected string.*Integer/i))
      end

      it "accepts false for boolean fields" do
        boolean_schema = Class.new do
          def to_json_schema
            {
              schema: {
                type: "object",
                properties: {
                  active: { type: "boolean" }
                },
                required: ["active"]
              }
            }
          end
        end

        errors = described_class.validate({ active: false }, boolean_schema.new)
        expect(errors).to be_empty
      end
    end

    context "multiple violations" do
      it "collects all errors" do
        output = { intent: "INVALID", confidence: 5.0 }
        errors = described_class.validate(output, schema)
        expect(errors.length).to be >= 3 # enum + range + missing
      end
    end

    context "non-hash output" do
      it "returns type mismatch error for non-hash when schema expects object" do
        errors = described_class.validate("not a hash", schema)
        expect(errors).not_to be_empty
        expect(errors.first).to match(/expected object/)
      end

      it "rejects Array output when schema specifies type: object" do
        errors = described_class.validate([{ intent: "sales" }], schema)
        expect(errors).not_to be_empty
      end

      it "rejects Integer output when schema specifies type: object" do
        errors = described_class.validate(42, schema)
        expect(errors).not_to be_empty
      end

      it "rejects nil output when schema specifies type: object" do
        errors = described_class.validate(nil, schema)
        expect(errors).not_to be_empty
      end
    end

    context "additionalProperties: false" do
      let(:strict_schema) do
        double("strict_schema").tap do |s|
          allow(s).to receive(:respond_to?).with(:to_json_schema).and_return(true)
          allow(s).to receive(:to_json_schema).and_return({
                                                            schema: {
                                                              type: "object",
                                                              properties: {
                                                                name: { type: "string" }
                                                              },
                                                              required: ["name"],
                                                              additionalProperties: false
                                                            }
                                                          })
        end
      end

      it "reports additional properties not allowed" do
        errors = described_class.validate({ name: "Alice", extra: "bad" }, strict_schema)
        expect(errors).to include(match(/extra.*additional property not allowed/))
      end

      it "passes when no additional properties are present" do
        errors = described_class.validate({ name: "Alice" }, strict_schema)
        expect(errors).to be_empty
      end
    end

    context "string length constraints" do
      let(:strlen_schema) do
        double("strlen_schema").tap do |s|
          allow(s).to receive(:respond_to?).with(:to_json_schema).and_return(true)
          allow(s).to receive(:to_json_schema).and_return({
                                                            schema: {
                                                              type: "object",
                                                              properties: {
                                                                code: { type: "string", minLength: 2, maxLength: 5 }
                                                              },
                                                              required: ["code"]
                                                            }
                                                          })
        end
      end

      it "catches string shorter than minLength" do
        errors = described_class.validate({ code: "A" }, strlen_schema)
        expect(errors).to include(match(/code.*below minLength 2/))
      end

      it "catches string longer than maxLength" do
        errors = described_class.validate({ code: "ABCDEF" }, strlen_schema)
        expect(errors).to include(match(/code.*above maxLength 5/))
      end

      it "passes string within length range" do
        errors = described_class.validate({ code: "ABC" }, strlen_schema)
        expect(errors).to be_empty
      end
    end

    context "array length constraints" do
      let(:arrlen_schema) do
        double("arrlen_schema").tap do |s|
          allow(s).to receive(:respond_to?).with(:to_json_schema).and_return(true)
          allow(s).to receive(:to_json_schema).and_return({
                                                            schema: {
                                                              type: "object",
                                                              properties: {
                                                                tags: { type: "array", items: { type: "string" },
                                                                        minItems: 1, maxItems: 3 }
                                                              },
                                                              required: ["tags"]
                                                            }
                                                          })
        end
      end

      it "catches array shorter than minItems" do
        errors = described_class.validate({ tags: [] }, arrlen_schema)
        expect(errors).to include(match(/tags.*below minItems 1/))
      end

      it "catches array longer than maxItems" do
        errors = described_class.validate({ tags: %w[a b c d] }, arrlen_schema)
        expect(errors).to include(match(/tags.*above maxItems 3/))
      end

      it "passes array within length range" do
        errors = described_class.validate({ tags: %w[a b] }, arrlen_schema)
        expect(errors).to be_empty
      end
    end

    context "additionalProperties: false on nested objects" do
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

        errors = described_class.validate(
          { profile: { name: "Alice", secret: "leaked" } },
          schema.new
        )

        expect(errors).not_to be_empty
        expect(errors.join).to match(/secret/)
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

        errors = described_class.validate(
          { name: "Alice", extra: "allowed" },
          schema.new
        )

        expect(errors).to be_empty
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

        errors = described_class.validate(
          { items: [{ id: 1, leaked: true }] },
          schema.new
        )

        expect(errors).not_to be_empty
        expect(errors.join).to match(/leaked/)
      end
    end

    context "nested arrays" do
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

        errors = described_class.validate({ matrix: [[1]] }, schema.new)
        expect(errors).not_to be_empty
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

        errors = described_class.validate({ matrix: [["not_an_int"]] }, schema.new)
        expect(errors).not_to be_empty
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

        errors = described_class.validate({ matrix: [[1, 2], [3, 4]] }, schema.new)
        expect(errors).to be_empty
      end
    end

    context "required field with nil value" do
      let(:nullable_schema) do
        double("nullable_schema").tap do |s|
          allow(s).to receive(:respond_to?).with(:to_json_schema).and_return(true)
          allow(s).to receive(:to_json_schema).and_return({
                                                            schema: {
                                                              type: "object",
                                                              properties: {
                                                                name: { type: "string" }
                                                              },
                                                              required: ["name"]
                                                            }
                                                          })
        end
      end

      it "reports type error for required field present with nil value" do
        errors = described_class.validate({ name: nil }, nullable_schema)
        expect(errors).to include(match(/name.*expected string.*got nil/))
      end

      it "works end-to-end: step rejects nil required field value" do
        step = Class.new(RubyLLM::Contract::Step::Base) do
          prompt { user "{input}" }
          output_schema do
            string :name, required: true
            integer :count, required: true
          end
        end

        adapter = RubyLLM::Contract::Adapters::Test.new(response: { "name" => nil, "count" => 42 })
        result = step.run("test", context: { adapter: adapter })

        expect(result.status).to eq(:validation_failed)
      end

      it "passes when non-required field is nil" do
        optional_schema = double("opt_schema").tap do |s|
          allow(s).to receive(:respond_to?).with(:to_json_schema).and_return(true)
          allow(s).to receive(:to_json_schema).and_return({
                                                            schema: {
                                                              type: "object",
                                                              properties: {
                                                                name: { type: "string" },
                                                                bio: { type: "string" }
                                                              },
                                                              required: ["name"]
                                                            }
                                                          })
        end
        errors = described_class.validate({ name: "Alice", bio: nil }, optional_schema)
        expect(errors).to be_empty
      end

      # ----------------------------------------------------------------
      # Bug fix in 0.10.3 — validator must respect nullable schemas on
      # required fields. Before the fix, `type: ["string", "null"]`,
      # `anyOf: [{type:"string"}, {type:"null"}]`, and `oneOf` equivalents
      # were all rejected when the value was nil, even though JSON Schema
      # explicitly permits null. Smoking-gun mutation: removing
      # `nullable_schema?` short-circuit from `validate_nil_field` makes
      # each of these tests fail with "expected ..., got nil".
      # ----------------------------------------------------------------
      it "passes nil on required field when schema declares type: [..., 'null'] (array form)" do
        nullable_schema = double("nullable_schema").tap do |s|
          allow(s).to receive(:respond_to?).with(:to_json_schema).and_return(true)
          allow(s).to receive(:to_json_schema).and_return({
                                                            schema: {
                                                              type: "object",
                                                              properties: {
                                                                x: { type: ["string", "null"] }
                                                              },
                                                              required: ["x"]
                                                            }
                                                          })
        end
        errors = described_class.validate({ x: nil }, nullable_schema)
        expect(errors).to be_empty
      end

      it "passes nil on required field when schema uses anyOf with null branch" do
        nullable_schema = double("nullable_schema").tap do |s|
          allow(s).to receive(:respond_to?).with(:to_json_schema).and_return(true)
          allow(s).to receive(:to_json_schema).and_return({
                                                            schema: {
                                                              type: "object",
                                                              properties: {
                                                                y: { anyOf: [{ type: "string" }, { type: "null" }] }
                                                              },
                                                              required: ["y"]
                                                            }
                                                          })
        end
        errors = described_class.validate({ y: nil }, nullable_schema)
        expect(errors).to be_empty
      end

      it "passes nil on required field when schema uses oneOf with null branch" do
        nullable_schema = double("nullable_schema").tap do |s|
          allow(s).to receive(:respond_to?).with(:to_json_schema).and_return(true)
          allow(s).to receive(:to_json_schema).and_return({
                                                            schema: {
                                                              type: "object",
                                                              properties: {
                                                                z: { oneOf: [{ type: "integer" }, { type: "null" }] }
                                                              },
                                                              required: ["z"]
                                                            }
                                                          })
        end
        errors = described_class.validate({ z: nil }, nullable_schema)
        expect(errors).to be_empty
      end

      it "still rejects nil on required field when schema is non-nullable" do
        # Regression guard: the fix must not over-relax. Plain non-nullable
        # required field (no array type / no anyOf-null) must still raise.
        non_nullable_schema = double("non_nullable_schema").tap do |s|
          allow(s).to receive(:respond_to?).with(:to_json_schema).and_return(true)
          allow(s).to receive(:to_json_schema).and_return({
                                                            schema: {
                                                              type: "object",
                                                              properties: {
                                                                w: { type: "string" }
                                                              },
                                                              required: ["w"]
                                                            }
                                                          })
        end
        errors = described_class.validate({ w: nil }, non_nullable_schema)
        expect(errors).not_to be_empty
        expect(errors.first).to match(/w.*expected.*got nil/)
      end
    end

    # ----------------------------------------------------------------
    # anyOf / oneOf branches were only consulted for nil (0.10.3), so a
    # non-null value under a composition was never validated: an object
    # missing its required fields, or with a wrong-typed field, passed as
    # :ok. Measured in an adopter: an analysis block without `score` was
    # :ok and became a 0/10 fail downstream.
    # ----------------------------------------------------------------
    context "anyOf / oneOf with a non-null value" do
      let(:nullable_block_schema) do
        Schematist::Schema.create do
          any_of :block do
            object do
              integer :score
              string :assessment
            end
            null
          end
        end
      end

      def raw_schema(properties, required)
        double("raw_schema").tap do |s|
          allow(s).to receive(:respond_to?).with(:to_json_schema).and_return(true)
          allow(s).to receive(:to_json_schema).and_return({ schema: { type: "object", properties: properties,
                                                                      required: required } })
        end
      end

      it "accepts an object that matches the object branch" do
        errors = described_class.validate({ block: { score: 7, assessment: "ok" } }, nullable_block_schema)
        expect(errors).to be_empty
      end

      it "reports a required field missing inside the object branch" do
        errors = described_class.validate({ block: { assessment: "ok" } }, nullable_block_schema)
        expect(errors).to eq(["missing required field: block.score"])
      end

      it "reports a wrong-typed field inside the object branch" do
        errors = described_class.validate({ block: { score: "7", assessment: "ok" } }, nullable_block_schema)
        expect(errors).to eq(["block.score: expected integer, got String"])
      end

      it "reports an additional property inside the object branch" do
        errors = described_class.validate({ block: { score: 7, assessment: "ok", extra: 1 } }, nullable_block_schema)
        expect(errors).to eq(["block.extra: additional property not allowed"])
      end

      it "rejects a value that fits no branch type" do
        errors = described_class.validate({ block: "score 7" }, nullable_block_schema)
        expect(errors).to eq(["block: expected one of object, null, got String"])
      end

      it "still accepts nil through the null branch" do
        errors = described_class.validate({ block: nil }, nullable_block_schema)
        expect(errors).to be_empty
      end

      it "accepts a value matching any one of several scalar branches" do
        schema = raw_schema({ v: { anyOf: [{ type: "integer" }, { type: "string", enum: %w[auto] }] } }, ["v"])
        expect(described_class.validate({ v: 3 }, schema)).to be_empty
        expect(described_class.validate({ v: "auto" }, schema)).to be_empty
      end

      it "reports why a value of a matching type still fails, when only one branch has that type" do
        schema = raw_schema({ v: { anyOf: [{ type: "integer" }, { type: "string", enum: %w[auto] }] } }, ["v"])
        expect(described_class.validate({ v: "manual" }, schema)).to eq([%(v: "manual" is not in enum ["auto"])])
      end

      it "validates every item of an array of anyOf items" do
        schema = raw_schema(
          { items: { type: "array", items: { anyOf: [{ type: "object", properties: { n: { type: "integer" } },
                                                       required: ["n"] }, { type: "null" }] } } },
          ["items"]
        )
        expect(described_class.validate({ items: [{ n: 1 }, nil] }, schema)).to be_empty
        expect(described_class.validate({ items: [{ n: 1 }, {}] },
                                        schema)).to eq(["missing required field: items[1].n"])
      end

      it "rejects a oneOf value that matches more than one branch" do
        schema = raw_schema({ v: { oneOf: [{ type: "number" }, { type: "integer" }] } }, ["v"])
        expect(described_class.validate({ v: 2 }, schema)).to eq(["v: matches 2 oneOf branches, expected exactly 1"])
        expect(described_class.validate({ v: 2.5 }, schema)).to be_empty
      end
    end

    context "type given as an array" do
      let(:schema) do
        double("type_array_schema").tap do |s|
          allow(s).to receive(:respond_to?).with(:to_json_schema).and_return(true)
          allow(s).to receive(:to_json_schema).and_return({ schema: { type: "object",
                                                                      properties: { x: { type: %w[string null] } },
                                                                      required: ["x"] } })
        end
      end

      it "accepts a value of any listed type" do
        expect(described_class.validate({ x: "a" }, schema)).to be_empty
      end

      it "rejects a value of an unlisted type" do
        expect(described_class.validate({ x: 5 }, schema)).to eq(["x: expected string or null, got Integer"])
      end
    end
  end
end
