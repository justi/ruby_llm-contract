# frozen_string_literal: true

RSpec.describe "sample_response in define_eval (GH-14)" do
  before { RubyLLM::Contract.reset_configuration! }

  let(:step) do
    Class.new(RubyLLM::Contract::Step::Base) do
      prompt "Classify: {input}"
      validate("has intent") { |o| o[:intent].to_s.size > 0 }
    end
  end

  describe "self-contained eval with sample_response" do
    it "run_eval works without any adapter setup" do
      step.define_eval("smoke") do
        default_input "test query"
        sample_response({ intent: "billing", confidence: 0.9 })
        verify "has intent", { intent: /billing/ }
      end

      report = step.run_eval("smoke")

      expect(report).to be_a(RubyLLM::Contract::Eval::Report)
      expect(report.score).to eq(1.0)
      expect(report.passed?).to be true
    end
  end

  describe "explicit adapter overrides sample_response" do
    it "uses provided adapter, ignores sample_response" do
      step.define_eval("smoke") do
        default_input "test"
        sample_response({ intent: "billing" })
        verify "has intent", { intent: /sales/ }  # won't match "billing"
      end

      # sample_response has "billing" but verify expects "sales" → would fail
      # Override with adapter returning "sales" → should pass
      adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"intent": "sales"}')
      report = step.run_eval("smoke", context: { adapter: adapter })

      expect(report.passed?).to be true
    end
  end

  describe "eval without sample_response" do
    it "works with explicit adapter (backward compat)" do
      step.define_eval("smoke") do
        default_input "test"
        verify "has intent", { intent: /billing/ }
      end

      adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"intent": "billing"}')
      report = step.run_eval("smoke", context: { adapter: adapter })

      expect(report.passed?).to be true
    end
  end

  describe "run_eval all evals with sample_response" do
    it "each eval uses its own sample_response" do
      step.define_eval("smoke") do
        default_input "test"
        sample_response({ intent: "billing" })
        verify "is billing", { intent: "billing" }
      end

      step.define_eval("full") do
        default_input "test"
        sample_response({ intent: "sales", confidence: 0.95 })
        verify "is sales", { intent: "sales" }
      end

      reports = step.run_eval
      expect(reports["smoke"].passed?).to be true
      expect(reports["full"].passed?).to be true
    end
  end

  describe "Pipeline eval with sample_response" do
    it "works on Pipeline" do
      s1 = Class.new(RubyLLM::Contract::Step::Base) do
        prompt "test {input}"
      end

      pipeline = Class.new(RubyLLM::Contract::Pipeline::Base)
      pipeline.step s1, as: :only

      pipeline.define_eval("e2e") do
        default_input "test"
        sample_response({ intent: "billing" })
        verify "has intent", { intent: /billing/ }
      end

      report = pipeline.run_eval("e2e")
      expect(report.passed?).to be true
    end
  end
end
