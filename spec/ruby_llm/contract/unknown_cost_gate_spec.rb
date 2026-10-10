# frozen_string_literal: true

require "tmpdir"
require "ruby_llm/contract/rake_task"
require "ruby_llm/contract/minitest"
require "ruby_llm/contract/rspec"

# A report's total_cost counts an unpriced case as 0.0, so a maximum_cost gate
# comparing totals alone passed whatever an unpriced model really cost.
RSpec.describe "maximum_cost gates on unknown cost" do
  before do
    RubyLLM::Contract.reset_configuration!
    RubyLLM::Contract.reset_eval_hosts!
  end

  let(:unpriced_model) { "no-pricing-model-xyz" }
  let(:spending_adapter) do
    RubyLLM::Contract::Adapters::Test.new(response: '{"label":"x"}', usage: { input_tokens: 1_000, output_tokens: 500 })
  end
  let(:zero_token_adapter) { RubyLLM::Contract::Adapters::Test.new(response: '{"label":"x"}') }

  def step_with_eval
    klass = Class.new(RubyLLM::Contract::Step::Base) do
      def self.name = "UnknownCostProbe"

      input_type String
      output_type Hash
      prompt { user "Classify: {input}" }
    end
    klass.define_eval("smoke") { add_case "case_1", input: "test", expected: { label: "x" } }
    klass
  end

  describe "Step::Trace#cost_unknown?" do
    def trace(**attrs) = RubyLLM::Contract::Step::Trace.new(**attrs)

    it "is true only for a named model that used tokens and got no cost" do
      tokens = { input_tokens: 10, output_tokens: 5 }

      expect(trace(model: unpriced_model, usage: tokens).cost_unknown?).to be(true)
      expect(trace(model: unpriced_model, usage: { input_tokens: 0, output_tokens: 0 }).cost_unknown?).to be(false)
      expect(trace(model: nil, usage: tokens).cost_unknown?).to be(false)
      expect(trace(model: unpriced_model, usage: tokens, cost: 0.01).cost_unknown?).to be(false)
    end

    it "judges a retried step per attempt, so a priced subtotal cannot hide an unpriced attempt" do
      attempts = [
        { attempt: 1, model: "priced", usage: { input_tokens: 10, output_tokens: 5 }, cost: 0.01 },
        { attempt: 2, model: unpriced_model, usage: { input_tokens: 10, output_tokens: 5 } }
      ]

      expect(trace(model: unpriced_model, usage: { input_tokens: 20, output_tokens: 10 },
                   attempts: attempts, cost: 0.01).cost_unknown?).to be(true)
    end
  end

  describe "Pipeline::Trace#cost_unknown?" do
    it "is true when any step trace is" do
      priced = RubyLLM::Contract::Step::Trace.new(model: "m", usage: { input_tokens: 1, output_tokens: 1 }, cost: 0.1)
      unpriced = RubyLLM::Contract::Step::Trace.new(model: unpriced_model, usage: { input_tokens: 1, output_tokens: 1 })

      expect(RubyLLM::Contract::Pipeline::Trace.new(step_traces: [priced, unpriced]).cost_unknown?).to be(true)
      expect(RubyLLM::Contract::Pipeline::Trace.new(step_traces: [priced]).cost_unknown?).to be(false)
    end
  end

  describe "report" do
    it "lists the unpriced case and keeps cost_unknown out of to_h for priced cases" do
      report = step_with_eval.run_eval("smoke", context: { adapter: spending_adapter, model: unpriced_model })

      expect(report.unknown_cost_results.map(&:name)).to eq(["case_1"])
      expect(report.results.first.to_h).to include(cost_unknown: true)

      offline = step_with_eval.run_eval("smoke", context: { adapter: zero_token_adapter, model: unpriced_model })
      expect(offline.unknown_cost_results).to be_empty
      expect(offline.results.first.to_h).not_to have_key(:cost_unknown)
    end

    it "keeps the flag when a failed step expectation rebuilds a pipeline case" do
      step = Class.new(RubyLLM::Contract::Step::Base) do
        input_type String
        output_type Hash
        prompt { user "{input}" }
      end
      pipeline = Class.new(RubyLLM::Contract::Pipeline::Base) do
        step step, as: :classify
        step step, as: :route
      end
      pipeline.define_eval("e2e") do
        add_case "billing", input: "charged twice", step_expectations: { classify: { priority: "low" } }
      end
      adapter = RubyLLM::Contract::Adapters::Test.new(
        responses: ['{"priority":"high"}', '{"team":"billing"}'], usage: { input_tokens: 100, output_tokens: 50 }
      )

      report = pipeline.run_eval("e2e", context: { adapter: adapter, model: unpriced_model })

      expect(report.results.first.step_status).to eq(:step_expectation_failed)
      expect(report.unknown_cost_results.map(&:name)).to eq(["billing"])
    end
  end

  describe "rake task" do
    def run_task(context:, **settings)
      step_with_eval
      task = RubyLLM::Contract::RakeTask.new(:"unknown_cost_#{rand(100_000)}") do |t|
        t.context = context
        settings.each { |key, value| t.public_send(:"#{key}=", value) }
      end
      Rake::Task[task.name].invoke
    end

    it "aborts when maximum_cost is set and a case has unknown cost" do
      expect do
        expect { run_task(context: { adapter: spending_adapter, model: unpriced_model }, maximum_cost: 1.0) }
          .to raise_error(SystemExit, /1 case\(s\) have unknown cost.*case_1.*on_unknown_pricing/)
      end.to output.to_stdout
    end

    it "passes with a warning under on_unknown_pricing :warn" do
      expect(RubyLLM::Contract::Eval::UnknownCostGate).to receive(:warn).with(/unknown cost.*case_1/)
      expect do
        run_task(context: { adapter: spending_adapter, model: unpriced_model },
                 maximum_cost: 1.0, on_unknown_pricing: :warn)
      end.to output(/All evals passed/).to_stdout
    end

    it "does not check pricing without maximum_cost, nor for zero-token offline runs" do
      expect do
        run_task(context: { adapter: spending_adapter, model: unpriced_model })
        run_task(context: { adapter: zero_token_adapter, model: unpriced_model }, maximum_cost: 1.0)
      end.to output(/All evals passed.*All evals passed/m).to_stdout
    end

    it "rejects an unknown mode when the task is defined, before any eval runs" do
      expect { RubyLLM::Contract::RakeTask.new(:"bad_mode_#{rand(100_000)}") { |t| t.on_unknown_pricing = :ignore } }
        .to raise_error(ArgumentError, /must be :refuse or :warn/)
    end
  end

  describe "pass_eval" do
    let(:context) { { adapter: spending_adapter, model: unpriced_model } }

    it "fails with_maximum_cost and names the unpriced case" do
      matcher = pass_eval("smoke").with_context(context).with_maximum_cost(1.0)

      expect(matcher.matches?(step_with_eval)).to be(false)
      expect(matcher.failure_message).to match(/stay within maximum cost.*unknown cost.*case_1/)
    end

    it "still checks the budget against priced cases under on_unknown_pricing(:warn)" do
      RubyLLM::Contract::CostCalculator.register_model("pricey-model", input_per_1m: 1_000.0, output_per_1m: 1_000.0)
      pricey = Class.new(RubyLLM::Contract::Step::Base) do
        model "pricey-model"
        input_type String
        output_type Hash
        prompt { user "{input}" }
      end
      unpriced = Class.new(pricey) do
        model "no-pricing-model-xyz"
        input_type Hash
      end
      pipeline = Class.new(RubyLLM::Contract::Pipeline::Base) do
        step pricey, as: :first
        step unpriced, as: :second
      end
      pipeline.define_eval("e2e") { add_case "c", input: "x" }
      adapter = RubyLLM::Contract::Adapters::Test.new(
        responses: ['{"a":1}', '{"b":2}'], usage: { input_tokens: 1_000, output_tokens: 500 }
      )
      allow(RubyLLM::Contract::Eval::UnknownCostGate).to receive(:warn)

      matcher = pass_eval("e2e").with_context(adapter: adapter).with_maximum_cost(0.0001).on_unknown_pricing(:warn)

      expect(matcher.matches?(pipeline)).to be(false)
      expect(matcher.failure_message).to match(/eval cost <= \$0\.0001/)
    ensure
      RubyLLM::Contract::CostCalculator.reset_custom_models!
    end

    it "lists other failures after the unknown cost, and lets an exception outrank it" do
      wrong_label = RubyLLM::Contract::Adapters::Test.new(response: '{"label":"y"}',
                                                          usage: { input_tokens: 10, output_tokens: 5 })
      failing = { adapter: wrong_label, model: unpriced_model }
      matcher = pass_eval("smoke").with_context(failing).with_maximum_cost(1.0)

      expect(matcher.matches?(step_with_eval)).to be(false)
      expect(matcher.failure_message).to match(/unknown cost.*case_1.*FAIL\s+case_1/m)

      Dir.mktmpdir do |dir|
        Dir.chdir(dir) do
          step = step_with_eval
          File.write(step.run_eval("smoke", context: context).save_baseline!, "{not json")
          matcher = pass_eval("smoke").with_context(context).with_maximum_cost(1.0).without_regressions

          expect(matcher.matches?(step)).to be(false)
          expect(matcher.failure_message).to include("raised an error")
          expect(matcher.failure_message).not_to include("unknown cost")
        end
      end
    end

    it "passes under on_unknown_pricing(:warn)" do
      expect(RubyLLM::Contract::Eval::UnknownCostGate).to receive(:warn).with(/unknown cost/)
      expect(step_with_eval).to pass_eval("smoke").with_context(context).with_maximum_cost(1.0)
                                                  .on_unknown_pricing(:warn)
    end
  end

  describe "assert_eval_passes" do
    include RubyLLM::Contract::MinitestHelpers

    def assert(condition, message = nil)
      raise message unless condition
    end

    it "fails with maximum_cost on unknown cost, passes under on_unknown_pricing: :warn" do
      context = { adapter: spending_adapter, model: unpriced_model }

      expect { assert_eval_passes(step_with_eval, "smoke", maximum_cost: 1.0, context: context) }
        .to raise_error(RuntimeError, /unknown cost.*case_1/)
      expect(RubyLLM::Contract::Eval::UnknownCostGate).to receive(:warn).with(/unknown cost/)
      assert_eval_passes(step_with_eval, "smoke", maximum_cost: 1.0, context: context, on_unknown_pricing: :warn)
    end
  end
end
