# frozen_string_literal: true

RSpec.describe "Zero-verify eval (ADR-0005)" do
  before { RubyLLM::Contract.reset_configuration! }

  describe "contract-only report details" do
    it "shows schema field count and validate count" do
      step = Class.new(RubyLLM::Contract::Step::Base) do
        output_schema do
          string :intent
          number :confidence
        end

        prompt "Classify: {input}"
        validate("has intent") { |o| !o[:intent].to_s.empty? }
        validate("high confidence") { |o| o[:confidence] > 0.5 }
      end

      step.define_eval("smoke") do
        default_input "test"
        sample_response({ intent: "billing", confidence: 0.9 })
      end

      report = step.run_eval("smoke")
      expect(report.passed?).to be true

      details = report.results.first.details
      expect(details).to include("schema")
      expect(details).to include("validates")
    end

    it "zero-verify eval passes when sample satisfies contract" do
      step = Class.new(RubyLLM::Contract::Step::Base) do
        prompt "Test: {input}"
        validate("has value") { |o| o[:v].is_a?(Integer) }
      end

      step.define_eval("smoke") do
        default_input "test"
        sample_response({ v: 42 })
      end

      report = step.run_eval("smoke")
      expect(report.passed?).to be true
    end

    it "zero-verify eval fails when sample violates validate" do
      step = Class.new(RubyLLM::Contract::Step::Base) do
        prompt "Test: {input}"
        validate("must be positive") { |o| o[:v] > 0 }
      end

      step.define_eval("smoke") do
        default_input "test"
        sample_response({ v: -1 })
      end

      report = step.run_eval("smoke")
      expect(report.passed?).to be false
    end
  end

  describe "sample_response pre-validation" do
    it "raises at definition time when sample violates schema" do
      step = Class.new(RubyLLM::Contract::Step::Base) do
        output_schema do
          string :intent, enum: %w[sales support billing]
        end
        prompt "Test: {input}"
      end

      expect do
        step.define_eval("bad") do
          default_input "test"
          sample_response({ intent: "INVALID_ENUM" })
        end
      end.to raise_error(ArgumentError, /sample_response.*schema/i)
    end

    it "passes silently when sample is valid" do
      step = Class.new(RubyLLM::Contract::Step::Base) do
        output_schema do
          string :intent, enum: %w[sales support billing]
        end
        prompt "Test: {input}"
      end

      expect do
        step.define_eval("good") do
          default_input "test"
          sample_response({ intent: "billing" })
        end
      end.not_to raise_error
    end

    it "skips pre-validation when step has no schema" do
      step = Class.new(RubyLLM::Contract::Step::Base) do
        prompt "Test: {input}"
      end

      expect do
        step.define_eval("ok") do
          default_input "test"
          sample_response({ anything: "goes" })
        end
      end.not_to raise_error
    end
  end

  describe "backward compat" do
    it "evals with verify blocks work as before" do
      step = Class.new(RubyLLM::Contract::Step::Base) do
        prompt "Test: {input}"
      end

      step.define_eval("custom") do
        default_input "test"
        sample_response({ v: 42 })
        verify "is 42", ->(o) { o[:v] == 42 }
      end

      report = step.run_eval("custom")
      expect(report.passed?).to be true
    end
  end
end
