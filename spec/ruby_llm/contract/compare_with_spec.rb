# frozen_string_literal: true

require "ruby_llm/contract/rspec"

RSpec.describe "compare_with — prompt A/B testing" do
  before { RubyLLM::Contract.reset_configuration! }

  let(:good_response) { '{"intent": "billing", "confidence": 0.9}' }
  let(:bad_response) { '{"intent": "", "confidence": 0.1}' }

  let(:good_adapter) { RubyLLM::Contract::Adapters::Test.new(response: good_response) }
  let(:bad_adapter) { RubyLLM::Contract::Adapters::Test.new(response: bad_response) }

  let(:candidate_step) do
    Class.new(RubyLLM::Contract::Step::Base) do
      input_type String
      output_type Hash
      prompt { user "{input}" }
      validate("has intent") { |o| !o[:intent].to_s.empty? }

      define_eval("accuracy") do
        default_input "test query"
        verify "has intent", { intent: /billing/ }
        verify "high confidence", ->(o) { o[:confidence] > 0.5 }
      end
    end
  end

  let(:baseline_step) do
    Class.new(RubyLLM::Contract::Step::Base) do
      input_type String
      output_type Hash
      prompt { user "{input}" }
      validate("has intent") { |o| !o[:intent].to_s.empty? }

      define_eval("accuracy") do
        default_input "test query"
        verify "has intent", { intent: /billing/ }
        verify "high confidence", ->(o) { o[:confidence] > 0.5 }
      end
    end
  end

  let(:equal_step) do
    Class.new(RubyLLM::Contract::Step::Base) do
      input_type String
      output_type Hash
      prompt { user "{input}" }
      validate("has intent") { |o| !o[:intent].to_s.empty? }

      define_eval("accuracy") do
        default_input "test query"
        verify "has intent", { intent: /billing/ }
        verify "high confidence", ->(o) { o[:confidence] > 0.5 }
      end
    end
  end

  describe "#compare_with" do
    it "returns a PromptDiff" do
      result = candidate_step.compare_with(
        equal_step, eval: "accuracy", context: { adapter: good_adapter }
      )

      expect(result).to be_a(RubyLLM::Contract::Eval::PromptDiff)
    end

    it "safe_to_switch? is true when no regressions" do
      result = candidate_step.compare_with(
        baseline_step, eval: "accuracy",
        context: { adapter: good_adapter }
      )

      expect(result.safe_to_switch?).to be true
    end

    it "safe_to_switch? is false when regressions exist" do
      # Candidate returns bad responses, baseline returns good responses.
      # Both use baseline's eval definition (same dataset), but different adapters.
      candidate = build_step_with_forced_adapter(bad_response)
      baseline = build_step_with_forced_adapter(good_response)

      diff = candidate.compare_with(baseline, eval: "accuracy")

      expect(diff.safe_to_switch?).to be false
    end

    it "detects improvements when candidate passes where baseline failed" do
      # Candidate returns good responses, baseline returns bad responses.
      candidate = build_step_with_forced_adapter(good_response)
      baseline = build_step_with_forced_adapter(bad_response)

      diff = candidate.compare_with(baseline, eval: "accuracy")

      expect(diff.improvements).not_to be_empty
    end

    it "computes score_delta correctly" do
      candidate = build_step_with_forced_adapter(good_response)
      baseline = build_step_with_forced_adapter(bad_response)

      diff = candidate.compare_with(baseline, eval: "accuracy")

      expect(diff.score_delta).to eq(
        (diff.candidate_score - diff.baseline_score).round(4)
      )
      expect(diff.score_delta).to be > 0
    end

    it "accepts model: parameter" do
      result = candidate_step.compare_with(
        equal_step, eval: "accuracy", model: "test-model",
        context: { adapter: good_adapter }
      )

      expect(result).to be_a(RubyLLM::Contract::Eval::PromptDiff)
      expect(result.candidate_score).to eq(result.baseline_score)
    end
  end

  describe "RSpec matcher: pass_eval.compared_with.without_regressions" do
    it "passes when candidate has no regressions vs baseline" do
      # Both use same adapter, both pass -> no regressions
      candidate = build_step_with_forced_adapter(good_response)
      baseline = build_step_with_forced_adapter(good_response)

      expect(candidate).to pass_eval("accuracy")
        .compared_with(baseline)
        .without_regressions
    end

    it "fails when candidate has regressions vs baseline" do
      candidate = build_step_with_forced_adapter(bad_response)
      baseline = build_step_with_forced_adapter(good_response)

      expect(candidate).not_to pass_eval("accuracy")
        .compared_with(baseline)
        .without_regressions
    end
  end

  # -- helpers --

  # Build a step where the adapter is baked into the step's `run` method.
  # This ensures compare_with (which calls Runner.run -> step.run) always
  # uses this adapter, regardless of what context compare_with passes.
  def build_step_with_forced_adapter(fixed_response)
    adapter = RubyLLM::Contract::Adapters::Test.new(response: fixed_response)
    step = Class.new(RubyLLM::Contract::Step::Base) do
      input_type String
      output_type Hash
      prompt { user "{input}" }
      validate("has intent") { |o| !o[:intent].to_s.empty? }

      define_eval("accuracy") do
        default_input "test query"
        verify "has intent", { intent: /billing/ }
        verify "high confidence", ->(o) { o[:confidence] > 0.5 }
      end
    end
    # Override run to force the adapter into context, so Runner always uses it
    step.define_singleton_method(:run) do |input, context: {}|
      super(input, context: context.merge(adapter: adapter))
    end
    step
  end

  # Legacy helper kept for tests that pass a shared adapter via context
  def build_step_with_eval(fixed_response)
    adapter = RubyLLM::Contract::Adapters::Test.new(response: fixed_response)
    step = Class.new(RubyLLM::Contract::Step::Base) do
      input_type String
      output_type Hash
      prompt { user "{input}" }
      validate("has intent") { |o| !o[:intent].to_s.empty? }

      define_eval("accuracy") do
        default_input "test query"
        verify "has intent", { intent: /billing/ }
        verify "high confidence", ->(o) { o[:confidence] > 0.5 }
      end
    end
    step.define_singleton_method(:run_eval) do |name = nil, context: {}, concurrency: nil|
      ctx = context.merge(adapter: adapter)
      super(name, context: ctx, concurrency: concurrency)
    end
    step
  end

  # -- Bug fix tests --

  describe "context isolation (stateful adapter)" do
    it "isolates context so stateful adapters don't cross-contaminate" do
      step = Class.new(RubyLLM::Contract::Step::Base) do
        input_type String
        output_type Hash
        prompt { user "{input}" }

        define_eval("smoke") do
          add_case "c1", input: "x", expected: { v: "good" }
          add_case "c2", input: "y", expected: { v: "good" }
        end
      end

      # Stateful adapter with responses: consumes in order. If contexts share
      # the adapter, candidate eats responses meant for baseline.
      adapter = RubyLLM::Contract::Adapters::Test.new(
        responses: ['{"v":"good"}', '{"v":"bad"}']
      )
      diff = step.compare_with(step, eval: "smoke", context: { adapter: adapter })

      # Same step vs itself must give identical scores regardless of adapter state
      expect(diff.candidate_score).to eq(diff.baseline_score)
      expect(diff.score_delta).to eq(0)
      expect(diff.safe_to_switch?).to be true
    end
  end

  describe "baseline's eval definition is the single source of truth" do
    it "uses baseline's dataset even when candidate defines a different eval" do
      # Baseline has a strict eval with expected: { intent: "support" }
      baseline_adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"intent":"support"}')
      baseline = Class.new(RubyLLM::Contract::Step::Base) do
        input_type String
        output_type Hash
        prompt { user "{input}" }

        define_eval("regression") do
          add_case "test", input: "query", expected: { intent: "support" }
        end
      end
      baseline.define_singleton_method(:run) do |input, context: {}|
        super(input, context: context.merge(adapter: baseline_adapter))
      end

      # Candidate defines a DIFFERENT eval (easy expected: { intent: "billing" })
      # but compare_with should ignore it and use baseline's expected: { intent: "support" }
      candidate_adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"intent":"billing"}')
      candidate = Class.new(RubyLLM::Contract::Step::Base) do
        input_type String
        output_type Hash
        prompt { user "{input}" }

        define_eval("regression") do
          add_case "test", input: "different query", expected: { intent: "billing" }
        end
      end
      candidate.define_singleton_method(:run) do |input, context: {}|
        super(input, context: context.merge(adapter: candidate_adapter))
      end

      diff = candidate.compare_with(baseline, eval: "regression")

      # Both sides run against baseline's dataset: input="query", expected={ intent: "support" }
      # Baseline returns "support" -> passes
      # Candidate returns "billing" -> fails (expected "support", got "billing")
      expect(diff.candidate_score).to be < diff.baseline_score
      expect(diff.safe_to_switch?).to be false

      # Verify the dataset used is baseline's (both sides have same case names/inputs/expected)
      expect(diff.case_names_match?).to be true
      expect(diff.cases_comparable?).to be true
    end

    it "raises ArgumentError when baseline has no eval with that name" do
      candidate = Class.new(RubyLLM::Contract::Step::Base) do
        input_type String
        output_type Hash
        prompt { user "{input}" }

        define_eval("accuracy") do
          default_input "test"
        end
      end

      baseline_without_eval = Class.new(RubyLLM::Contract::Step::Base) do
        input_type String
        output_type Hash
        prompt { user "{input}" }
      end

      expect {
        candidate.compare_with(baseline_without_eval, eval: "accuracy")
      }.to raise_error(ArgumentError, /No eval 'accuracy' on baseline step/)
    end

    it "candidate does not need its own eval definition" do
      # Candidate has NO eval defined, but compare_with uses baseline's
      candidate_adapter = RubyLLM::Contract::Adapters::Test.new(response: good_response)
      candidate = Class.new(RubyLLM::Contract::Step::Base) do
        input_type String
        output_type Hash
        prompt { user "{input}" }
        validate("has intent") { |o| !o[:intent].to_s.empty? }
        # No define_eval here
      end
      candidate.define_singleton_method(:run) do |input, context: {}|
        super(input, context: context.merge(adapter: candidate_adapter))
      end

      baseline_adapter = RubyLLM::Contract::Adapters::Test.new(response: good_response)
      baseline = Class.new(RubyLLM::Contract::Step::Base) do
        input_type String
        output_type Hash
        prompt { user "{input}" }
        validate("has intent") { |o| !o[:intent].to_s.empty? }

        define_eval("accuracy") do
          default_input "test query"
          verify "has intent", { intent: /billing/ }
          verify "high confidence", ->(o) { o[:confidence] > 0.5 }
        end
      end
      baseline.define_singleton_method(:run) do |input, context: {}|
        super(input, context: context.merge(adapter: baseline_adapter))
      end

      diff = candidate.compare_with(baseline, eval: "accuracy")

      # Both return good response, same dataset -> safe to switch
      expect(diff.safe_to_switch?).to be true
      expect(diff.candidate_score).to eq(diff.baseline_score)
    end
  end

  describe "compare_with without adapter (sample_response not used)" do
    it "results in skipped cases — not safe to switch" do
      baseline = Class.new(RubyLLM::Contract::Step::Base) do
        input_type String
        output_type Hash
        prompt { user "{input}" }

        define_eval("accuracy") do
          default_input "test"
          sample_response({ intent: "billing", confidence: 0.9 })
          verify "has intent", { intent: /billing/ }
        end
      end

      candidate = Class.new(RubyLLM::Contract::Step::Base) do
        input_type String
        output_type Hash
        prompt { user "{input}" }
      end

      # Without adapter, compare_with does NOT use sample_response.
      # Cases get skipped → both sides empty → not safe.
      diff = candidate.compare_with(baseline, eval: "accuracy")
      expect(diff.baseline_empty?).to be true
      expect(diff.candidate_empty?).to be true
      expect(diff.safe_to_switch?).to be false
    end
  end

  describe "compared_with without without_regressions" do
    it "compared_with implies regression check (not a silent no-op)" do
      candidate = build_step_with_forced_adapter(good_response)
      baseline = build_step_with_forced_adapter(bad_response)

      expect(candidate).to pass_eval("accuracy")
        .compared_with(baseline)
    end

    it "fails when baseline is better even without explicit without_regressions" do
      candidate = build_step_with_forced_adapter(bad_response)
      baseline = build_step_with_forced_adapter(good_response)

      expect(candidate).not_to pass_eval("accuracy")
        .compared_with(baseline)
    end
  end

  describe "score-only regression" do
    it "safe_to_switch? is false when score drops even if both fail" do
      # Baseline: partial match (intent matches but confidence is low)
      baseline_adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"intent":"billing","confidence":0.3}')
      baseline = Class.new(RubyLLM::Contract::Step::Base) do
        input_type String
        output_type Hash
        prompt { user "{input}" }

        define_eval("regression") do
          add_case "test", input: "query", expected: { intent: "billing" }
        end
      end
      baseline.define_singleton_method(:run) do |input, context: {}|
        super(input, context: context.merge(adapter: baseline_adapter))
      end

      # Candidate: no match at all (wrong intent)
      candidate_adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"intent":"wrong","confidence":0.1}')
      candidate = Class.new(RubyLLM::Contract::Step::Base) do
        input_type String
        output_type Hash
        prompt { user "{input}" }

        define_eval("regression") do
          add_case "test", input: "query", expected: { intent: "billing" }
        end
      end
      candidate.define_singleton_method(:run) do |input, context: {}|
        super(input, context: context.merge(adapter: candidate_adapter))
      end

      diff = candidate.compare_with(baseline, eval: "regression")

      expect(diff.score_delta).to be_negative
      expect(diff.safe_to_switch?).to be false
      expect(diff.score_regressions.length).to eq(1)
    end
  end

  describe "per-case score regression masked by average" do
    it "safe_to_switch? is false when one case drops even if another improves" do
      # Both sides use baseline's dataset: cases "a" and "b"
      # Baseline: both cases return "partial" -> both match expected
      baseline_adapter = RubyLLM::Contract::Adapters::Test.new(
        responses: ['{"v":"partial"}', '{"v":"partial"}']
      )
      baseline = Class.new(RubyLLM::Contract::Step::Base) do
        input_type String
        output_type Hash
        prompt { user "{input}" }

        define_eval("regression") do
          add_case "a", input: "x", expected: { v: "partial" }
          add_case "b", input: "y", expected: { v: "partial" }
        end
      end
      baseline.define_singleton_method(:run) do |input, context: {}|
        super(input, context: context.merge(adapter: baseline_adapter))
      end

      # Candidate: case "a" passes, case "b" returns wrong value
      candidate_adapter = RubyLLM::Contract::Adapters::Test.new(
        responses: ['{"v":"partial"}', '{"v":"wrong"}']
      )
      candidate = Class.new(RubyLLM::Contract::Step::Base) do
        input_type String
        output_type Hash
        prompt { user "{input}" }

        define_eval("regression") do
          add_case "a", input: "x", expected: { v: "partial" }
          add_case "b", input: "y", expected: { v: "partial" }
        end
      end
      candidate.define_singleton_method(:run) do |input, context: {}|
        super(input, context: context.merge(adapter: candidate_adapter))
      end

      diff = candidate.compare_with(baseline, eval: "regression")

      expect(diff.score_regressions).not_to be_empty
      expect(diff.safe_to_switch?).to be false
    end
  end

  # -------------------------------------------------------------------------
  # Proof that candidate's eval definition is ignored — baseline is truth
  # -------------------------------------------------------------------------
  describe "candidate eval manipulation is ignored (baseline is source of truth)" do
    it "candidate's different evaluator is ignored" do
      # Baseline: strict evaluator requiring intent == "billing"
      baseline = Class.new(RubyLLM::Contract::Step::Base) do
        input_type String
        output_type Hash
        prompt { user "{input}" }

        define_eval("test") do
          default_input "x"
          verify "strict", ->(o) { o[:intent] == "billing" }
        end
      end
      baseline.define_singleton_method(:run) do |input, context: {}|
        super(input, context: context.merge(
          adapter: RubyLLM::Contract::Adapters::Test.new(response: '{"intent":"billing"}')
        ))
      end

      # Candidate: lenient evaluator (always passes) — should be IGNORED
      candidate = Class.new(RubyLLM::Contract::Step::Base) do
        input_type String
        output_type Hash
        prompt { user "{input}" }

        define_eval("test") do
          default_input "x"
          verify "lenient", ->(o) { true } # always passes
        end
      end
      candidate.define_singleton_method(:run) do |input, context: {}|
        super(input, context: context.merge(
          adapter: RubyLLM::Contract::Adapters::Test.new(response: '{"intent":"wrong"}')
        ))
      end

      diff = candidate.compare_with(baseline, eval: "test")

      # Baseline's strict evaluator is used for both:
      # - baseline returns "billing" → passes strict check
      # - candidate returns "wrong" → fails strict check
      expect(diff.baseline_score).to eq(1.0)
      expect(diff.candidate_score).to eq(0.0)
      expect(diff.safe_to_switch?).to be false
    end

    it "candidate's different expected_traits is ignored" do
      # Baseline: expects intent to match /billing/
      baseline = Class.new(RubyLLM::Contract::Step::Base) do
        input_type String
        output_type Hash
        prompt { user "{input}" }

        define_eval("test") do
          add_case "c1", input: "x", expected: { intent: "billing" }
        end
      end
      baseline.define_singleton_method(:run) do |input, context: {}|
        super(input, context: context.merge(
          adapter: RubyLLM::Contract::Adapters::Test.new(response: '{"intent":"billing"}')
        ))
      end

      # Candidate: expects intent == "anything" — should be IGNORED
      candidate = Class.new(RubyLLM::Contract::Step::Base) do
        input_type String
        output_type Hash
        prompt { user "{input}" }

        define_eval("test") do
          add_case "c1", input: "x", expected: { intent: "anything" }
        end
      end
      candidate.define_singleton_method(:run) do |input, context: {}|
        super(input, context: context.merge(
          adapter: RubyLLM::Contract::Adapters::Test.new(response: '{"intent":"anything"}')
        ))
      end

      diff = candidate.compare_with(baseline, eval: "test")

      # Baseline's expected { intent: "billing" } is used for BOTH:
      # - baseline returns "billing" → matches → score 1.0
      # - candidate returns "anything" → doesn't match "billing" → score 0.0
      expect(diff.baseline_score).to eq(1.0)
      expect(diff.candidate_score).to eq(0.0)
      expect(diff.safe_to_switch?).to be false
    end
  end

  describe "pass_eval.compared_with with sample_response (no adapter)" do
    it "fails because compare_with skips sample_response fallback" do
      baseline = Class.new(RubyLLM::Contract::Step::Base) do
        input_type String
        output_type Hash
        prompt { user "{input}" }

        define_eval("smoke") do
          default_input "test"
          sample_response({ intent: "billing", confidence: 0.9 })
          verify "has intent", { intent: /billing/ }
        end
      end

      candidate = Class.new(RubyLLM::Contract::Step::Base) do
        input_type String
        output_type Hash
        prompt { user "{input}" }
      end

      # Without adapter/model, cases get skipped → not safe
      expect(candidate).not_to pass_eval("smoke").compared_with(baseline)
    end
  end

  describe "step_expectations in compare_with (pipeline)" do
    it "uses baseline's step_expectations for both sides" do
      # Define two simple steps
      step_a = Class.new(RubyLLM::Contract::Step::Base) do
        input_type String
        output_type Hash
        prompt { user "{input}" }
      end

      step_b = Class.new(RubyLLM::Contract::Step::Base) do
        input_type String
        output_type Hash
        prompt { user "{input}" }
      end

      # Baseline pipeline with step_expectations
      baseline_pipeline = Class.new(RubyLLM::Contract::Pipeline::Base) do
        step step_a, as: :classify
        step step_b, as: :route
      end

      adapter = RubyLLM::Contract::Adapters::Test.new(
        responses: ['{"priority":"high"}', '{"team":"billing"}']
      )

      baseline_pipeline.define_eval("e2e") do
        add_case "billing",
          input: "I was charged twice",
          expected: { team: "billing" },
          step_expectations: { classify: { priority: "high" } }
      end

      # Candidate pipeline — same steps, same structure
      candidate_pipeline = Class.new(RubyLLM::Contract::Pipeline::Base) do
        step step_a, as: :classify
        step step_b, as: :route
      end

      # compare_with uses baseline's eval (with step_expectations)
      diff = candidate_pipeline.compare_with(baseline_pipeline,
        eval: "e2e", context: { adapter: adapter })

      # Both sides use same adapter + same eval → identical results
      expect(diff.candidate_score).to eq(diff.baseline_score)
      expect(diff.safe_to_switch?).to be true
    end
  end
end
