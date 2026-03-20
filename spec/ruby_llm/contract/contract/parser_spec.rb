# frozen_string_literal: true

RSpec.describe RubyLLM::Contract::Parser do
  describe ".parse" do
    context "with :json strategy" do
      it "parses valid JSON and returns the data structure" do
        result = described_class.parse('{"intent":"sales"}', strategy: :json)
        expect(result).to eq({ intent: "sales" })
      end

      it "parses JSON arrays" do
        result = described_class.parse("[1, 2, 3]", strategy: :json)
        expect(result).to eq([1, 2, 3])
      end

      it "raises ParseError for malformed JSON" do
        expect do
          described_class.parse("not valid json", strategy: :json)
        end.to raise_error(RubyLLM::Contract::ParseError, /Failed to parse JSON/)
      end

      it "includes raw output in the error details" do
        described_class.parse("bad json", strategy: :json)
      rescue RubyLLM::Contract::ParseError => e
        expect(e.details).to eq("bad json")
      end
    end

    context "with :text strategy" do
      it "returns the raw string unchanged" do
        result = described_class.parse("hello world", strategy: :text)
        expect(result).to eq("hello world")
      end
    end

    context "with unknown strategy" do
      it "raises ArgumentError" do
        expect do
          described_class.parse("data", strategy: :xml)
        end.to raise_error(ArgumentError, "Unknown parse strategy: xml")
      end
    end

    context "BOM stripping" do
      it "strips UTF-8 BOM from the beginning of JSON" do
        bom_json = "\xEF\xBB\xBF" + '{"key":"value"}'
        result = described_class.parse(bom_json, strategy: :json)
        expect(result).to eq({ key: "value" })
      end

      it "parses cleanly when no BOM is present" do
        result = described_class.parse('{"key":"value"}', strategy: :json)
        expect(result).to eq({ key: "value" })
      end
    end

    context "code fence stripping" do
      it "strips ```json ... ``` fences from JSON output" do
        fenced = "```json\n{\"key\":\"value\"}\n```"
        result = described_class.parse(fenced, strategy: :json)
        expect(result).to eq({ key: "value" })
      end

      it "strips ``` ... ``` fences without language tag" do
        fenced = "```\n{\"items\":[1,2]}\n```"
        result = described_class.parse(fenced, strategy: :json)
        expect(result).to eq({ items: [1, 2] })
      end
    end

    context "JSON extraction from prose" do
      it "extracts JSON object embedded in surrounding text" do
        prose = "Here is the result:\n{\"intent\":\"sales\"}\nThat's my answer."
        result = described_class.parse(prose, strategy: :json)
        expect(result).to eq({ intent: "sales" })
      end

      it "extracts JSON array embedded in surrounding text" do
        prose = "The items are: [1, 2, 3] and that's it."
        result = described_class.parse(prose, strategy: :json)
        expect(result).to eq([1, 2, 3])
      end
    end

    context "Hash/Array passthrough" do
      it "passes through a Hash without re-parsing, symbolizing keys" do
        result = described_class.parse({ "name" => "Alice", "age" => 30 }, strategy: :json)
        expect(result).to eq({ name: "Alice", age: 30 })
      end

      it "passes through an Array, symbolizing nested Hash keys" do
        result = described_class.parse([{ "id" => 1 }, { "id" => 2 }], strategy: :json)
        expect(result).to eq([{ id: 1 }, { id: 2 }])
      end
    end
  end
end
