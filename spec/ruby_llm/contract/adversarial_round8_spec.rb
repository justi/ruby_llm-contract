# frozen_string_literal: true

# Adversarial QA round 8 -- API design correctness and user-facing contract violations.
# Rounds 1-6 found ~33 bugs (crashes, missing validation, behavioral correctness).
# Round 8 focuses on a DIFFERENT axis: does the public API behave as documented
# and expected? Every test here validates a user-facing contract promise.

RSpec.describe "Adversarial QA round 8 -- API contract violations" do
  before { RubyLLM::Contract.reset_configuration! }

  # ---------------------------------------------------------------------------
  # BUG 39: max_input(-1) silently accepts a negative limit, then rejects ALL
  # inputs because any positive token estimate > -1 is true.
  #
  # The error message says "estimated N tokens, max -1" which is nonsensical.
  # The API contract: max_input should only accept positive token limits.
  # ---------------------------------------------------------------------------
  describe "BUG 39 (FIXED): max_input with negative value raises at definition time" do
    it "raises ArgumentError for max_input(-1) at definition time" do
      expect do
        Class.new(RubyLLM::Contract::Step::Base) do
          prompt { user "{input}" }
          output_type String
          max_input(-1)
        end
      end.to raise_error(ArgumentError, /max_input must be positive/)
    end

    it "raises ArgumentError for max_input(0) at definition time" do
      expect do
        Class.new(RubyLLM::Contract::Step::Base) do
          prompt { user "{input}" }
          output_type String
          max_input(0)
        end
      end.to raise_error(ArgumentError, /max_input must be positive/)
    end
  end

  # ---------------------------------------------------------------------------
  # BUG 40: run_eval with no name returns Hash{String=>Report}, not Report.
  #
  # Step.run_eval(:name) returns a Report. Step.run_eval (no args) returns
  # a Hash mapping eval names to Report objects via transform_values. This
  # is an inconsistent return type contract. Callers who do:
  #   report = MyStep.run_eval
  #   report.passed?   # NoMethodError -- it's a Hash, not a Report
  #
  # The API contract violation: run_eval should always return an object with
  # a consistent interface.
  # ---------------------------------------------------------------------------
  describe "BUG 40: run_eval return type inconsistency" do
    it "run_eval(:name) returns a Report" do
      step = Class.new(RubyLLM::Contract::Step::Base) do
        prompt { user "{input}" }
        define_eval(:smoke) do
          default_input "test"
          sample_response "hello"
        end
      end

      report = step.run_eval(:smoke)
      expect(report).to be_a(RubyLLM::Contract::Eval::Report),
                        "run_eval(:name) should return a Report, got #{report.class}"
      expect(report).to respond_to(:passed?)
      expect(report).to respond_to(:score)
    end

    it "run_eval with no args returns a Hash, not a Report" do
      step = Class.new(RubyLLM::Contract::Step::Base) do
        prompt { user "{input}" }
        define_eval(:smoke) do
          default_input "test"
          sample_response "hello"
        end
        define_eval(:regression) do
          default_input "test2"
          sample_response "hello2"
        end
      end

      result = step.run_eval
      # This documents the inconsistency: no-arg run_eval returns a Hash
      expect(result).to be_a(Hash),
                        "run_eval (no args) returns a Hash, not a Report"
      expect(result).not_to respond_to(:passed?),
                            "The Hash returned by run_eval does not have passed? -- " \
                            "callers expecting a Report will get NoMethodError"
      result.each_value do |report|
        expect(report).to be_a(RubyLLM::Contract::Eval::Report)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # BUG 41: run_eval with no evals defined returns empty Hash {}.
  #
  # When a Step has no define_eval calls, run_eval (no args) returns {}.
  # This empty Hash does not respond to passed?, score, etc.
  # ---------------------------------------------------------------------------
  describe "BUG 41: run_eval with no evals returns empty Hash" do
    it "returns empty Hash when no evals are defined" do
      step = Class.new(RubyLLM::Contract::Step::Base) do
        prompt { user "{input}" }
      end

      result = step.run_eval
      expect(result).to eq({}),
                        "run_eval on step with no evals should return {}"
      expect(result).not_to respond_to(:passed?),
                            "Empty Hash does not have passed? -- API contract is broken"
    end
  end

  # ---------------------------------------------------------------------------
  # BUG 42: String context keys are not recognized; adapter/model silently nil.
  #
  # KNOWN_CONTEXT_KEYS is an array of symbols. If a user passes context keys
  # as strings, the adapter lookup fails because context[:adapter] returns nil
  # for string-keyed hashes.
  # ---------------------------------------------------------------------------
  describe "BUG 42: String context keys are silently ignored" do
    it "does not find adapter when key is a string" do
      step = Class.new(RubyLLM::Contract::Step::Base) do
        prompt { user "{input}" }
      end

      adapter = RubyLLM::Contract::Adapters::Test.new(response: "ok")

      # String key "adapter" is not recognized
      expect do
        step.run("test", context: { "adapter" => adapter })
      end.to raise_error(RubyLLM::Contract::Error, /No adapter configured/),
             "String key 'adapter' is silently ignored, causing 'no adapter' crash"
    end

    it "works with symbol key :adapter" do
      step = Class.new(RubyLLM::Contract::Step::Base) do
        prompt { user "{input}" }
        output_type String
      end

      adapter = RubyLLM::Contract::Adapters::Test.new(response: "ok")
      result = step.run("test", context: { adapter: adapter })

      expect(result.status).to eq(:ok)
    end

    it "warns about string keys that are known as symbols" do
      step = Class.new(RubyLLM::Contract::Step::Base) do
        prompt { user "{input}" }
        output_type String
      end

      adapter = RubyLLM::Contract::Adapters::Test.new(response: "ok")

      # warn is dispatched on the Step class singleton (private Kernel method)
      warnings = []
      allow(step).to receive(:warn) { |msg| warnings << msg }

      step.run("test", context: { adapter: adapter, "model" => "gpt-4" })

      warning_text = warnings.join(" ")
      expect(warning_text).to include("Unknown context keys"),
                              "Should warn about string key 'model'"
    end
  end

  # ---------------------------------------------------------------------------
  # BUG 43: validate("") with empty description -- silent, unhelpful errors.
  #
  # When a class-level validate is given an empty string description, and the
  # invariant fails, the error message is just "". This makes debugging
  # impossible.
  # ---------------------------------------------------------------------------
  describe "BUG 43: validate with empty description produces unhelpful errors" do
    it "produces empty string in validation_errors when empty-description invariant fails" do
      step = Class.new(RubyLLM::Contract::Step::Base) do
        prompt { user "{input}" }
        output_type RubyLLM::Contract::Types::Hash
        contract { parse :json }
        validate("") { |_o| false }
      end

      adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"x": 1}')
      result = step.run("test", context: { adapter: adapter })

      expect(result.status).to eq(:validation_failed)
      # The error message is just "" -- completely unhelpful
      expect(result.validation_errors).to include(""),
                                          "Empty-description validate produces empty error string"
    end

    it "contract invariant with empty description also produces empty error" do
      step = Class.new(RubyLLM::Contract::Step::Base) do
        prompt { user "{input}" }
        output_type RubyLLM::Contract::Types::Hash
        contract do
          parse :json
          invariant("") { |_o| false }
        end
      end

      adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"x": 1}')
      result = step.run("test", context: { adapter: adapter })

      expect(result.status).to eq(:validation_failed)
      expect(result.validation_errors).to include("")
    end
  end

  # ---------------------------------------------------------------------------
  # BUG 44: Pipeline with no steps silently succeeds.
  # ---------------------------------------------------------------------------
  describe "BUG 44 (FIXED): Empty pipeline raises ArgumentError" do
    it "raises ArgumentError when run with no steps" do
      pipeline = Class.new(RubyLLM::Contract::Pipeline::Base)

      adapter = RubyLLM::Contract::Adapters::Test.new(response: "ok")
      expect { pipeline.run("hello", context: { adapter: adapter }) }
        .to raise_error(ArgumentError, /no steps defined/i)
    end
  end

  # ---------------------------------------------------------------------------
  # BUG 45: Report#passed? returns true for empty results (vacuous truth).
  # ---------------------------------------------------------------------------
  describe "BUG 45 (FIXED): Report#passed? returns false for empty results" do
    it "returns false for empty report" do
      report = RubyLLM::Contract::Eval::Report.new(dataset_name: "empty", results: [])

      expect(report.passed?).to eq(false),
                                "Report with zero results should return passed? == false"
      expect(report.score).to eq(0.0),
                              "Report#score returns 0.0 for empty results"
    end

    it "score and passed? are now consistent for empty report" do
      report = RubyLLM::Contract::Eval::Report.new(dataset_name: "empty", results: [])

      expect(report.passed?).to eq(false)
      expect(report.score).to eq(0.0)
    end
  end

  # ---------------------------------------------------------------------------
  # BUG 46: Status value contract -- ok? is always the inverse of failed?.
  # ---------------------------------------------------------------------------
  describe "BUG 46: Status value contract" do
    it "Step::Result ok? is always the inverse of failed?" do
      statuses = %i[ok input_error parse_error validation_failed adapter_error limit_exceeded]

      statuses.each do |status|
        result = RubyLLM::Contract::Step::Result.new(
          status: status, raw_output: nil, parsed_output: nil
        )
        expect(result.ok?).to eq(!result.failed?),
                              "For status #{status}: ok? (#{result.ok?}) should be !failed? (#{!result.failed?})"
      end
    end

    it "Pipeline::Result ok? is always the inverse of failed?" do
      statuses = %i[ok input_error parse_error validation_failed
                    adapter_error limit_exceeded timeout budget_exceeded]

      statuses.each do |status|
        result = RubyLLM::Contract::Pipeline::Result.new(
          status: status, step_results: [], outputs_by_step: {}
        )
        expect(result.ok?).to eq(!result.failed?),
                              "For status #{status}: ok? (#{result.ok?}) should be !failed? (#{!result.failed?})"
      end
    end

    it "Step::Result allows arbitrary status symbols without constraint" do
      result = RubyLLM::Contract::Step::Result.new(
        status: :completely_made_up_status, raw_output: nil, parsed_output: nil
      )
      expect(result.status).to eq(:completely_made_up_status)
      expect(result.ok?).to be false
      expect(result.failed?).to be true
    end

    it "Pipeline statuses include :timeout and :budget_exceeded beyond Step statuses" do
      sc = Class.new(RubyLLM::Contract::Step::Base) do
        prompt { user "{input}" }
        output_type RubyLLM::Contract::Types::Hash
        contract { parse :json }
      end

      pipeline = Class.new(RubyLLM::Contract::Pipeline::Base) do
        step sc, as: :slow_step
      end

      slow_adapter = Class.new(RubyLLM::Contract::Adapters::Base) do
        define_method(:call) do |**_opts|
          sleep 0.01
          RubyLLM::Contract::Adapters::Response.new(
            content: '{"ok": true}',
            usage: { input_tokens: 0, output_tokens: 0 }
          )
        end
      end.new

      result = pipeline.run("test", context: { adapter: slow_adapter }, timeout_ms: 1)

      if result.status == :timeout
        expect(result.failed?).to be true
        expect(result.ok?).to be false
        expect(result.failed_step).not_to be_nil
      end
    end
  end

  # ---------------------------------------------------------------------------
  # BUG 47: Pipeline.run result contract -- outputs_by_step, failed_step, etc.
  # ---------------------------------------------------------------------------
  describe "BUG 47: Pipeline result contract consistency" do
    it "outputs_by_step is always a Hash, even on failure" do
      sc = Class.new(RubyLLM::Contract::Step::Base) do
        prompt { user "{input}" }
        output_type RubyLLM::Contract::Types::Hash
        contract { parse :json }
      end

      pipeline = Class.new(RubyLLM::Contract::Pipeline::Base) do
        step sc, as: :first
      end

      adapter = RubyLLM::Contract::Adapters::Test.new(response: "not json at all")
      result = pipeline.run("test", context: { adapter: adapter })

      expect(result.outputs_by_step).to be_a(Hash),
                                        "outputs_by_step should always be a Hash, got #{result.outputs_by_step.class}"
      expect(result.outputs_by_step).to be_empty
    end

    it "failed_step is nil on success" do
      sc = Class.new(RubyLLM::Contract::Step::Base) do
        prompt { user "{input}" }
        output_type RubyLLM::Contract::Types::Hash
        contract { parse :json }
      end

      pipeline = Class.new(RubyLLM::Contract::Pipeline::Base) do
        step sc, as: :first
      end

      adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"ok": true}')
      result = pipeline.run("test", context: { adapter: adapter })

      expect(result.status).to eq(:ok)
      expect(result.failed_step).to be_nil,
                                    "failed_step should be nil on success"
    end

    it "failed_step is a symbol identifying the failed step" do
      sc = Class.new(RubyLLM::Contract::Step::Base) do
        prompt { user "{input}" }
        output_type RubyLLM::Contract::Types::Hash
        contract { parse :json }
      end

      pipeline = Class.new(RubyLLM::Contract::Pipeline::Base) do
        step sc, as: :first
      end

      adapter = RubyLLM::Contract::Adapters::Test.new(response: "not json")
      result = pipeline.run("test", context: { adapter: adapter })

      expect(result.failed?).to be true
      expect(result.failed_step).to eq(:first),
                                    "failed_step should identify the failing step"
    end

    it "empty pipeline raises ArgumentError (step_results never empty)" do
      pipeline = Class.new(RubyLLM::Contract::Pipeline::Base)

      adapter = RubyLLM::Contract::Adapters::Test.new(response: "ok")
      expect { pipeline.run("test", context: { adapter: adapter }) }
        .to raise_error(ArgumentError, /no steps defined/i)
    end
  end

  # ---------------------------------------------------------------------------
  # BUG 48: Step without prompt -- error at run time is UNCAUGHT.
  #
  # A Step that never calls `prompt` does not error at class definition time.
  # When run() is called, `prompt` getter raises ArgumentError. But this
  # ArgumentError is raised INSIDE run_once, which calls
  # Runner.new(..., prompt_block: prompt, ...). The `prompt` call raises
  # ArgumentError. This error is NOT inside the Runner#call rescue chain
  # -- it happens before the Runner is even created. The ArgumentError
  # propagates uncaught all the way to the caller.
  #
  # The contract violation: Step.run should NEVER raise -- it should always
  # return a Result. But a missing prompt causes an uncaught exception.
  #
  # Fix: Catch ArgumentError from prompt getter in run_once and return
  # an :input_error Result.
  # ---------------------------------------------------------------------------
  describe "BUG 48: Step without prompt raises uncaught exception at run time" do
    it "does not error at class definition time" do
      expect do
        Class.new(RubyLLM::Contract::Step::Base) do
          output_type String
        end
      end.not_to raise_error
    end

    it "returns :input_error Result instead of raising" do
      step = Class.new(RubyLLM::Contract::Step::Base) do
        output_type String
      end

      adapter = RubyLLM::Contract::Adapters::Test.new(response: "ok")
      result = step.run("test", context: { adapter: adapter })

      # After the fix, this should return a Result with :input_error
      expect(result).to be_a(RubyLLM::Contract::Step::Result),
                        "Step.run should always return a Result, not raise"
      expect(result.status).to eq(:input_error),
                               "Missing prompt should produce :input_error status"
      expect(result.validation_errors.first).to include("prompt has not been set"),
                                                "Error should mention missing prompt"
    end
  end

  # ---------------------------------------------------------------------------
  # BUG 49: context: { adapter: nil } -- explicit nil adapter.
  # ---------------------------------------------------------------------------
  describe "BUG 49: Explicit nil adapter in context" do
    it "falls through to default adapter when context[:adapter] is nil" do
      step = Class.new(RubyLLM::Contract::Step::Base) do
        prompt { user "{input}" }
      end

      expect do
        step.run("test", context: { adapter: nil })
      end.to raise_error(RubyLLM::Contract::Error, /No adapter configured/)
    end

    it "nil model is passed through without crash" do
      step = Class.new(RubyLLM::Contract::Step::Base) do
        prompt { user "{input}" }
        output_type String
      end

      adapter = RubyLLM::Contract::Adapters::Test.new(response: "ok")
      result = step.run("test", context: { adapter: adapter, model: nil })
      expect(result.status).to eq(:ok)
    end
  end

  # ---------------------------------------------------------------------------
  # BUG 50: context: { model: "" } -- empty string model.
  # ---------------------------------------------------------------------------
  describe "BUG 50: Empty string model in context" do
    it "passes empty string model to adapter without validation" do
      step = Class.new(RubyLLM::Contract::Step::Base) do
        prompt { user "{input}" }
        output_type String
      end

      adapter = RubyLLM::Contract::Adapters::Test.new(response: "ok")
      result = step.run("test", context: { adapter: adapter, model: "" })

      expect(result.status).to eq(:ok)
      expect(result.trace.model).to eq(""),
                                    "Empty string model is used as-is without validation"
    end
  end

  # ---------------------------------------------------------------------------
  # BUG 51: input_type with plain Ruby classes.
  # ---------------------------------------------------------------------------
  describe "BUG 51: input_type with plain Ruby classes" do
    it "input_type(Hash) accepts any hash" do
      step = Class.new(RubyLLM::Contract::Step::Base) do
        input_type Hash
        output_type String
        prompt { |i| user i.to_s }
      end

      adapter = RubyLLM::Contract::Adapters::Test.new(response: "ok")
      result = step.run({ any: "hash", works: true }, context: { adapter: adapter })
      expect(result.status).to eq(:ok)
    end

    it "input_type(String) rejects Integer with clear error" do
      step = Class.new(RubyLLM::Contract::Step::Base) do
        input_type String
        prompt { |i| user i.to_s }
      end

      adapter = RubyLLM::Contract::Adapters::Test.new(response: "ok")
      result = step.run(42, context: { adapter: adapter })

      expect(result.status).to eq(:input_error)
      expect(result.validation_errors.first).to include("String"),
                                                "Error should mention expected type String"
    end

    it "default input_type is String" do
      step = Class.new(RubyLLM::Contract::Step::Base) do
        prompt { user "{input}" }
      end

      expect(step.input_type).to eq(String)
    end

    it "default input_type rejects non-String input" do
      step = Class.new(RubyLLM::Contract::Step::Base) do
        output_type String
        prompt { |i| user i.to_s }
      end

      adapter = RubyLLM::Contract::Adapters::Test.new(response: "ok")
      result = step.run(42, context: { adapter: adapter })
      expect(result.status).to eq(:input_error)
    end
  end

  # ---------------------------------------------------------------------------
  # BUG 52: Default output_type is Hash, forcing JSON parsing.
  # ---------------------------------------------------------------------------
  describe "BUG 52: Default output_type is Hash, forcing JSON parsing" do
    it "default output_type is plain Ruby Hash" do
      step = Class.new(RubyLLM::Contract::Step::Base) do
        prompt { user "{input}" }
      end

      expect(step.output_type).to eq(Hash)
    end

    it "default output_type forces JSON parse on plain text response" do
      step = Class.new(RubyLLM::Contract::Step::Base) do
        prompt { user "{input}" }
      end

      adapter = RubyLLM::Contract::Adapters::Test.new(response: "just plain text")
      result = step.run("test", context: { adapter: adapter })

      expect(result.status).to eq(:parse_error),
                               "Default Hash output_type forces JSON parsing, " \
                               "causing parse_error on plain text response. " \
                               "Got: #{result.status}"
    end

    it "explicit output_type String allows plain text response" do
      step = Class.new(RubyLLM::Contract::Step::Base) do
        prompt { user "{input}" }
        output_type String
      end

      adapter = RubyLLM::Contract::Adapters::Test.new(response: "just plain text")
      result = step.run("test", context: { adapter: adapter })

      expect(result.status).to eq(:ok)
      expect(result.parsed_output).to eq("just plain text")
    end
  end

  # ---------------------------------------------------------------------------
  # BUG 53: raw_output type is not always String.
  # ---------------------------------------------------------------------------
  describe "BUG 53: raw_output type is not always String" do
    it "raw_output is a Hash when adapter returns Hash" do
      step = Class.new(RubyLLM::Contract::Step::Base) do
        prompt { user "{input}" }
        output_type RubyLLM::Contract::Types::Hash
        contract { parse :json }
      end

      adapter = RubyLLM::Contract::Adapters::Test.new(response: { "name" => "Alice" })
      result = step.run("test", context: { adapter: adapter })

      expect(result.status).to eq(:ok)
      expect(result.raw_output).to be_a(Hash),
                                   "raw_output is Hash when adapter returns Hash, not String"
    end

    it "raw_output is String when adapter returns String" do
      step = Class.new(RubyLLM::Contract::Step::Base) do
        prompt { user "{input}" }
        output_type RubyLLM::Contract::Types::Hash
        contract { parse :json }
      end

      adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"name": "Alice"}')
      result = step.run("test", context: { adapter: adapter })

      expect(result.status).to eq(:ok)
      expect(result.raw_output).to be_a(String)
    end

    it "raw_output from nil Test adapter response is empty string (normalize_response)" do
      step = Class.new(RubyLLM::Contract::Step::Base) do
        prompt { user "{input}" }
        output_type String
      end

      # Test adapter with response: nil -- normalize_response converts nil to ""
      adapter = RubyLLM::Contract::Adapters::Test.new(response: nil)
      result = step.run("test", context: { adapter: adapter })

      # normalize_response converts nil to "" so raw_output is ""
      expect(result.raw_output).to eq(""),
                                   "Test adapter normalize_response converts nil to empty string"
    end
  end

  # ---------------------------------------------------------------------------
  # BUG 54: Eval::Report score and passed? edge cases.
  # ---------------------------------------------------------------------------
  describe "BUG 54: Report score/passed edge cases" do
    it "score is 0.0 to 1.0 range with normal results" do
      results = [
        RubyLLM::Contract::Eval::CaseResult.new(
          name: "a", input: "test", output: nil, expected: nil,
          step_status: :ok, score: 1.0, passed: true
        ),
        RubyLLM::Contract::Eval::CaseResult.new(
          name: "b", input: "test", output: nil, expected: nil,
          step_status: :ok, score: 0.0, passed: false
        )
      ]
      report = RubyLLM::Contract::Eval::Report.new(dataset_name: "test", results: results)

      expect(report.score).to be_between(0.0, 1.0)
      expect(report.score).to eq(0.5)
    end

    it "passed? is false when any result fails" do
      results = [
        RubyLLM::Contract::Eval::CaseResult.new(
          name: "a", input: "test", output: nil, expected: nil,
          step_status: :ok, score: 1.0, passed: true
        ),
        RubyLLM::Contract::Eval::CaseResult.new(
          name: "b", input: "test", output: nil, expected: nil,
          step_status: :ok, score: 0.0, passed: false
        )
      ]
      report = RubyLLM::Contract::Eval::Report.new(dataset_name: "test", results: results)

      expect(report.passed?).to be false
    end

    it "passed? is true only when ALL results pass" do
      results = [
        RubyLLM::Contract::Eval::CaseResult.new(
          name: "a", input: "test", output: nil, expected: nil,
          step_status: :ok, score: 1.0, passed: true
        ),
        RubyLLM::Contract::Eval::CaseResult.new(
          name: "b", input: "test", output: nil, expected: nil,
          step_status: :ok, score: 0.8, passed: true
        )
      ]
      report = RubyLLM::Contract::Eval::Report.new(dataset_name: "test", results: results)

      expect(report.passed?).to be true
      expect(report.score).to eq(0.9)
    end

    it "pass_rate returns correct format" do
      results = [
        RubyLLM::Contract::Eval::CaseResult.new(
          name: "a", input: "test", output: nil, expected: nil,
          step_status: :ok, score: 1.0, passed: true
        ),
        RubyLLM::Contract::Eval::CaseResult.new(
          name: "b", input: "test", output: nil, expected: nil,
          step_status: :ok, score: 0.0, passed: false
        ),
        RubyLLM::Contract::Eval::CaseResult.new(
          name: "c", input: "test", output: nil, expected: nil,
          step_status: :ok, score: 1.0, passed: true
        )
      ]
      report = RubyLLM::Contract::Eval::Report.new(dataset_name: "test", results: results)

      expect(report.pass_rate).to eq("2/3")
      expect(report.passed).to eq(2)
      expect(report.failed).to eq(1)
    end
  end

  # ---------------------------------------------------------------------------
  # BUG 55: Pipeline eval support.
  # ---------------------------------------------------------------------------
  describe "BUG 55: Pipeline eval support" do
    it "Pipeline::Base has run_eval class method" do
      expect(RubyLLM::Contract::Pipeline::Base).to respond_to(:run_eval)
    end

    it "Pipeline::Base has define_eval class method" do
      expect(RubyLLM::Contract::Pipeline::Base).to respond_to(:define_eval)
    end

    it "run_eval on pipeline with no evals returns empty hash" do
      pipeline = Class.new(RubyLLM::Contract::Pipeline::Base)
      result = pipeline.run_eval
      expect(result).to eq({})
    end
  end

  # ---------------------------------------------------------------------------
  # BUG 56: Step class inheritance does not carry DSL state.
  # ---------------------------------------------------------------------------
  describe "BUG 56 (FIXED): Step class inheritance carries DSL state" do
    it "child class inherits parent prompt" do
      parent = Class.new(RubyLLM::Contract::Step::Base) do
        prompt { user "parent prompt" }
      end

      child = Class.new(parent)

      expect { child.prompt }.not_to raise_error
      expect(child.prompt).to eq(parent.prompt)
    end

    it "child class inherits parent input_type" do
      parent = Class.new(RubyLLM::Contract::Step::Base) do
        input_type Hash
      end

      child = Class.new(parent)

      expect(child.input_type).to eq(Hash),
                                  "Child class should inherit parent's Hash input_type"
    end

    it "child class inherits parent contract" do
      parent = Class.new(RubyLLM::Contract::Step::Base) do
        contract do
          parse :json
          invariant("always true") { |_o| true }
        end
      end

      child = Class.new(parent)

      expect(child.contract.invariants).not_to be_empty,
                                               "Child class should inherit parent's invariants"
      expect(child.contract.parse_strategy).to eq(:json),
                                               "Child class should inherit parent's :json parse strategy"
    end
  end

  # ---------------------------------------------------------------------------
  # BUG 57: Unknown context keys produce a warning, not an error.
  # ---------------------------------------------------------------------------
  describe "BUG 57: Unknown context keys behavior" do
    it "warns about unknown keys but does not crash" do
      step = Class.new(RubyLLM::Contract::Step::Base) do
        prompt { user "{input}" }
        output_type String
      end

      adapter = RubyLLM::Contract::Adapters::Test.new(response: "ok")
      warnings = []
      # warn is dispatched on the Step class singleton (private Kernel method)
      allow(step).to receive(:warn) { |msg| warnings << msg }

      result = step.run("test", context: { adapter: adapter, unknown_key: true, another: 42 })

      expect(result.status).to eq(:ok)
      expect(warnings.join(" ")).to include("Unknown context keys"),
                                    "Should warn about unknown context keys"
    end

    it "lists the unknown keys in the warning" do
      step = Class.new(RubyLLM::Contract::Step::Base) do
        prompt { user "{input}" }
        output_type String
      end

      adapter = RubyLLM::Contract::Adapters::Test.new(response: "ok")
      warnings = []
      allow(step).to receive(:warn) { |msg| warnings << msg }

      step.run("test", context: { adapter: adapter, foo_bar: true })

      expect(warnings.join(" ")).to include("foo_bar"),
                                    "Warning should mention the specific unknown key"
    end

    it "does not warn when all keys are known" do
      step = Class.new(RubyLLM::Contract::Step::Base) do
        prompt { user "{input}" }
        output_type String
      end

      adapter = RubyLLM::Contract::Adapters::Test.new(response: "ok")
      warnings = []
      allow(step).to receive(:warn) { |msg| warnings << msg }

      step.run("test", context: { adapter: adapter, model: "gpt-4" })

      expect(warnings).to be_empty,
                          "Should not warn when all context keys are known"
    end
  end

  # ---------------------------------------------------------------------------
  # BUG 58: RetryPolicy block form defaults to 1 attempt (no retry).
  # ---------------------------------------------------------------------------
  describe "BUG 58: RetryPolicy block form defaults to 1 attempt (no retry)" do
    it "block form defaults to max_attempts 1 (no actual retry)" do
      policy = RubyLLM::Contract::Step::RetryPolicy.new do
        retry_on :parse_error
      end

      expect(policy.max_attempts).to eq(1),
                                     "Block form defaults to 1 attempt, meaning NO retry occurs"
    end

    it "block form with explicit attempts: 3 does retry" do
      policy = RubyLLM::Contract::Step::RetryPolicy.new do
        attempts 3
        retry_on :parse_error
      end

      expect(policy.max_attempts).to eq(3)
    end

    it "keyword form with no attempts defaults to 1" do
      policy = RubyLLM::Contract::Step::RetryPolicy.new(retry_on: [:parse_error])

      expect(policy.max_attempts).to eq(1)
    end

    it "documents that a step with block retry_policy (no attempts) does not actually retry" do
      step = Class.new(RubyLLM::Contract::Step::Base) do
        input_type String
        output_type RubyLLM::Contract::Types::Hash
        contract { parse :json }
        prompt { |input| user "Process: #{input}" }
        retry_policy do
          retry_on :parse_error
          # NOTE: no `attempts` call -- defaults to 1
        end
      end

      call_count = 0
      adapter = Class.new(RubyLLM::Contract::Adapters::Base) do
        define_method(:call) do |**_opts|
          call_count += 1
          RubyLLM::Contract::Adapters::Response.new(
            content: "not json",
            usage: { input_tokens: 0, output_tokens: 0 }
          )
        end
      end.new

      result = step.run("test", context: { adapter: adapter })

      expect(result.status).to eq(:parse_error)
      expect(call_count).to eq(1),
                            "With default max_attempts=1, adapter is only called once -- no retry"
    end
  end

  # ---------------------------------------------------------------------------
  # BUG 59: EvaluationResult#score is clamped to 0.0..1.0.
  # ---------------------------------------------------------------------------
  describe "BUG 59: EvaluationResult clamps score to 0.0..1.0" do
    it "clamps score > 1.0 to 1.0" do
      result = RubyLLM::Contract::Eval::EvaluationResult.new(score: 2.5, passed: true)
      expect(result.score).to eq(1.0),
                              "Score 2.5 should be clamped to 1.0"
    end

    it "clamps score < 0.0 to 0.0" do
      result = RubyLLM::Contract::Eval::EvaluationResult.new(score: -0.5, passed: false)
      expect(result.score).to eq(0.0),
                              "Score -0.5 should be clamped to 0.0"
    end

    it "keeps score within range unchanged" do
      result = RubyLLM::Contract::Eval::EvaluationResult.new(score: 0.75, passed: true)
      expect(result.score).to eq(0.75)
    end
  end

  # ---------------------------------------------------------------------------
  # BUG 60: Pipeline#test with missing step responses.
  # ---------------------------------------------------------------------------
  describe "BUG 60: Pipeline#test with missing step responses" do
    it "uses empty string for unmapped steps" do
      step_a = Class.new(RubyLLM::Contract::Step::Base) do
        prompt { user "{input}" }
        output_type RubyLLM::Contract::Types::Hash
        contract { parse :json }
      end

      step_b = Class.new(RubyLLM::Contract::Step::Base) do
        input_type RubyLLM::Contract::Types::Hash
        output_type RubyLLM::Contract::Types::Hash
        contract { parse :json }
        prompt { |i| user i.to_json }
      end

      pipeline = Class.new(RubyLLM::Contract::Pipeline::Base) do
        step step_a, as: :first
        step step_b, as: :second
      end

      result = pipeline.test("hello", responses: { first: '{"ok": true}' })

      expect(result.failed?).to be true
      expect(result.failed_step).to eq(:second)
    end
  end

  # ---------------------------------------------------------------------------
  # BUG 61: Invariant truthiness semantics.
  # ---------------------------------------------------------------------------
  describe "BUG 61: Invariant truthiness semantics" do
    it "treats any truthy return as pass" do
      step = Class.new(RubyLLM::Contract::Step::Base) do
        prompt { user "{input}" }
        output_type RubyLLM::Contract::Types::Hash
        contract { parse :json }
        validate("returns a string") { |_o| "this is an error message" }
      end

      adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"x": 1}')
      result = step.run("test", context: { adapter: adapter })

      expect(result.status).to eq(:ok),
                               "Truthy string return from validate is treated as pass"
    end

    it "treats 0 as truthy (pass)" do
      step = Class.new(RubyLLM::Contract::Step::Base) do
        prompt { user "{input}" }
        output_type RubyLLM::Contract::Types::Hash
        contract { parse :json }
        validate("returns zero") { |_o| 0 }
      end

      adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"x": 1}')
      result = step.run("test", context: { adapter: adapter })

      expect(result.status).to eq(:ok),
                               "0 is truthy in Ruby, so validate { 0 } passes"
    end
  end

  # ---------------------------------------------------------------------------
  # BUG 62: max_cost(0) with no pricing data -- silently ignored.
  # ---------------------------------------------------------------------------
  describe "BUG 62 (FIXED): max_cost(0) raises at definition time" do
    it "raises ArgumentError for max_cost(0)" do
      expect do
        Class.new(RubyLLM::Contract::Step::Base) do
          prompt { user "{input}" }
          output_type String
          max_cost(0)
        end
      end.to raise_error(ArgumentError, /max_cost must be positive/)
    end
  end

  # ---------------------------------------------------------------------------
  # BUG 63: EvalDefinition#verify validation.
  # ---------------------------------------------------------------------------
  describe "BUG 63: verify without input raises ArgumentError" do
    it "raises when no default_input and no input: keyword" do
      expect do
        RubyLLM::Contract::Eval::EvalDefinition.new("test") do
          verify "check something", ->(o) { o }
        end
      end.to raise_error(ArgumentError, /verify requires input/)
    end

    it "raises when no expected and no expect: keyword" do
      expect do
        RubyLLM::Contract::Eval::EvalDefinition.new("test") do
          default_input "hello"
          verify "check something"
        end
      end.to raise_error(ArgumentError, /verify requires either/)
    end
  end
end
