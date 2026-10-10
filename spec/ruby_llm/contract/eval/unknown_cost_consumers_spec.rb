# frozen_string_literal: true

require "json"
require "tmpdir"

# A report's total_cost is a subtotal over the cases it could price. Rankings,
# savings, single-shot cost and saved files must not read that subtotal as the
# whole cost.
RSpec.describe "Consumers of a cost that is only a subtotal" do
  def case_result(name, cost:, cost_unknown: false, attempts: nil, score: 1.0)
    RubyLLM::Contract::Eval::CaseResult.new(
      name: name, input: "x", output: {}, expected: {}, step_status: :ok, score: score, passed: score >= 1.0,
      cost: cost, cost_unknown: cost_unknown, attempts: attempts
    )
  end

  def report(*results)
    RubyLLM::Contract::Eval::Report.new(dataset_name: "smoke", results: results, step_name: "Probe")
  end

  # Priced at $0.004 a case over two cases.
  let(:priced) { report(case_result("a", cost: 0.004), case_result("b", cost: 0.004)) }
  # One case priced at $0.001, the other unpriced: the $0.001 subtotal looks cheapest.
  let(:partly_unpriced) { report(case_result("a", cost: 0.001), case_result("b", cost: nil, cost_unknown: true)) }

  def comparison(reports, configs: nil)
    RubyLLM::Contract::Eval::ModelComparison.new(eval_name: "smoke", reports: reports, configs: configs)
  end

  describe "ModelComparison" do
    it "does not name a model with unpriced cases the cheapest" do
      cmp = comparison({ "priced-model" => priced, "partial-model" => partly_unpriced })

      expect(cmp.best_for).to eq("priced-model")
    end

    it "names no cheapest model when none could be fully priced" do
      expect(comparison({ "partial-model" => partly_unpriced }).best_for).to be_nil
    end

    it "gives a model with unpriced cases no cost per point" do
      cmp = comparison({ "priced-model" => priced, "partial-model" => partly_unpriced })

      expect(cmp.cost_per_point).to eq("priced-model" => 0.008, "partial-model" => Float::INFINITY)
    end
  end

  describe "Recommender" do
    def recommend(current: nil)
      cmp = comparison({ "priced-model" => priced, "partial-model" => partly_unpriced },
                       configs: { "priced-model" => { model: "priced-model" },
                                  "partial-model" => { model: "partial-model" } })
      RubyLLM::Contract::Eval::Recommender.new(comparison: cmp, min_score: 0.5, current_config: current).recommend
    end

    it "does not recommend a model ranked on a subtotal" do
      expect(recommend.best).to eq(model: "priced-model")
      expect(recommend.warnings).to include(a_string_including("partial-model: unknown pricing"))
    end

    it "promises no savings against a current model whose cost is only a subtotal" do
      cheap = report(case_result("a", cost: 0.0001), case_result("b", cost: 0.0001))
      cmp = comparison({ "partial-model" => partly_unpriced, "cheap-model" => cheap },
                       configs: { "partial-model" => { model: "partial-model" },
                                  "cheap-model" => { model: "cheap-model" } })
      rec = RubyLLM::Contract::Eval::Recommender.new(comparison: cmp, min_score: 0.5,
                                                     current_config: { model: "partial-model" }).recommend

      expect(rec.best).to eq(model: "cheap-model")
      expect(rec.savings).to eq({})
    end
  end

  describe "single-shot cost" do
    it "counts only the first attempt, not a later attempt's spend, when the first was unpriced" do
      attempts = [{ attempt: 1, model: "unpriced", cost_unknown: true },
                  { attempt: 2, model: "priced", cost: 0.02 }]
      escalated = report(case_result("a", cost: 0.02, cost_unknown: true, attempts: attempts))

      expect(escalated.single_shot_cost).to eq(0.0)
    end

    it "uses the first attempt's cost when it was priced" do
      attempts = [{ attempt: 1, model: "m", cost: 0.003 }, { attempt: 2, model: "n", cost: 0.02 }]

      expect(report(case_result("a", cost: 0.023, attempts: attempts)).single_shot_cost).to eq(0.003)
    end
  end

  describe "saved baselines and history" do
    it "marks unpriced cases and runs, and leaves fully priced ones as before" do
      Dir.mktmpdir do |dir|
        baseline = JSON.parse(File.read(partly_unpriced.save_baseline!(path: File.join(dir, "b.json"))))
        expect(baseline["cases"].map { |c| c["cost_unknown"] }).to eq([nil, true])

        partly_unpriced.save_history!(path: File.join(dir, "h.jsonl"))
        priced.save_history!(path: File.join(dir, "h.jsonl"))
        runs = File.readlines(File.join(dir, "h.jsonl")).map { |line| JSON.parse(line) }
        expect(runs.map { |r| r["cost_unknown"] }).to eq([true, nil])
        expect(partly_unpriced.eval_history(path: File.join(dir, "h.jsonl")).to_s).to include("+ unknown")
      end
    end
  end
end

RSpec.describe "Incomplete token counts outside eval reports" do
  let(:incomplete_adapter) do
    Class.new(RubyLLM::Contract::Adapters::Base) do
      def call(messages:, **_options) # rubocop:disable Lint/UnusedMethodArgument
        RubyLLM::Contract::Adapters::Response.new(
          content: '{"v": 1}', usage: { input_tokens: 0, output_tokens: 0 },
          cost: nil, cost_complete: false, usage_complete: false
        )
      end
    end.new
  end
  let(:step) { Class.new(RubyLLM::Contract::Step::Base) { prompt "test {input}" } }

  def pipeline(budget)
    Class.new(RubyLLM::Contract::Pipeline::Base).tap do |klass|
      klass.step step, as: :only
      klass.token_budget budget if budget
    end
  end

  it "warns that a token_budget was checked against counts a provider left out" do
    result = nil
    expect { result = pipeline(1_000).run("x", context: { adapter: incomplete_adapter }) }
      .to output(/token_budget checked against incomplete token counts/).to_stderr
    expect(result.trace.usage_complete?).to be(false)
  end

  it "does not warn without a token_budget" do
    expect { pipeline(nil).run("x", context: { adapter: incomplete_adapter }) }.not_to output.to_stderr
  end

  it "logs an unknown cost as unknown, not as $0" do
    io = StringIO.new
    RubyLLM::Contract.configure { |c| c.logger = Logger.new(io) }
    step.run("x", context: { adapter: incomplete_adapter, model: "gpt-4.1-mini" })

    expect(io.string).to include("cost=unknown")
  ensure
    RubyLLM::Contract.reset_configuration!
  end
end
