# frozen_string_literal: true

RSpec.describe "Parser.symbolize_keys (deep)" do
  let(:parser) { RubyLLM::Contract::Parser }

  describe "flat hash" do
    it "symbolizes string keys" do
      expect(parser.symbolize_keys({ "a" => 1, "b" => 2 })).to eq({ a: 1, b: 2 })
    end

    it "keeps already-symbol keys" do
      expect(parser.symbolize_keys({ a: 1, b: 2 })).to eq({ a: 1, b: 2 })
    end

    it "handles mixed string/symbol keys" do
      expect(parser.symbolize_keys({ "a" => 1, b: 2 })).to eq({ a: 1, b: 2 })
    end

    it "handles empty hash" do
      expect(parser.symbolize_keys({})).to eq({})
    end
  end

  describe "nested hashes" do
    it "symbolizes 2 levels deep" do
      input = { "a" => { "b" => 1 } }
      expect(parser.symbolize_keys(input)).to eq({ a: { b: 1 } })
    end

    it "symbolizes 3 levels deep" do
      input = { "a" => { "b" => { "c" => "deep" } } }
      expect(parser.symbolize_keys(input)).to eq({ a: { b: { c: "deep" } } })
    end

    it "handles empty nested hash" do
      input = { "a" => {} }
      expect(parser.symbolize_keys(input)).to eq({ a: {} })
    end
  end

  describe "arrays" do
    it "symbolizes hashes inside arrays" do
      input = { "items" => [{ "name" => "Alice" }, { "name" => "Bob" }] }
      expect(parser.symbolize_keys(input)).to eq({ items: [{ name: "Alice" }, { name: "Bob" }] })
    end

    it "leaves array of strings unchanged" do
      input = { "tags" => %w[ruby llm] }
      expect(parser.symbolize_keys(input)).to eq({ tags: %w[ruby llm] })
    end

    it "leaves array of integers unchanged" do
      input = { "scores" => [1, 2, 3] }
      expect(parser.symbolize_keys(input)).to eq({ scores: [1, 2, 3] })
    end

    it "handles empty array" do
      input = { "items" => [] }
      expect(parser.symbolize_keys(input)).to eq({ items: [] })
    end

    it "handles mixed array (hashes and primitives)" do
      input = { "data" => [{ "id" => 1 }, "plain", 42, nil] }
      expect(parser.symbolize_keys(input)).to eq({ data: [{ id: 1 }, "plain", 42, nil] })
    end

    it "handles nested arrays" do
      input = { "matrix" => [[{ "v" => 1 }], [{ "v" => 2 }]] }
      expect(parser.symbolize_keys(input)).to eq({ matrix: [[{ v: 1 }], [{ v: 2 }]] })
    end
  end

  describe "real-world: reddit promo planner shape" do
    it "symbolizes the full target audience response" do
      input = {
        "locale" => "en",
        "description" => "Invoicing tool for freelancers",
        "groups" => [
          {
            "who" => "I'm a freelancer struggling with invoicing",
            "use_cases" => ["I lose track of who paid", "Clients forget to pay"],
            "not_covered" => ["Enterprise billing", "Physical retail POS"],
            "good_fit_threads" => ["anyone else hate chasing invoices?"],
            "bad_fit_threads" => ["best POS system for my restaurant?"]
          }
        ]
      }

      result = parser.symbolize_keys(input)

      expect(result[:locale]).to eq("en")
      expect(result[:groups][0][:who]).to eq("I'm a freelancer struggling with invoicing")
      expect(result[:groups][0][:use_cases]).to eq(["I lose track of who paid", "Clients forget to pay"])
      expect(result[:groups][0][:not_covered].first).to eq("Enterprise billing")
    end
  end

  describe "primitives pass through" do
    it("string") { expect(parser.symbolize_keys("hello")).to eq("hello") }
    it("integer") { expect(parser.symbolize_keys(42)).to eq(42) }
    it("nil") { expect(parser.symbolize_keys(nil)).to be_nil }
    it("float") { expect(parser.symbolize_keys(3.14)).to eq(3.14) }
    it("boolean") { expect(parser.symbolize_keys(true)).to eq(true) }
  end

  describe "nil values" do
    it "handles nil values in hash" do
      input = { "a" => nil, "b" => 1 }
      expect(parser.symbolize_keys(input)).to eq({ a: nil, b: 1 })
    end

    it "handles nil inside array" do
      input = { "items" => [nil, { "id" => 1 }, nil] }
      expect(parser.symbolize_keys(input)).to eq({ items: [nil, { id: 1 }, nil] })
    end
  end

  describe "integration: step with adapter returning Hash" do
    before { RubyLLM::Contract.reset_configuration! }

    it "validate blocks can access deeply nested symbol keys" do
      step = Class.new(RubyLLM::Contract::Step::Base) do
        prompt "test {input}"
        validate("has nested key") { |o| o[:groups][0][:who] == "Alice" }
      end

      hash_adapter = Class.new(RubyLLM::Contract::Adapters::Base) do
        define_method(:call) do |messages:, **_options|
          RubyLLM::Contract::Adapters::Response.new(
            content: { "groups" => [{ "who" => "Alice", "tags" => ["ruby"] }] },
            usage: { input_tokens: 10, output_tokens: 5 }
          )
        end
      end.new

      result = step.run("test", context: { adapter: hash_adapter })

      expect(result.status).to eq(:ok)
      expect(result.parsed_output[:groups][0][:who]).to eq("Alice")
      expect(result.parsed_output[:groups][0][:tags]).to eq(["ruby"])
    end
  end
end
