# frozen_string_literal: true

RSpec.describe "Eval::Dataset + Runner" do
  before { RubyLLM::Contract.reset_configuration! }

  let(:classify_step) do
    Class.new(RubyLLM::Contract::Step::Base) do
      input_type RubyLLM::Contract::Types::String
      output_type RubyLLM::Contract::Types::Hash
      prompt { user "{input}" }
      contract { parse :json }
    end
  end

  describe "Dataset" do
    it "defines cases with input and expected" do
      ds = RubyLLM::Contract::Eval::Dataset.define("test") do
        add_case "case 1", input: "hello", expected: { intent: "greeting" }
        add_case "case 2", input: "buy",   expected: { intent: "sales" }
      end

      expect(ds.name).to eq("test")
      expect(ds.cases.length).to eq(2)
      expect(ds.cases[0].name).to eq("case 1")
      expect(ds.cases[0].input).to eq("hello")
      expect(ds.cases[0].expected).to eq({ intent: "greeting" })
    end

    it "supports expected_traits" do
      ds = RubyLLM::Contract::Eval::Dataset.define do
        add_case input: "test", expected_traits: { intent: "sales", confidence: 0.9 }
      end

      expect(ds.cases[0].expected_traits).to eq({ intent: "sales", confidence: 0.9 })
    end

    it "supports custom evaluator" do
      custom = ->(o) { o[:score] > 5 }
      ds = RubyLLM::Contract::Eval::Dataset.define do
        add_case input: "test", evaluator: custom
      end

      expect(ds.cases[0].evaluator).to eq(custom)
    end

    it "auto-names cases" do
      ds = RubyLLM::Contract::Eval::Dataset.define do
        add_case input: "a"
        add_case input: "b"
      end

      expect(ds.cases.map(&:name)).to eq(%w[case_1 case_2])
    end
  end

  describe "Runner + Report" do
    it "runs all cases and returns a report" do
      adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"intent": "greeting"}')

      ds = RubyLLM::Contract::Eval::Dataset.define("classify") do
        add_case "match", input: "hello", expected: { intent: "greeting" }
        add_case "mismatch", input: "buy", expected: { intent: "sales" }
      end

      report = RubyLLM::Contract::Eval::Runner.run(step: classify_step, dataset: ds,
                                                context: { adapter: adapter })

      expect(report.results.length).to eq(2)
      expect(report.dataset_name).to eq("classify")
    end

    it "scores correctly — 1/2 pass" do
      adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"intent": "greeting"}')

      ds = RubyLLM::Contract::Eval::Dataset.define do
        add_case input: "hello", expected: { intent: "greeting" }  # pass
        add_case input: "buy",   expected: { intent: "sales" }     # fail
      end

      report = RubyLLM::Contract::Eval::Runner.run(step: classify_step, dataset: ds,
                                                context: { adapter: adapter })

      expect(report.passed).to eq(1)
      expect(report.failed).to eq(1)
      expect(report.pass_rate).to eq("1/2")
      expect(report.score).to eq(0.5)
      expect(report.passed?).to be false
    end

    it "scores correctly — all pass" do
      adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"intent": "greeting"}')

      ds = RubyLLM::Contract::Eval::Dataset.define do
        add_case input: "hello", expected: { intent: "greeting" }
        add_case input: "hi",    expected: { intent: "greeting" }
      end

      report = RubyLLM::Contract::Eval::Runner.run(step: classify_step, dataset: ds,
                                                context: { adapter: adapter })

      expect(report.score).to eq(1.0)
      expect(report.passed?).to be true
      expect(report.pass_rate).to eq("2/2")
    end

    it "handles contract failure as score 0" do
      adapter = RubyLLM::Contract::Adapters::Test.new(response: "not json")

      ds = RubyLLM::Contract::Eval::Dataset.define do
        add_case input: "test", expected: { intent: "sales" }
      end

      report = RubyLLM::Contract::Eval::Runner.run(step: classify_step, dataset: ds,
                                                context: { adapter: adapter })

      expect(report.score).to eq(0.0)
      expect(report.results[0].step_status).to eq(:parse_error)
    end

    it "evaluates expected_traits" do
      adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"intent": "sales", "confidence": 0.9}')

      ds = RubyLLM::Contract::Eval::Dataset.define do
        add_case input: "buy", expected_traits: { intent: "sales" }
      end

      report = RubyLLM::Contract::Eval::Runner.run(step: classify_step, dataset: ds,
                                                context: { adapter: adapter })

      expect(report.passed?).to be true
    end

    it "evaluates expected_traits with regex" do
      adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"intent": "billing_support"}')

      ds = RubyLLM::Contract::Eval::Dataset.define do
        add_case input: "help", expected_traits: { intent: /billing/ }
      end

      report = RubyLLM::Contract::Eval::Runner.run(step: classify_step, dataset: ds,
                                                context: { adapter: adapter })

      expect(report.passed?).to be true
    end

    it "evaluates with custom proc evaluator" do
      adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"score": 8}')

      ds = RubyLLM::Contract::Eval::Dataset.define do
        add_case input: "test", evaluator: ->(o) { o[:score] > 5 }
      end

      report = RubyLLM::Contract::Eval::Runner.run(step: classify_step, dataset: ds,
                                                context: { adapter: adapter })

      expect(report.passed?).to be true
    end

    it "evaluates contract-only cases (no expected)" do
      adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"k": "v"}')

      ds = RubyLLM::Contract::Eval::Dataset.define do
        add_case input: "test"
      end

      report = RubyLLM::Contract::Eval::Runner.run(step: classify_step, dataset: ds,
                                                context: { adapter: adapter })

      expect(report.passed?).to be true
      expect(report.results[0].details).to eq("contract passed")
    end

    it "provides summary" do
      adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"intent": "greeting"}')

      ds = RubyLLM::Contract::Eval::Dataset.define("my_eval") do
        add_case input: "hello", expected: { intent: "greeting" }
      end

      report = RubyLLM::Contract::Eval::Runner.run(step: classify_step, dataset: ds,
                                                context: { adapter: adapter })

      expect(report.summary).to eq("my_eval: 1/1 checks passed")
    end
  end

  describe "eval_case convenience" do
    it "evaluates a single case inline" do
      adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"intent": "sales"}')

      result = classify_step.eval_case(
        input: "buy stuff",
        expected: { intent: "sales" },
        context: { adapter: adapter }
      )

      expect(result.passed?).to be true
      expect(result.score).to eq(1.0)
    end

    it "reports failure on mismatch" do
      adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"intent": "other"}')

      result = classify_step.eval_case(
        input: "buy stuff",
        expected: { intent: "sales" },
        context: { adapter: adapter }
      )

      expect(result.passed?).to be false
    end
  end
end
