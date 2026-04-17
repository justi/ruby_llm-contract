# frozen_string_literal: true

RSpec.describe RubyLLM::Contract::Eval::RetryOptimizer do
  before { RubyLLM::Contract.reset_configuration! }

  # Minimal step with two evals: "easy" (all pass) and "hard" (nano fails)
  let(:step) do
    klass = Class.new(RubyLLM::Contract::Step::Base) do
      input_type String
      output_type Hash
      prompt { user "Classify: {input}" }
      validate("has label") { |o| o[:label].is_a?(String) }
    end

    klass.define_eval("easy") do
      default_input("classify this")
      sample_response({ label: "A" })
      verify "always passes", expect: ->(o) { o[:label].is_a?(String) }
    end

    klass.define_eval("hard") do
      default_input("classify edge case")
      sample_response({ label: "B" })
      verify "always passes", expect: ->(o) { o[:label].is_a?(String) }
    end

    klass
  end

  def stub_compare_models_scores(step, score_matrix)
    # score_matrix: { "easy" => { "nano" => 1.0, "mini" => 1.0 }, "hard" => { "nano" => 0.5, "mini" => 1.0 } }
    allow(step).to receive(:compare_models) do |eval_name, candidates:, **_opts|
      reports = {}
      configs = {}

      candidates.each do |config|
        label = RubyLLM::Contract::Eval::ModelComparison.candidate_label(config)
        score = score_matrix.dig(eval_name, label) || 0.0
        passed = score >= 0.95

        result = RubyLLM::Contract::Eval::CaseResult.new(
          name: "case_1", input: "test", output: {}, expected: {},
          step_status: :ok, score: score, passed: passed,
          cost: 0.001, duration_ms: 100
        )
        reports[label] = RubyLLM::Contract::Eval::Report.new(dataset_name: eval_name, results: [result])
        configs[label] = config
      end

      RubyLLM::Contract::Eval::ModelComparison.new(eval_name: eval_name, reports: reports, configs: configs)
    end
  end

  describe "#call" do
    it "builds score matrix across all evals" do
      stub_compare_models_scores(step, {
        "easy" => { "nano" => 1.0, "mini" => 1.0 },
        "hard" => { "nano" => 0.5, "mini" => 1.0 }
      })

      result = described_class.new(
        step: step,
        candidates: [{ model: "nano" }, { model: "mini" }]
      ).call

      expect(result.eval_names).to contain_exactly("easy", "hard")
      expect(result.score_matrix["easy"]["nano"]).to eq(1.0)
      expect(result.score_matrix["hard"]["nano"]).to eq(0.5)
      expect(result.score_matrix["hard"]["mini"]).to eq(1.0)
    end

    it "identifies the constraining eval" do
      stub_compare_models_scores(step, {
        "easy" => { "nano" => 1.0, "mini" => 1.0 },
        "hard" => { "nano" => 0.5, "mini" => 1.0 }
      })

      result = described_class.new(
        step: step,
        candidates: [{ model: "nano" }, { model: "mini" }]
      ).call

      expect(result.constraining_eval).to eq("hard")
    end

    it "builds a chain from cheapest to constraining-eval-passing" do
      stub_compare_models_scores(step, {
        "easy" => { "nano" => 1.0, "mini" => 1.0 },
        "hard" => { "nano" => 0.5, "mini" => 1.0 }
      })

      result = described_class.new(
        step: step,
        candidates: [{ model: "nano" }, { model: "mini" }]
      ).call

      expect(result.chain).to eq([{ model: "nano" }, { model: "mini" }])
    end

    it "suggests single model when cheapest passes all evals" do
      stub_compare_models_scores(step, {
        "easy" => { "nano" => 1.0, "mini" => 1.0 },
        "hard" => { "nano" => 1.0, "mini" => 1.0 }
      })

      result = described_class.new(
        step: step,
        candidates: [{ model: "nano" }, { model: "mini" }]
      ).call

      expect(result.chain).to eq([{ model: "nano" }])
    end

    it "returns empty chain when no candidate passes all evals" do
      stub_compare_models_scores(step, {
        "easy" => { "nano" => 0.5, "mini" => 0.5 },
        "hard" => { "nano" => 0.5, "mini" => 0.5 }
      })

      result = described_class.new(
        step: step,
        candidates: [{ model: "nano" }, { model: "mini" }]
      ).call

      expect(result.chain).to be_empty
    end

    it "builds chain from disjoint eval coverage via retry escalation" do
      stub_compare_models_scores(step, {
        "easy" => { "nano" => 1.0, "mini" => 0.5 },
        "hard" => { "nano" => 0.5, "mini" => 1.0 }
      })

      result = described_class.new(
        step: step,
        candidates: [{ model: "nano" }, { model: "mini" }]
      ).call

      # nano passes easy, mini passes hard. As a retry chain nano→mini:
      # easy inputs pass on nano (first try), hard inputs fail nano then
      # pass on mini (retry). Both evals covered via escalation.
      expect(result.chain.length).to eq(2)
      expect(result.chain).to eq([{ model: "nano" }, { model: "mini" }])
    end

    it "handles reasoning_effort candidates" do
      stub_compare_models_scores(step, {
        "easy" => { "nano" => 1.0, "mini (effort: low)" => 1.0, "mini" => 1.0 },
        "hard" => { "nano" => 0.5, "mini (effort: low)" => 0.5, "mini" => 1.0 }
      })

      result = described_class.new(
        step: step,
        candidates: [
          { model: "nano" },
          { model: "mini", reasoning_effort: "low" },
          { model: "mini" }
        ]
      ).call

      expect(result.chain).to eq([{ model: "nano" }, { model: "mini" }])
    end
  end

  describe "Result#to_dsl" do
    it "generates simple models syntax for model-only chain" do
      stub_compare_models_scores(step, {
        "easy" => { "nano" => 1.0, "mini" => 1.0 },
        "hard" => { "nano" => 0.5, "mini" => 1.0 }
      })

      result = described_class.new(
        step: step,
        candidates: [{ model: "nano" }, { model: "mini" }]
      ).call

      expect(result.to_dsl).to eq('retry_policy models: %w[nano mini]')
    end

    it "generates escalate syntax when reasoning_effort is involved" do
      stub_compare_models_scores(step, {
        "easy" => { "nano" => 1.0, "mini (effort: low)" => 1.0, "mini" => 1.0 },
        "hard" => { "nano" => 0.5, "mini (effort: low)" => 1.0, "mini" => 1.0 }
      })

      result = described_class.new(
        step: step,
        candidates: [
          { model: "nano" },
          { model: "mini", reasoning_effort: "low" },
          { model: "mini" }
        ]
      ).call

      expect(result.to_dsl).to include("escalate")
      expect(result.to_dsl).to include("reasoning_effort")
    end
  end

  describe "Result#print_summary" do
    it "outputs table with constraining eval marked" do
      stub_compare_models_scores(step, {
        "easy" => { "nano" => 1.0, "mini" => 1.0 },
        "hard" => { "nano" => 0.5, "mini" => 1.0 }
      })

      result = described_class.new(
        step: step,
        candidates: [{ model: "nano" }, { model: "mini" }]
      ).call

      output = StringIO.new
      result.print_summary(output)
      text = output.string

      expect(text).to include("retry chain optimization")
      expect(text).to include("Constraining eval: hard")
      expect(text).to include("Suggested chain:")
      expect(text).to include("DSL:")
    end
  end
end
