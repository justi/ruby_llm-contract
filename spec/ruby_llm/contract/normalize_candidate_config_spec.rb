# frozen_string_literal: true

RSpec.describe "RubyLLM::Contract.normalize_candidate_config" do
  subject(:normalize) { ->(entry) { RubyLLM::Contract.normalize_candidate_config(entry) } }

  describe "string input" do
    it "wraps in hash with :model key" do
      expect(normalize.("gpt-4.1-mini")).to eq({ model: "gpt-4.1-mini" })
    end

    it "strips whitespace" do
      expect(normalize.("  gpt-4.1-mini  ")).to eq({ model: "gpt-4.1-mini" })
    end

    it "raises on empty string" do
      expect { normalize.("") }.to raise_error(ArgumentError, /non-empty/)
    end

    it "raises on whitespace-only string" do
      expect { normalize.("   ") }.to raise_error(ArgumentError, /non-empty/)
    end
  end

  describe "hash input with symbol keys" do
    it "returns normalized hash with model" do
      expect(normalize.({ model: "gpt-4.1-mini" })).to eq({ model: "gpt-4.1-mini" })
    end

    it "includes reasoning_effort when present" do
      result = normalize.({ model: "gpt-5-mini", reasoning_effort: "high" })
      expect(result).to eq({ model: "gpt-5-mini", reasoning_effort: "high" })
    end

    it "excludes reasoning_effort when nil" do
      result = normalize.({ model: "gpt-4.1-mini", reasoning_effort: nil })
      expect(result).to eq({ model: "gpt-4.1-mini" })
    end
  end

  describe "hash input with string keys" do
    it "normalizes string keys to symbols" do
      result = normalize.({ "model" => "gpt-4.1-mini" })
      expect(result).to eq({ model: "gpt-4.1-mini" })
    end

    it "handles string reasoning_effort key" do
      result = normalize.({ "model" => "gpt-5-mini", "reasoning_effort" => "low" })
      expect(result).to eq({ model: "gpt-5-mini", reasoning_effort: "low" })
    end
  end

  describe "validation" do
    it "raises when hash has no :model key" do
      expect { normalize.({ reasoning_effort: "high" }) }.to raise_error(ArgumentError, /must include/)
    end

    it "raises when model value is nil" do
      expect { normalize.({ model: nil }) }.to raise_error(ArgumentError, /must include/)
    end

    it "raises when model value is not a string" do
      expect { normalize.({ model: 123 }) }.to raise_error(ArgumentError, /must include/)
    end

    it "raises for non-String/Hash input" do
      expect { normalize.(123) }.to raise_error(ArgumentError, /Expected String or Hash/)
      expect { normalize.(nil) }.to raise_error(ArgumentError, /Expected String or Hash/)
    end
  end

  describe "returns a new hash (no caller mutation)" do
    it "does not freeze the caller's hash" do
      original = { model: "gpt-4.1-mini", reasoning_effort: "low" }
      normalize.(original)
      expect(original).not_to be_frozen
    end

    it "returns a different object from the input" do
      original = { model: "gpt-4.1-mini" }
      result = normalize.(original)
      expect(result).not_to equal(original)
    end
  end
end
