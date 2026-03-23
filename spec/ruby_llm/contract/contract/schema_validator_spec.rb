# frozen_string_literal: true

require "ruby_llm/schema"

RSpec.describe RubyLLM::Contract::SchemaValidator do
  let(:schema) do
    RubyLLM::Schema.create do
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
    end
  end
end
