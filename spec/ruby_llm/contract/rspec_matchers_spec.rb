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

    # Anti-facade F11: previously `with_minimum_score` chain was untested
    # at this level - the matcher could ignore the threshold entirely.
    describe ".with_minimum_score" do
      before do
        step.define_eval("partial") do
          default_input "test"
          sample_response({ intent: "billing", confidence: 0.3 })
          verify "high confidence (fails)", ->(o) { o[:confidence] > 0.5 }
          verify "has intent (passes)", { intent: /billing/ }
        end
      end

      it "passes when score >= threshold" do
        expect(step).to pass_eval("partial").with_minimum_score(0.5)
      end

      it "fails when score < threshold" do
        expect(step).not_to pass_eval("partial").with_minimum_score(0.9)
      end

      it "failure message names the actual score and the threshold" do
        matcher = pass_eval("partial").with_minimum_score(0.9)
        matcher.matches?(step)
        msg = matcher.failure_message
        expect(msg).to include("0.5") # actual score
        expect(msg).to include("0.9") # threshold
      end
    end

    describe ".with_maximum_cost" do
      before do
        step.define_eval("cheap") do
          default_input "test"
          sample_response({ intent: "billing", confidence: 0.9 })
          verify "has intent", { intent: /billing/ }
        end
      end

      it "passes when total_cost is within budget" do
        expect(step).to pass_eval("cheap").with_maximum_cost(1.0)
      end

      # The over-budget path is exercised in cost_of_quality_spec.rb:365
      # with a constructed report. Here we verify the chain attribute
      # round-trips so that swapping `@maximum_cost = nil` would fail.
      it "stores the maximum_cost threshold on the matcher" do
        matcher = pass_eval("cheap").with_maximum_cost(0.05)
        expect(matcher.instance_variable_get(:@maximum_cost)).to eq(0.05)
      end
    end
  end
end
