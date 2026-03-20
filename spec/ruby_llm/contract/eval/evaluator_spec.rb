# frozen_string_literal: true

RSpec.describe "Eval::Evaluator" do
  describe RubyLLM::Contract::Eval::Evaluator::Exact do
    let(:evaluator) { described_class.new }

    it "passes on exact match" do
      result = evaluator.call(output: { intent: "sales" }, expected: { intent: "sales" })
      expect(result.passed).to be true
      expect(result.score).to eq(1.0)
    end

    it "fails on mismatch" do
      result = evaluator.call(output: { intent: "sales" }, expected: { intent: "billing" })
      expect(result.passed).to be false
      expect(result.score).to eq(0.0)
    end
  end

  describe RubyLLM::Contract::Eval::Evaluator::Regex do
    it "passes when pattern matches" do
      evaluator = described_class.new(/billing/)
      result = evaluator.call(output: "I need billing help")
      expect(result.passed).to be true
    end

    it "fails when pattern does not match" do
      evaluator = described_class.new(/billing/)
      result = evaluator.call(output: "I want to buy")
      expect(result.passed).to be false
    end

    it "searches Hash values" do
      evaluator = described_class.new(/billing/)
      result = evaluator.call(output: { intent: "billing", confidence: "0.9" })
      expect(result.passed).to be true
    end
  end

  describe RubyLLM::Contract::Eval::Evaluator::JsonIncludes do
    let(:evaluator) { described_class.new }

    it "passes when all expected keys match" do
      result = evaluator.call(
        output: { intent: "sales", confidence: 0.9, extra: "ignored" },
        expected: { intent: "sales", confidence: 0.9 }
      )
      expect(result.passed).to be true
      expect(result.score).to eq(1.0)
    end

    it "fails on missing key" do
      result = evaluator.call(
        output: { intent: "sales" },
        expected: { intent: "sales", confidence: 0.9 }
      )
      expect(result.passed).to be false
      expect(result.details).to include("missing key: confidence")
    end

    it "fails on value mismatch" do
      result = evaluator.call(
        output: { intent: "billing" },
        expected: { intent: "sales" }
      )
      expect(result.passed).to be false
      expect(result.details).to include("intent")
    end

    it "gives partial score" do
      result = evaluator.call(
        output: { intent: "sales", confidence: 0.5 },
        expected: { intent: "sales", confidence: 0.9 }
      )
      expect(result.score).to eq(0.5) # 1/2 matched
    end

    it "supports regex values" do
      result = evaluator.call(
        output: { intent: "billing_support" },
        expected: { intent: /billing/ }
      )
      expect(result.passed).to be true
    end
  end

  describe RubyLLM::Contract::Eval::Evaluator::ProcEvaluator do
    it "passes when proc returns true" do
      evaluator = described_class.new(->(o) { o[:score] > 5 })
      result = evaluator.call(output: { score: 8 })
      expect(result.passed).to be true
      expect(result.details).to eq("passed")
    end

    it "fails when proc returns false" do
      evaluator = described_class.new(->(o) { o[:score] > 5 })
      result = evaluator.call(output: { score: 2 })
      expect(result.passed).to be false
      expect(result.details).to eq("not passed")
    end

    it "accepts 2-arity proc with input" do
      evaluator = described_class.new(->(output, input) { output[:lang] == input[:lang] })
      result = evaluator.call(output: { lang: "fr" }, input: { lang: "fr" })
      expect(result.passed).to be true
    end

    it "handles numeric return as score" do
      evaluator = described_class.new(->(_o) { 0.75 })
      result = evaluator.call(output: {})
      expect(result.score).to eq(0.75)
      expect(result.passed).to be true # >= 0.5
    end
  end

  describe RubyLLM::Contract::Eval::EvaluationResult do
    it "clamps score to 0.0-1.0" do
      result = described_class.new(score: 1.5, passed: true)
      expect(result.score).to eq(1.0)
    end

    it "defaults label from passed" do
      expect(described_class.new(score: 1.0, passed: true).label).to eq("PASS")
      expect(described_class.new(score: 0.0, passed: false).label).to eq("FAIL")
    end

    it "is frozen" do
      result = described_class.new(score: 1.0, passed: true)
      expect(result).to be_frozen
    end
  end
end
