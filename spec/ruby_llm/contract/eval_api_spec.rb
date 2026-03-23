# frozen_string_literal: true

RSpec.describe "define_eval / run_eval API (GH-13)" do
  before { RubyLLM::Contract.reset_configuration! }

  let(:good_response) { '{"intent": "billing", "confidence": 0.9}' }
  let(:adapter) { RubyLLM::Contract::Adapters::Test.new(response: good_response) }

  let(:step) do
    Class.new(RubyLLM::Contract::Step::Base) do
      input_type String
      output_type Hash
      prompt { user "{input}" }
      validate("has intent") { |o| !o[:intent].to_s.empty? }
    end
  end

  describe "define_eval + run_eval on Step" do
    it "registers and runs a named eval" do
      step.define_eval("smoke") do
        default_input "test query"
        verify "has intent", { intent: /billing/ }
      end

      report = step.run_eval("smoke", context: { adapter: adapter })

      expect(report).to be_a(RubyLLM::Contract::Eval::Report)
      expect(report.score).to eq(1.0)
      expect(report.passed?).to be true
    end

    it "verify with Hash uses json_includes" do
      step.define_eval("hash_test") do
        default_input "query"
        verify "intent is billing", { intent: "billing" }
      end

      report = step.run_eval("hash_test", context: { adapter: adapter })
      expect(report.passed?).to be true
    end

    it "verify with Regexp uses regex evaluator" do
      step.define_eval("regex_test") do
        default_input "query"
        verify "intent matches", /billing/
      end

      report = step.run_eval("regex_test", context: { adapter: adapter })
      expect(report.passed?).to be true
    end

    it "verify with Proc uses custom evaluator" do
      step.define_eval("proc_test") do
        default_input "query"
        verify "confidence high", ->(o) { o[:confidence] > 0.5 }
      end

      report = step.run_eval("proc_test", context: { adapter: adapter })
      expect(report.passed?).to be true
    end

    it "default_input applies to all cases" do
      step.define_eval("defaults") do
        default_input "shared input"
        verify "case 1", { intent: /billing/ }
        verify "case 2", ->(o) { o[:confidence] > 0.5 }
      end

      report = step.run_eval("defaults", context: { adapter: adapter })
      expect(report.pass_rate).to eq("2/2")
    end

    it "per-case input overrides default" do
      step.define_eval("override") do
        default_input "default"
        verify "with override", input: "custom input", expect: { intent: /billing/ }
      end

      report = step.run_eval("override", context: { adapter: adapter })
      expect(report.passed?).to be true
    end

    it "run_eval without name runs all evals" do
      step.define_eval("smoke") do
        default_input "q"
        verify "has intent", { intent: /billing/ }
      end

      step.define_eval("full") do
        default_input "q"
        verify "has intent", { intent: /billing/ }
        verify "high confidence", ->(o) { o[:confidence] > 0.5 }
      end

      reports = step.run_eval(context: { adapter: adapter })

      expect(reports).to be_a(Hash)
      expect(reports.keys).to contain_exactly("smoke", "full")
      expect(reports["smoke"].passed?).to be true
      expect(reports["full"].passed?).to be true
    end

    it "raises on unknown eval name" do
      expect { step.run_eval("nonexistent", context: { adapter: adapter }) }
        .to raise_error(ArgumentError, /No eval 'nonexistent'/)
    end
  end

  describe "define_eval + run_eval on Pipeline" do
    it "works on Pipeline::Base" do
      s1 = Class.new(RubyLLM::Contract::Step::Base) do
        input_type String
        output_type Hash
        prompt { user "{input}" }
      end

      pipeline = Class.new(RubyLLM::Contract::Pipeline::Base)
      pipeline.step s1, as: :only

      pipeline.define_eval("e2e") do
        default_input "test"
        verify "has intent", { intent: /billing/ }
      end

      report = pipeline.run_eval("e2e", context: { adapter: adapter })
      expect(report.passed?).to be true
    end
  end

  describe "to_s on Report" do
    it "prints cleanly" do
      step.define_eval("smoke") do
        default_input "q"
        verify "has intent", { intent: /billing/ }
      end

      report = step.run_eval("smoke", context: { adapter: adapter })
      expect(report.to_s).to eq("smoke: 1/1 checks passed")
    end
  end
end
