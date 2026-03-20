# frozen_string_literal: true

require "ruby_llm/contract/rspec"

RSpec.describe "RSpec matchers (GH-16)" do
  before { RubyLLM::Contract.reset_configuration! }

  let(:good_adapter) { RubyLLM::Contract::Adapters::Test.new(response: '{"intent": "billing", "confidence": 0.9}') }
  let(:bad_adapter) { RubyLLM::Contract::Adapters::Test.new(response: '{"intent": "INVALID"}') }

  let(:step) do
    Class.new(RubyLLM::Contract::Step::Base) do
      prompt "Classify: {input}"
      validate("valid intent") { |o| %w[sales support billing].include?(o[:intent]) }
      validate("has confidence") { |o| o[:confidence].is_a?(Numeric) }
    end
  end

  # =========================================================================
  # satisfy_contract
  # =========================================================================

  describe "satisfy_contract" do
    it "passes when result is :ok" do
      result = step.run("test", context: { adapter: good_adapter })
      expect(result).to satisfy_contract
    end

    it "fails when result has validation errors" do
      result = step.run("test", context: { adapter: bad_adapter })
      expect(result).not_to satisfy_contract
    end

    it "failure message shows validation errors" do
      result = step.run("test", context: { adapter: bad_adapter })

      matcher = satisfy_contract
      matcher.matches?(result)
      msg = matcher.failure_message

      expect(msg).to include("validation_failed")
      expect(msg).to include("valid intent")
      expect(msg).to include("Raw output")
    end

    it "failure message shows raw output" do
      result = step.run("test", context: { adapter: bad_adapter })

      matcher = satisfy_contract
      matcher.matches?(result)
      msg = matcher.failure_message

      expect(msg).to include("INVALID")
    end

    it "works with parse_error" do
      bad = RubyLLM::Contract::Adapters::Test.new(response: "not json at all")
      result = step.run("test", context: { adapter: bad })
      expect(result).not_to satisfy_contract
    end

    it "negated matcher works" do
      result = step.run("test", context: { adapter: good_adapter })

      matcher = satisfy_contract
      matcher.matches?(result)
      msg = matcher.failure_message_when_negated

      expect(msg).to include("NOT to satisfy contract")
    end
  end

  # =========================================================================
  # pass_eval
  # =========================================================================

  describe "pass_eval" do
    before do
      step.define_eval("smoke") do
        default_input "test query"
        sample_response({ intent: "billing", confidence: 0.9 })
        verify "has intent", { intent: /billing/ }
        verify "confident", ->(o) { o[:confidence] > 0.5 }
      end
    end

    it "passes when all eval cases pass" do
      expect(step).to pass_eval("smoke")
    end

    it "fails when eval cases fail" do
      step.define_eval("strict") do
        default_input "test"
        sample_response({ intent: "billing", confidence: 0.9 })
        verify "impossible", ->(o) { o[:intent] == "nonexistent" }
      end

      expect(step).not_to pass_eval("strict")
    end

    it "failure message shows per-case details" do
      step.define_eval("failing") do
        default_input "test"
        sample_response({ intent: "billing", confidence: 0.3 })
        verify "high confidence", ->(o) { o[:confidence] > 0.5 }
      end

      matcher = pass_eval("failing")
      matcher.matches?(step)
      msg = matcher.failure_message

      expect(msg).to include("FAIL")
      expect(msg).to include("high confidence")
    end

    it "supports with_context chain for adapter override" do
      step.define_eval("live") do
        default_input "test"
        verify "has intent", { intent: /billing/ }
      end

      expect(step).to pass_eval("live").with_context(adapter: good_adapter)
    end

    it "negated matcher works" do
      matcher = pass_eval("smoke")
      matcher.matches?(step)
      msg = matcher.failure_message_when_negated

      expect(msg).to include("NOT to pass")
    end

    it "catches errors gracefully instead of raising" do
      matcher = pass_eval("nonexistent")
      result = matcher.matches?(step)

      expect(result).to be false
      expect(matcher.failure_message).to include("raised an error")
      expect(matcher.failure_message).to include("No eval 'nonexistent'")
    end
  end
end
