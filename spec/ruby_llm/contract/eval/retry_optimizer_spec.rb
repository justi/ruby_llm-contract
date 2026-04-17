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

    it "returns empty chain when coverage is disjoint (no model passes all evals)" do
      stub_compare_models_scores(step, {
        "easy" => { "nano" => 1.0, "mini" => 0.5 },
        "hard" => { "nano" => 0.5, "mini" => 1.0 }
      })

      result = described_class.new(
        step: step,
        candidates: [{ model: "nano" }, { model: "mini" }]
      ).call

      # nano passes easy but not hard, mini passes hard but not easy.
      # Retry fires on validation_failed/parse_error — NOT on low eval
      # score. A model returning :ok with wrong output won't escalate.
      # No single model covers all evals → no viable chain.
      expect(result.chain).to be_empty
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

  # ── Offline mode: real step with sample_response, no stubs ──

  describe "offline mode (sample_response, no adapter)" do
    it "produces correct scores and chain without any API calls" do
      offline_step = Class.new(RubyLLM::Contract::Step::Base) do
        input_type String
        output_type Hash
        prompt { user "Classify: {input}" }
        validate("has label") { |o| %w[A B].include?(o[:label]) }
      end

      offline_step.define_eval("passes") do
        default_input("test")
        sample_response({ label: "A" })
        verify "label is A", expect: ->(o) { o[:label] == "A" }
      end

      offline_step.define_eval("fails_for_B") do
        default_input("test")
        sample_response({ label: "B" })
        verify "label must be A", expect: ->(o) { o[:label] == "A" }
      end

      # No adapter, no model — pure offline via sample_response.
      result = offline_step.optimize_retry_policy(
        candidates: [{ model: "cheap" }, { model: "expensive" }],
        context: {}
      )

      expect(result.eval_names).to contain_exactly("passes", "fails_for_B")
      expect(result.score_matrix).to be_a(Hash)
      # Both candidates get identical scores in offline mode (same sample_response).
      expect(result.score_matrix["passes"].values.uniq).to eq([1.0])
    end
  end

  # ── Integration: optimizer chain works at runtime ──

  describe "integration: suggested chain works with step.run" do
    it "chain's last model passes all evals when run through step" do
      int_step = Class.new(RubyLLM::Contract::Step::Base) do
        input_type String
        output_type Hash
        prompt { user "Classify: {input}" }
        validate("has label") { |o| o[:label].is_a?(String) }
      end

      int_step.define_eval("smoke") do
        default_input("test")
        sample_response({ label: "correct" })
        verify "label present", expect: ->(o) { o[:label].is_a?(String) }
      end

      result = int_step.optimize_retry_policy(
        candidates: [{ model: "fast" }, { model: "slow" }],
        context: {}
      )

      # In offline mode all candidates score the same — chain has at least 1 entry.
      expect(result.chain).not_to be_empty

      # Verify the chain's last model actually passes when run through the step.
      last_config = result.chain.last
      adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"label": "correct"}')
      step_result = int_step.run("test", context: { adapter: adapter, model: last_config[:model] })

      expect(step_result.ok?).to be true
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
