# frozen_string_literal: true

RSpec.describe "Technical audit findings" do
  before { RubyLLM::Contract.reset_configuration! }

  # -------------------------------------------------------------------------
  # FINDING 1 (HIGH): Retry trace cost calculated from last model, not per-attempt
  # -------------------------------------------------------------------------
  describe "FINDING 1: retry trace cost and latency aggregation" do
    it "calculates cost per-attempt and sums them, not using last model pricing for all tokens" do
      # Simulate two models with different pricing by stubbing CostCalculator
      # nano: $0.10/M input, $0.10/M output => 100 input + 50 output = $0.000015
      # full: $2.00/M input, $2.00/M output => 100 input + 50 output = $0.000300
      # Correct total: $0.000015 + $0.000300 = $0.000315
      # Bug total (all tokens at full pricing): (200 input + 100 output) at $2.00/M = $0.000600

      call_count = 0
      adapter = Object.new
      adapter.define_singleton_method(:call) do |**opts|
        call_count += 1
        # All attempts fail validation so we get retry with escalation
        RubyLLM::Contract::Adapters::Response.new(
          content: '{"key": ""}',
          usage: { input_tokens: 100, output_tokens: 50 }
        )
      end

      step = Class.new(RubyLLM::Contract::Step::Base) do
        input_type RubyLLM::Contract::Types::String
        output_type RubyLLM::Contract::Types::Hash
        prompt { user "{input}" }
        contract do
          parse :json
          invariant("always fails") { |_o| false }
        end
        retry_policy models: %w[gpt-4.1-nano gpt-4.1]
      end

      # Stub CostCalculator to return known per-model costs
      nano_cost = 0.000015
      full_cost = 0.000300

      allow(RubyLLM::Contract::CostCalculator).to receive(:calculate).and_call_original
      allow(RubyLLM::Contract::CostCalculator).to receive(:calculate)
        .with(model_name: "gpt-4.1-nano", usage: { input_tokens: 100, output_tokens: 50 })
        .and_return(nano_cost)
      allow(RubyLLM::Contract::CostCalculator).to receive(:calculate)
        .with(model_name: "gpt-4.1", usage: { input_tokens: 100, output_tokens: 50 })
        .and_return(full_cost)

      # The bug: cost is recalculated from last model ("gpt-4.1") with aggregated tokens (200+100)
      # which would give $0.000600 instead of $0.000315
      # Also stub the buggy call to verify it's NOT used:
      allow(RubyLLM::Contract::CostCalculator).to receive(:calculate)
        .with(model_name: "gpt-4.1", usage: { input_tokens: 200, output_tokens: 100 })
        .and_return(0.000600)

      result = step.run("test", context: { adapter: adapter })

      expect(result.trace.cost).to be_within(0.000001).of(nano_cost + full_cost)
    end

    it "sums latency_ms across all attempts, not just last" do
      call_count = 0
      adapter = Object.new
      adapter.define_singleton_method(:call) do |**_opts|
        call_count += 1
        sleep(0.02) # 20ms each call
        RubyLLM::Contract::Adapters::Response.new(
          content: '{"key": ""}',
          usage: { input_tokens: 10, output_tokens: 5 }
        )
      end

      step = Class.new(RubyLLM::Contract::Step::Base) do
        input_type RubyLLM::Contract::Types::String
        output_type RubyLLM::Contract::Types::Hash
        prompt { user "{input}" }
        contract do
          parse :json
          invariant("always fails") { |_o| false }
        end
        retry_policy { attempts 3 }
      end

      result = step.run("test", context: { adapter: adapter })

      # With 3 attempts at ~20ms each, total should be >= 50ms (allowing some overhead)
      # The bug would only report the last attempt's latency (~20ms)
      expect(result.trace.latency_ms).to be >= 50
    end

    it "records per-attempt cost in attempt entries" do
      call_count = 0
      adapter = Object.new
      adapter.define_singleton_method(:call) do |**_opts|
        call_count += 1
        RubyLLM::Contract::Adapters::Response.new(
          content: '{"key": ""}',
          usage: { input_tokens: 100, output_tokens: 50 }
        )
      end

      step = Class.new(RubyLLM::Contract::Step::Base) do
        input_type RubyLLM::Contract::Types::String
        output_type RubyLLM::Contract::Types::Hash
        prompt { user "{input}" }
        contract do
          parse :json
          invariant("always fails") { |_o| false }
        end
        retry_policy models: %w[nano full]
      end

      allow(RubyLLM::Contract::CostCalculator).to receive(:calculate).and_return(nil)
      allow(RubyLLM::Contract::CostCalculator).to receive(:calculate)
        .with(model_name: "nano", usage: { input_tokens: 100, output_tokens: 50 })
        .and_return(0.000015)
      allow(RubyLLM::Contract::CostCalculator).to receive(:calculate)
        .with(model_name: "full", usage: { input_tokens: 100, output_tokens: 50 })
        .and_return(0.000300)

      result = step.run("test", context: { adapter: adapter })
      attempts = result.trace[:attempts]

      expect(attempts[0]).to have_key(:cost)
      expect(attempts[0][:cost]).to eq(0.000015)
      expect(attempts[1]).to have_key(:cost)
      expect(attempts[1][:cost]).to eq(0.000300)
    end
  end

  # -------------------------------------------------------------------------
  # FINDING 2 (HIGH): timeout_ms checked only after step completes
  # -------------------------------------------------------------------------
  describe "FINDING 2: cooperative timeout documentation" do
    it "has a comment in Runner explaining cooperative timeout behavior" do
      gem_root = File.expand_path("../../..", __dir__)
      source = File.read(File.join(gem_root, "lib/ruby_llm/contract/pipeline/runner.rb"))
      expect(source).to include("cooperative timeout")
    end
  end

  # -------------------------------------------------------------------------
  # FINDING 3 (HIGH): DSL state doesn't inherit to subclasses
  # -------------------------------------------------------------------------
  describe "FINDING 3: DSL state inheritance to subclasses" do
    let(:parent_step) do
      Class.new(RubyLLM::Contract::Step::Base) do
        input_type RubyLLM::Contract::Types::String
        output_type RubyLLM::Contract::Types::Hash
        prompt { user "Parent prompt: {input}" }
        contract do
          parse :json
          invariant("has key") { |o| o[:key].to_s != "" }
        end
        validate("extra check") { |o| o[:extra] != "bad" }
        max_output 1000
        max_input 5000
        max_cost 0.50
      end
    end

    let(:child_step) do
      parent = parent_step
      Class.new(parent)
    end

    it "inherits prompt from parent" do
      expect { child_step.prompt }.not_to raise_error
      expect(child_step.prompt).to eq(parent_step.prompt)
    end

    it "inherits input_type from parent" do
      expect(child_step.input_type).to eq(RubyLLM::Contract::Types::String)
    end

    it "inherits output_type from parent" do
      expect(child_step.output_type).to eq(RubyLLM::Contract::Types::Hash)
    end

    it "inherits max_output from parent" do
      expect(child_step.max_output).to eq(1000)
    end

    it "inherits max_input from parent" do
      expect(child_step.max_input).to eq(5000)
    end

    it "inherits max_cost from parent" do
      expect(child_step.max_cost).to eq(0.50)
    end

    it "inherits contract from parent" do
      expect(child_step.contract).to be_a(RubyLLM::Contract::Definition)
    end

    it "child can override parent DSL without affecting parent" do
      parent = parent_step
      child = Class.new(parent) do
        max_output 2000
      end

      expect(child.max_output).to eq(2000)
      expect(parent.max_output).to eq(1000)
    end

    it "child inherits validate blocks from parent effective_contract" do
      adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"key": "value", "extra": "bad"}')
      result = child_step.run("test", context: { adapter: adapter })

      # The parent validate("extra check") should be inherited
      expect(result.status).to eq(:validation_failed)
      expect(result.validation_errors).to include("extra check")
    end

    it "child step can run with parent's DSL" do
      adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"key": "value", "extra": "good"}')
      result = child_step.run("test", context: { adapter: adapter })

      expect(result.status).to eq(:ok)
    end

    it "inherits eval_definitions from parent" do
      parent = Class.new(RubyLLM::Contract::Step::Base) do
        prompt "test {input}"
      end
      parent.define_eval("smoke") do
        default_input "test"
      end

      child = Class.new(parent)

      # Child should see parent's eval definitions
      expect { child.run_eval("smoke", context: { adapter: RubyLLM::Contract::Adapters::Test.new(response: "ok") }) }
        .not_to raise_error(ArgumentError)
    end

    it "inherits retry_policy from parent" do
      parent = Class.new(RubyLLM::Contract::Step::Base) do
        input_type RubyLLM::Contract::Types::String
        output_type RubyLLM::Contract::Types::Hash
        prompt { user "{input}" }
        contract { parse :json }
        retry_policy { attempts 3 }
      end

      child = Class.new(parent)
      expect(child.retry_policy).not_to be_nil
      expect(child.retry_policy.max_attempts).to eq(3)
    end
  end

  # -------------------------------------------------------------------------
  # FINDING 4 (MEDIUM): Pipeline steps mutable + empty pipeline returns :ok
  # -------------------------------------------------------------------------
  describe "FINDING 4: pipeline steps immutability and empty pipeline" do
    it "does not allow mutating pipeline steps from outside" do
      s1 = Class.new(RubyLLM::Contract::Step::Base) do
        input_type RubyLLM::Contract::Types::String
        prompt { user "{input}" }
      end

      pipeline = Class.new(RubyLLM::Contract::Pipeline::Base)
      pipeline.step s1, as: :first

      expect { pipeline.steps.push({ step_class: Object, alias: :injected }) }.to raise_error(FrozenError)
    end

    it "raises ArgumentError when running an empty pipeline" do
      pipeline = Class.new(RubyLLM::Contract::Pipeline::Base)
      adapter = RubyLLM::Contract::Adapters::Test.new(response: "test")

      expect { pipeline.run("input", context: { adapter: adapter }) }
        .to raise_error(ArgumentError, /no steps defined/i)
    end
  end

  # -------------------------------------------------------------------------
  # FINDING 5 (MEDIUM): Negative limits accepted without fail-fast
  # -------------------------------------------------------------------------
  describe "FINDING 5: negative limits fail-fast validation" do
    it "raises ArgumentError for negative max_input" do
      expect do
        Class.new(RubyLLM::Contract::Step::Base) do
          max_input(-1)
        end
      end.to raise_error(ArgumentError, /max_input must be positive/)
    end

    it "raises ArgumentError for zero max_input" do
      expect do
        Class.new(RubyLLM::Contract::Step::Base) do
          max_input(0)
        end
      end.to raise_error(ArgumentError, /max_input must be positive/)
    end

    it "raises ArgumentError for negative max_output" do
      expect do
        Class.new(RubyLLM::Contract::Step::Base) do
          max_output(-5)
        end
      end.to raise_error(ArgumentError, /max_output must be positive/)
    end

    it "raises ArgumentError for zero max_output" do
      expect do
        Class.new(RubyLLM::Contract::Step::Base) do
          max_output(0)
        end
      end.to raise_error(ArgumentError, /max_output must be positive/)
    end

    it "raises ArgumentError for negative max_cost" do
      expect do
        Class.new(RubyLLM::Contract::Step::Base) do
          max_cost(-0.01)
        end
      end.to raise_error(ArgumentError, /max_cost must be positive/)
    end

    it "raises ArgumentError for zero max_cost" do
      expect do
        Class.new(RubyLLM::Contract::Step::Base) do
          max_cost(0)
        end
      end.to raise_error(ArgumentError, /max_cost must be positive/)
    end

    it "accepts valid positive max_input" do
      expect do
        Class.new(RubyLLM::Contract::Step::Base) do
          max_input(100)
        end
      end.not_to raise_error
    end

    it "accepts valid positive max_output" do
      expect do
        Class.new(RubyLLM::Contract::Step::Base) do
          max_output(100)
        end
      end.not_to raise_error
    end

    it "accepts valid positive max_cost" do
      expect do
        Class.new(RubyLLM::Contract::Step::Base) do
          max_cost(0.50)
        end
      end.not_to raise_error
    end

    it "raises ArgumentError for non-numeric max_input" do
      expect do
        Class.new(RubyLLM::Contract::Step::Base) do
          max_input("foo")
        end
      end.to raise_error(ArgumentError, /max_input must be positive/)
    end

    it "raises ArgumentError for non-numeric max_output" do
      expect do
        Class.new(RubyLLM::Contract::Step::Base) do
          max_output("bar")
        end
      end.to raise_error(ArgumentError, /max_output must be positive/)
    end

    it "raises ArgumentError for non-numeric max_cost" do
      expect do
        Class.new(RubyLLM::Contract::Step::Base) do
          max_cost("baz")
        end
      end.to raise_error(ArgumentError, /max_cost must be positive/)
    end
  end

  # -------------------------------------------------------------------------
  # FINDING 6 (MEDIUM): Report#passed? returns true for empty results
  # -------------------------------------------------------------------------
  describe "FINDING 6: Report#passed? for empty results" do
    it "returns false when results are empty" do
      report = RubyLLM::Contract::Eval::Report.new(dataset_name: "empty", results: [])
      expect(report.passed?).to be false
    end

    it "returns true when all results pass" do
      report = RubyLLM::Contract::Eval::Report.new(
        dataset_name: "good",
        results: [
          RubyLLM::Contract::Eval::CaseResult.new(
            name: "a", input: nil, output: nil, expected: nil,
            step_status: :ok, score: 1.0, passed: true, details: "passed"
          )
        ]
      )
      expect(report.passed?).to be true
    end

    it "returns false when some results fail" do
      report = RubyLLM::Contract::Eval::Report.new(
        dataset_name: "mixed",
        results: [
          RubyLLM::Contract::Eval::CaseResult.new(
            name: "a", input: nil, output: nil, expected: nil,
            step_status: :ok, score: 1.0, passed: true, details: "passed"
          ),
          RubyLLM::Contract::Eval::CaseResult.new(
            name: "b", input: nil, output: nil, expected: nil,
            step_status: :ok, score: 0.0, passed: false, details: "not passed"
          )
        ]
      )
      expect(report.passed?).to be false
    end
  end

  # -------------------------------------------------------------------------
  # FINDING 7 (MEDIUM): ruby_llm-schema without version constraint
  # -------------------------------------------------------------------------
  describe "FINDING 7: ruby_llm-schema version constraint" do
    it "has a version constraint on ruby_llm-schema dependency" do
      gem_root = File.expand_path("../../..", __dir__)
      gemspec_content = File.read(File.join(gem_root, "ruby_llm-contract.gemspec"))

      # Should NOT have bare dependency without version
      expect(gemspec_content).not_to match(/add_dependency\s+"ruby_llm-schema"\s*$/)
      # Should have a version constraint
      expect(gemspec_content).to match(/add_dependency\s+"ruby_llm-schema",\s+"[~><=\d\s.]+"/)
    end
  end
end
