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
        bom_json = "﻿{\"key\":\"value\"}"
        result = described_class.parse(bom_json, strategy: :json)
        expect(result).to eq({ key: "value" })
      end

      it "parses cleanly when no BOM is present" do
        result = described_class.parse('{"key":"value"}', strategy: :json)
        expect(result).to eq({ key: "value" })
      end

      it "works end-to-end: step with BOM-prefixed JSON response" do
        step = Class.new(RubyLLM::Contract::Step::Base) do
          prompt { user "{input}" }
          output_type RubyLLM::Contract::Types::Hash
          contract { parse :json }
        end

        bom = "\xEF\xBB\xBF"
        adapter = RubyLLM::Contract::Adapters::Test.new(response: "#{bom}{\"status\": \"ok\"}")
        result = step.run("test", context: { adapter: adapter })

        expect(result.status).to eq(:ok)
        expect(result.parsed_output[:status]).to eq("ok")
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

    context "code fence stripping with non-standard language tags" do
      it "strips ```javascript fences" do
        fenced = "```javascript\n{\"key\": \"value\"}\n```"
        result = described_class.parse(fenced, strategy: :json)
        expect(result).to eq({ key: "value" })
      end

      it "strips ```js fences" do
        fenced = "```js\n{\"key\": \"value\"}\n```"
        result = described_class.parse(fenced, strategy: :json)
        expect(result).to eq({ key: "value" })
      end

      it "strips ```jsonc fences" do
        fenced = "```jsonc\n{\"count\": 42}\n```"
        result = described_class.parse(fenced, strategy: :json)
        expect(result).to eq({ count: 42 })
      end

      it "strips ```Json (mixed case) fences" do
        fenced = "```Json\n{\"name\": \"Alice\"}\n```"
        result = described_class.parse(fenced, strategy: :json)
        expect(result).to eq({ name: "Alice" })
      end

      it "strips ```text fences containing JSON" do
        fenced = "```text\n{\"data\": true}\n```"
        result = described_class.parse(fenced, strategy: :json)
        expect(result).to eq({ data: true })
      end
    end

    context "prose extraction edge cases" do
      it "extracts JSON from 'json' prefix without backticks" do
        text = "json\n{\"status\": \"ok\"}"
        result = described_class.parse(text, strategy: :json)
        expect(result).to eq({ status: "ok" })
      end

      it "still raises ParseError when no valid JSON is present" do
        text = "I cannot generate JSON for that request."
        expect do
          described_class.parse(text, strategy: :json)
        end.to raise_error(RubyLLM::Contract::ParseError)
      end
    end

    context "boolean and numeric raw_output" do
      it "handles boolean false without crashing" do
        expect do
          described_class.parse(false, strategy: :json)
        end.not_to raise_error(TypeError)
      end

      it "handles boolean true without crashing" do
        expect do
          described_class.parse(true, strategy: :json)
        end.not_to raise_error(TypeError)
      end

      it "handles integer 0 without crashing" do
        expect do
          described_class.parse(0, strategy: :json)
        end.not_to raise_error(TypeError)
      end

      it "handles integer 42 without crashing" do
        expect do
          described_class.parse(42, strategy: :json)
        end.not_to raise_error(TypeError)
      end

      it "handles float 3.14 without crashing" do
        expect do
          described_class.parse(3.14, strategy: :json)
        end.not_to raise_error(TypeError)
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

      it "handles nested Array/Hash structures" do
        input = [{ "items" => [{ "id" => 1 }, { "id" => 2 }] }]
        result = described_class.parse(input, strategy: :json)
        expect(result).to be_an(Array)
        expect(result.first[:items].first[:id]).to eq(1)
      end

      it "handles Array raw_output in :text strategy" do
        input = [1, 2, 3]
        result = described_class.parse(input, strategy: :text)
        expect(result).to eq([1, 2, 3])
      end
    end
  end
end
