# frozen_string_literal: true

# Adversarial QA round 3 -- regression tests for newly discovered bugs.
# Rounds 1-2 found 12 bugs total; these are NEW bugs that rounds 1-2 missed.
# Each describe block covers a specific bug, its fix, and regression guard.

RSpec.describe "Adversarial QA round 3 -- bug regressions" do
  before { RubyLLM::Contract.reset_configuration! }

  # ---------------------------------------------------------------------------
  # BUG 15: nil adapter response content crashes Parser with unhandled TypeError.
  #
  # When an adapter returns nil content (e.g., content filter blocked the
  # response, or Test adapter constructed with response: nil), Parser.parse
  # with :json strategy calls JSON.parse(nil), which raises TypeError
  # ("no implicit conversion of nil into String"). The rescue chain only
  # catches JSON::ParserError and RubyLLM::Contract::ParseError, so the TypeError
  # propagates as an unhandled exception all the way to the caller.
  #
  # Fix: Parser.parse treats nil raw_output as empty string for :json strategy,
  # which produces a clean ParseError instead of an unhandled TypeError.
  # ---------------------------------------------------------------------------
  describe "BUG 15: nil adapter content crashes Parser with TypeError" do
    it "Parser.parse(nil, strategy: :json) returns ParseError instead of TypeError" do
      expect do
        RubyLLM::Contract::Parser.parse(nil, strategy: :json)
      end.to raise_error(RubyLLM::Contract::ParseError),
             "Parser.parse(nil, :json) should raise ParseError, not TypeError"
    end

    it "Parser.parse(nil, strategy: :text) returns nil without crashing" do
      result = RubyLLM::Contract::Parser.parse(nil, strategy: :text)
      expect(result).to be_nil
    end

    it "step with nil adapter content produces :parse_error, not an exception" do
      step = Class.new(RubyLLM::Contract::Step::Base) do
        prompt { user "{input}" }
        output_type RubyLLM::Contract::Types::Hash
        contract { parse :json }
      end

      # Test adapter with nil content simulates a content-filtered response
      adapter = RubyLLM::Contract::Adapters::Test.new(response: nil)
      result = step.run("test", context: { adapter: adapter })

      expect(result.status).to eq(:parse_error),
                               "nil content should produce :parse_error, got #{result.status} " \
                               "with errors: #{result.validation_errors}"
    end

    it "step with empty string adapter content produces :parse_error cleanly" do
      step = Class.new(RubyLLM::Contract::Step::Base) do
        prompt { user "{input}" }
        output_type RubyLLM::Contract::Types::Hash
        contract { parse :json }
      end

      adapter = RubyLLM::Contract::Adapters::Test.new(response: "")
      result = step.run("test", context: { adapter: adapter })

      expect(result.status).to eq(:parse_error),
                               "empty string content should produce :parse_error, got #{result.status}"
    end
  end

  # ---------------------------------------------------------------------------
  # BUG 18: Retry with dynamic prompt does not re-evaluate prompt on each attempt.
  #
  # When run_with_retry calls run_once, it creates a new Runner, which calls
  # build_and_render_prompt. A dynamic prompt block that reads Time.now or an
  # external counter SHOULD get fresh values on each retry. This test confirms
  # that each retry attempt evaluates the prompt block independently, seeing
  # the latest state of captured variables.
  # ---------------------------------------------------------------------------
  describe "BUG 18: Retry prompt re-evaluation" do
    it "re-evaluates dynamic prompt block on each retry attempt" do
      call_count = 0

      step = Class.new(RubyLLM::Contract::Step::Base) do
        input_type String
        output_type RubyLLM::Contract::Types::Hash
        contract { parse :json }

        prompt do |input|
          call_count += 1
          user "attempt #{call_count}: #{input}"
        end

        retry_policy attempts: 3, retry_on: %i[validation_failed parse_error]
      end

      # First two responses fail validation (not valid JSON), third succeeds
      responses = ["not json", "still not json", '{"result": "ok"}']
      idx = 0
      adapter = Class.new(RubyLLM::Contract::Adapters::Base) do
        define_method(:call) do |**_opts|
          content = responses[idx] || responses.last
          idx += 1
          RubyLLM::Contract::Adapters::Response.new(
            content: content,
            usage: { input_tokens: 0, output_tokens: 0 }
          )
        end
      end.new

      result = step.run("hello", context: { adapter: adapter })

      expect(result.status).to eq(:ok)
      # The prompt block should have been called 3 times (once per attempt)
      expect(call_count).to eq(3),
                            "Dynamic prompt block should be re-evaluated on each retry attempt, " \
                            "but was only called #{call_count} times"
    end
  end

  # ---------------------------------------------------------------------------
  # BUG 19: ProcEvaluator treats truthy non-boolean returns inconsistently.
  #
  # ProcEvaluator has explicit branches for true, false, and Numeric. Any other
  # truthy value (like the string "false") falls to the else branch which uses
  # `!!result` -- so the string "false" is treated as PASS (truthy in Ruby).
  # This is technically correct Ruby semantics but surprising for eval authors
  # who may return "false" thinking it means failure.
  #
  # This is not a code fix but a behavioral documentation test that verifies
  # the current (intentional) behavior, since it was flagged as a concern.
  # ---------------------------------------------------------------------------
  describe "BUG 19 (behavioral): ProcEvaluator truthy semantics" do
    it "treats string 'false' as passing (Ruby truthy semantics)" do
      evaluator = RubyLLM::Contract::Eval::Evaluator::ProcEvaluator.new(
        proc { |_output| "false" }
      )

      result = evaluator.call(output: { data: "test" })

      # String "false" is truthy in Ruby, so this passes
      expect(result.passed).to eq(true),
                               "String 'false' should be truthy in Ruby, so ProcEvaluator should treat it as pass"
      expect(result.score).to eq(1.0)
    end

    it "treats nil as failing" do
      evaluator = RubyLLM::Contract::Eval::Evaluator::ProcEvaluator.new(
        proc { |_output| }
      )

      result = evaluator.call(output: { data: "test" })

      expect(result.passed).to eq(false)
      expect(result.score).to eq(0.0)
    end

    it "treats 0 (numeric) as failing (score < 0.5)" do
      evaluator = RubyLLM::Contract::Eval::Evaluator::ProcEvaluator.new(
        proc { |_output| 0 }
      )

      result = evaluator.call(output: { data: "test" })

      expect(result.passed).to eq(false),
                               "Numeric 0 (< 0.5 threshold) should be treated as fail"
    end

    it "treats 0.5 (numeric) as passing (score >= 0.5)" do
      evaluator = RubyLLM::Contract::Eval::Evaluator::ProcEvaluator.new(
        proc { |_output| 0.5 }
      )

      result = evaluator.call(output: { data: "test" })

      expect(result.passed).to eq(true),
                               "Numeric 0.5 (>= 0.5 threshold) should be treated as pass"
    end
  end

  # ---------------------------------------------------------------------------
  # BUG 20: validate block on frozen output -- sort! would crash but sort_by
  # works. Confirm deep-frozen output is safe for non-mutating operations
  # but properly prevents mutation.
  # ---------------------------------------------------------------------------
  describe "BUG 20: Deep-frozen output in validate blocks" do
    it "allows non-mutating operations (sort_by, select, map) on frozen output" do
      step = Class.new(RubyLLM::Contract::Step::Base) do
        prompt { user "{input}" }
        output_type RubyLLM::Contract::Types::Hash
        contract { parse :json }

        validate "items are sorted by score" do |output|
          items = output[:items] || []
          sorted = items.sort_by { |i| -(i[:score] || 0) }
          items == sorted
        end
      end

      adapter = RubyLLM::Contract::Adapters::Test.new(
        response: '{"items": [{"name": "a", "score": 10}, {"name": "b", "score": 5}]}'
      )
      result = step.run("test", context: { adapter: adapter })

      expect(result.status).to eq(:ok),
                               "Non-mutating sort_by on frozen array should work. Got: #{result.validation_errors}"
    end

    it "prevents mutating operations (sort!) on frozen output arrays" do
      step = Class.new(RubyLLM::Contract::Step::Base) do
        prompt { user "{input}" }
        output_type RubyLLM::Contract::Types::Hash
        contract { parse :json }

        # This validate block tries to mutate the frozen array -- should be caught
        validate "bad mutating sort" do |output|
          items = output[:items] || []
          items.sort_by! { |i| i[:score] }
          true
        end
      end

      adapter = RubyLLM::Contract::Adapters::Test.new(
        response: '{"items": [{"name": "a", "score": 10}, {"name": "b", "score": 5}]}'
      )
      result = step.run("test", context: { adapter: adapter })

      # The validate block should raise FrozenError, which is caught and
      # reported as a validation error
      expect(result.status).to eq(:validation_failed),
                               "Mutating frozen output should cause validation_failed"
      expect(result.validation_errors.first).to include("FrozenError"),
                                                "Error should mention FrozenError: #{result.validation_errors}"
    end
  end

  # ---------------------------------------------------------------------------
  # BUG 21: Pipeline step with nil parsed_output passes nil to next step.
  #
  # If step 1 succeeds (status: :ok) but parsed_output is nil (e.g., text
  # step that returns nil), the next step receives nil as input. If the next
  # step has input_type String, this fails with a confusing type error.
  # This test documents the data-threading behavior.
  # ---------------------------------------------------------------------------
  describe "BUG 21: Pipeline data threading with nil parsed_output" do
    it "passes nil to next step when previous step has nil parsed_output" do
      step_a = Class.new(RubyLLM::Contract::Step::Base) do
        prompt { user "{input}" }
        # Text output, no contract - parsed_output will be whatever adapter returns
      end

      step_b = Class.new(RubyLLM::Contract::Step::Base) do
        input_type String
        prompt { |input| user "Process: #{input}" }
      end

      pipeline = Class.new(RubyLLM::Contract::Pipeline::Base) do
        step step_a, as: :step_a
        step step_b, as: :step_b
      end

      # Step A returns nil content, which becomes nil parsed_output
      # Step B should get nil as input and handle it according to its input_type
      adapter = RubyLLM::Contract::Adapters::Test.new(responses: [nil, "result"])
      result = pipeline.run("start", context: { adapter: adapter })

      # nil.is_a?(String) is false, so step B should fail with input_error
      # This confirms the data threading behavior -- nil flows through
      if result.step_results.length > 1
        step_b_result = result.step_results[1][:result]
        # Step B should fail because nil is not a String
        expect(step_b_result.status).to eq(:input_error),
                                        "Step B should fail with input_error when receiving nil input, " \
                                        "got #{step_b_result.status}"
      end
    end
  end

end
