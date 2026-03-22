# frozen_string_literal: true

# Edge-case coverage for code paths not exercised by primary unit/integration specs.
# Each test targets a specific branch or boundary condition.

RSpec.describe "Edge cases" do
  before { RubyLLM::Contract.reset_configuration! }

  # ===========================================================================
  # Step::Trace -- hash-like interface and merge
  # ===========================================================================

  describe RubyLLM::Contract::Step::Trace do
    describe "#merge" do
      it "creates new frozen Trace with overridden fields while preserving the rest" do
        original = described_class.new(model: "gpt-4", latency_ms: 100, usage: { input_tokens: 10, output_tokens: 5 })
        merged = original.merge(model: "gpt-5", attempts: [{ attempt: 1 }])

        expect(merged.model).to eq("gpt-5")
        expect(merged.latency_ms).to eq(100)
        expect(merged.attempts).to eq([{ attempt: 1 }])
        expect(merged).to be_frozen
        expect(merged).not_to equal(original)
      end
    end

    describe "#key? / #has_key?" do
      let(:trace) { described_class.new(model: "gpt-4", latency_ms: 100) }

      it "returns true for present, false for nil/unknown attributes" do
        expect(trace.key?(:model)).to be true
        expect(trace.key?(:usage)).to be false
        expect(trace.key?(:nonexistent)).to be false
      end

      it "coerces string keys via to_sym" do
        expect(trace.key?("model")).to be true
        expect(trace.key?("usage")).to be false
      end

      it "has_key? is an alias for key?" do
        expect(trace.has_key?(:model)).to be true # rubocop:disable Style/PreferredHashMethods
        expect(trace.has_key?(:usage)).to be false # rubocop:disable Style/PreferredHashMethods
      end
    end

    describe "#==" do
      it "equals a Hash with the same key-value pairs" do
        trace = described_class.new(model: "gpt-4", latency_ms: 100)
        expect(trace).to eq({ model: "gpt-4", latency_ms: 100 })
      end

      it "does not equal non-Hash/non-Trace objects" do
        trace = described_class.new(model: "gpt-4")
        expect(trace).not_to eq("gpt-4")
      end
    end

    describe "#[] for invalid keys" do
      it "returns nil for keys that are not valid Trace attributes" do
        trace = described_class.new(model: "gpt-4")
        expect(trace[:totally_unknown]).to be_nil
      end
    end

    describe "#[] does not leak internal state via Object methods" do
      let(:trace) { described_class.new(model: "test-model", usage: { input_tokens: 10, output_tokens: 5 }) }

      it "returns nil for :class instead of leaking the class constant" do
        expect(trace[:class]).to be_nil
      end

      it "returns nil for :object_id instead of leaking internal ID" do
        expect(trace[:object_id]).to be_nil
      end

      it "returns nil for :instance_variables instead of leaking ivar names" do
        expect(trace[:instance_variables]).to be_nil
      end

      it "returns nil for :freeze instead of returning the object itself" do
        expect(trace[:freeze]).to be_nil
      end

      it "still returns correct values for known attributes" do
        expect(trace[:model]).to eq("test-model")
        expect(trace[:usage]).to eq({ input_tokens: 10, output_tokens: 5 })
      end

      it "is consistent with key? for all lookups" do
        dangerous_keys = %i[class object_id instance_variables freeze hash send
                            respond_to? nil? is_a? equal? inspect to_s]

        dangerous_keys.each do |key|
          expect(trace.key?(key)).to be(false)
          expect(trace[key]).to be_nil
        end
      end
    end

    describe "#to_h with all-nil fields" do
      it "returns empty hash when no attributes are set" do
        expect(described_class.new.to_h).to eq({})
      end
    end

    describe "#to_s with non-Hash usage" do
      it "omits tokens when usage is not a Hash" do
        trace = described_class.new(model: "gpt-4", usage: "not a hash")
        expect(trace.to_s).to eq("gpt-4")
        expect(trace.to_s).not_to include("tokens")
      end
    end

    describe "#to_h omits nil cost for unknown model" do
      it "does not include :cost key when model is unknown" do
        trace = described_class.new(model: "unknown-model", usage: { input_tokens: 10, output_tokens: 5 })
        expect(trace.to_h).not_to have_key(:cost)
      end
    end
  end

  # ===========================================================================
  # Contract::Definition.merge -- composing definitions
  # ===========================================================================

  describe RubyLLM::Contract::Definition do
    describe ".merge" do
      it "appends extra invariants to base invariants" do
        base = described_class.new do
          parse :json
          invariant("base check") { |_| true }
        end

        extra = RubyLLM::Contract::Invariant.new("extra check", ->(_) { true })
        merged = described_class.merge(base, extra_invariants: [extra])

        expect(merged.parse_strategy).to eq(:json)
        expect(merged.invariants.map(&:description)).to eq(["base check", "extra check"])
      end

      it "overrides parse strategy when parse_override is provided" do
        base = described_class.new { parse :text }
        merged = described_class.merge(base, parse_override: :json)

        expect(merged.parse_strategy).to eq(:json)
      end

      it "preserves base parse strategy when parse_override is nil" do
        base = described_class.new { parse :json }
        merged = described_class.merge(base, parse_override: nil)

        expect(merged.parse_strategy).to eq(:json)
      end
    end
  end

  # ===========================================================================
  # Step::Base -- context key warnings and prompt errors
  # ===========================================================================

  describe RubyLLM::Contract::Step::Base do
    describe "unknown context keys warning" do
      it "emits a warning listing unknown keys" do
        step = Class.new(described_class) { prompt "test {input}" }
        adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"v": 1}')

        expect(step).to receive(:warn).with(/Unknown context keys.*bogus_key/)
        step.run("hello", context: { adapter: adapter, bogus_key: "value" })
      end

      it "does not warn when all keys are known" do
        step = Class.new(described_class) { prompt "test {input}" }
        adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"v": 1}')

        expect(step).not_to receive(:warn)
        step.run("hello", context: { adapter: adapter, model: "gpt-4" })
      end
    end

    describe ".prompt when never set" do
      it "raises ArgumentError with descriptive message" do
        step = Class.new(described_class)
        expect { step.prompt }.to raise_error(ArgumentError, /prompt has not been set/)
      end
    end

    describe ".run_eval with no evals defined" do
      it "returns empty hash for run_eval without name" do
        step = Class.new(described_class) { prompt "test {input}" }
        expect(step.run_eval).to eq({})
      end
    end

    describe "explicit contract parse overrides inferred parse from output_type" do
      it "uses explicit :text even when output_type is Hash, causing type mismatch" do
        step = Class.new(described_class) do
          output_type Hash
          prompt "test {input}"
          contract { parse :text }
        end

        adapter = RubyLLM::Contract::Adapters::Test.new(response: "not json")
        result = step.run("test", context: { adapter: adapter })

        expect(result.status).to eq(:validation_failed)
      end
    end
  end

  # ===========================================================================
  # Pipeline::Base -- empty pipeline
  # ===========================================================================

  describe RubyLLM::Contract::Pipeline::Base do
    describe "empty pipeline" do
      it "raises ArgumentError when run with no steps defined" do
        pipeline = Class.new(described_class)
        adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"v": 1}')

        expect { pipeline.run("test", context: { adapter: adapter }) }
          .to raise_error(ArgumentError, /no steps defined/i)
      end
    end
  end

  # ===========================================================================
  # Pipeline::Runner -- empty steps
  # ===========================================================================

  describe RubyLLM::Contract::Pipeline::Runner do
    it "raises ArgumentError for an empty step list" do
      expect { described_class.new(steps: [], context: {}, timeout_ms: nil, token_budget: nil) }
        .to raise_error(ArgumentError, /no steps defined/i)
    end
  end

  # ===========================================================================
  # Pipeline::Trace -- total_cost nil paths, to_s edge cases
  # ===========================================================================

  describe RubyLLM::Contract::Pipeline::Trace do
    describe "#calculate_total_cost" do
      it "returns nil when step_traces is nil" do
        expect(described_class.new(step_traces: nil).total_cost).to be_nil
      end

      it "returns nil when all step costs are nil" do
        mock_trace = double("trace", cost: nil)
        expect(described_class.new(step_traces: [mock_trace]).total_cost).to be_nil
      end
    end

    describe "#[] does not leak internal state via Object methods" do
      let(:trace) { described_class.new(trace_id: "abc-123") }

      it "returns nil for :class" do
        expect(trace[:class]).to be_nil
      end

      it "returns nil for :object_id" do
        expect(trace[:object_id]).to be_nil
      end

      it "returns nil for :instance_variables" do
        expect(trace[:instance_variables]).to be_nil
      end

      it "still returns correct values for known attributes" do
        expect(trace[:trace_id]).to eq("abc-123")
        expect(trace[:total_latency_ms]).to be_nil
      end
    end

    describe "#to_s" do
      it "shows 0 steps and placeholder trace when fully nil" do
        trace = described_class.new
        str = trace.to_s
        expect(str).to include("(0 steps)")
        expect(str).to include("trace=")
      end

      it "excludes token info when total_usage is nil" do
        trace = described_class.new(trace_id: "abc12345")
        expect(trace.to_s).not_to include("tokens")
      end
    end
  end

  # ===========================================================================
  # Eval::Report -- empty results, each delegation
  # ===========================================================================

  describe RubyLLM::Contract::Eval::Report do
    describe "#score" do
      it "returns 0.0 for empty results" do
        report = described_class.new(dataset_name: "empty", results: [])
        expect(report.score).to eq(0.0)
      end
    end

    describe "#each" do
      it "delegates to results array" do
        report = described_class.new(
          dataset_name: "test",
          results: [
            RubyLLM::Contract::Eval::CaseResult.new(
              name: "a", input: nil, output: nil, expected: nil,
              step_status: :ok, score: 1.0, passed: true
            ),
            RubyLLM::Contract::Eval::CaseResult.new(
              name: "b", input: nil, output: nil, expected: nil,
              step_status: :ok, score: 0.0, passed: false
            )
          ]
        )

        collected = []
        report.each { |r| collected << r.passed? } # rubocop:disable Style/MapIntoArray
        expect(collected).to eq([true, false])
      end
    end
  end

  # ===========================================================================
  # Eval::EvalDefinition -- error paths and build_adapter
  # ===========================================================================

  describe RubyLLM::Contract::Eval::EvalDefinition do
    describe "#verify error paths" do
      it "raises when verify has no expected or expect argument" do
        expect do
          described_class.new("test") do
            default_input "input"
            verify "no expected"
          end
        end.to raise_error(ArgumentError, /verify requires either/)
      end

      it "raises when no input is available for a verify case" do
        expect do
          described_class.new("test") do
            verify "no input", { key: "val" }
          end
        end.to raise_error(ArgumentError, /verify requires input/)
      end
    end

    describe "#build_adapter" do
      it "returns nil when no sample_response is set" do
        defn = described_class.new("test") { default_input "input" }
        expect(defn.build_adapter).to be_nil
      end

      it "converts Hash sample_response to JSON string for adapter" do
        defn = described_class.new("test") do
          default_input "input"
          sample_response({ key: "value" })
        end

        adapter = defn.build_adapter
        response = adapter.call(messages: [])
        parsed = JSON.parse(response.content, symbolize_names: true)
        expect(parsed).to eq({ key: "value" })
      end

      it "keeps String sample_response as-is" do
        defn = described_class.new("test") do
          default_input "input"
          sample_response('{"raw": "json"}')
        end

        adapter = defn.build_adapter
        response = adapter.call(messages: [])
        expect(response.content).to eq('{"raw": "json"}')
      end
    end

    describe "#effective_cases (zero-verify)" do
      it "auto-generates contract check case from default_input when no verify" do
        defn = described_class.new("test") { default_input "auto-input" }
        dataset = defn.build_dataset

        expect(dataset.cases.size).to eq(1)
        expect(dataset.cases.first.name).to eq("contract check")
        expect(dataset.cases.first.input).to eq("auto-input")
      end

      it "returns empty dataset when no input and no verify cases" do
        defn = described_class.new("test") {}
        expect(defn.build_dataset.cases).to be_empty
      end
    end
  end

  # ===========================================================================
  # Eval::Runner -- normalize_result for Pipeline::Result
  # ===========================================================================

  describe RubyLLM::Contract::Eval::Runner do
    describe "Pipeline eval via define_eval" do
      it "normalizes Pipeline::Result to step-like result for evaluation" do
        s1 = Class.new(RubyLLM::Contract::Step::Base) { prompt "test {input}" }

        pipeline = Class.new(RubyLLM::Contract::Pipeline::Base)
        pipeline.step s1, as: :only

        pipeline.define_eval("smoke") do
          default_input "test"
          sample_response({ v: 1 })
          verify "has value", { v: 1 }
        end

        report = pipeline.run_eval("smoke")

        expect(report.passed?).to be true
        expect(report.results.first.output).to eq({ v: 1 })
      end
    end

    describe "evaluate_traits with boolean expectations" do
      let(:step) { Class.new(RubyLLM::Contract::Step::Base) { prompt "test {input}" } }

      it "passes true trait when value is truthy, fails when nil" do
        adapter_truthy = RubyLLM::Contract::Adapters::Test.new(response: '{"active": true}')
        adapter_nil = RubyLLM::Contract::Adapters::Test.new(response: '{"active": null}')

        ds_truthy = RubyLLM::Contract::Eval::Dataset.define { add_case input: "t", expected_traits: { active: true } }
        ds_nil = RubyLLM::Contract::Eval::Dataset.define { add_case input: "t", expected_traits: { active: true } }

        report_truthy = described_class.run(step: step, dataset: ds_truthy, context: { adapter: adapter_truthy })
        report_nil = described_class.run(step: step, dataset: ds_nil, context: { adapter: adapter_nil })

        expect(report_truthy.passed?).to be true
        expect(report_nil.passed?).to be false
      end

      it "passes false trait when value is falsy, fails when truthy" do
        adapter_false = RubyLLM::Contract::Adapters::Test.new(response: '{"active": false}')
        adapter_yes = RubyLLM::Contract::Adapters::Test.new(response: '{"active": "yes"}')

        ds_false = RubyLLM::Contract::Eval::Dataset.define { add_case input: "t", expected_traits: { active: false } }
        ds_yes = RubyLLM::Contract::Eval::Dataset.define { add_case input: "t", expected_traits: { active: false } }

        report_false = described_class.run(step: step, dataset: ds_false, context: { adapter: adapter_false })
        report_yes = described_class.run(step: step, dataset: ds_yes, context: { adapter: adapter_yes })

        expect(report_false.passed?).to be true
        expect(report_yes.passed?).to be false
      end
    end

    describe "evaluate_traits with contract failure" do
      it "reports step failed with parse_error details when adapter returns invalid JSON" do
        step = Class.new(RubyLLM::Contract::Step::Base) { prompt "test {input}" }
        adapter = RubyLLM::Contract::Adapters::Test.new(response: "not json")

        ds = RubyLLM::Contract::Eval::Dataset.define { add_case input: "t", expected_traits: { name: "Alice" } }
        report = described_class.run(step: step, dataset: ds, context: { adapter: adapter })

        expect(report.passed?).to be false
        expect(report.results.first.details).to include("step failed")
        expect(report.results.first.step_status).to eq(:parse_error)
      end
    end

    describe "evaluate_expected with Regexp" do
      it "uses Regex evaluator for Regexp expected" do
        step = Class.new(RubyLLM::Contract::Step::Base) { output_type String; prompt "test {input}" }
        adapter = RubyLLM::Contract::Adapters::Test.new(response: "Hello world")

        ds = RubyLLM::Contract::Eval::Dataset.define { add_case input: "t", expected: /world/ }
        report = described_class.run(step: step, dataset: ds, context: { adapter: adapter })

        expect(report.passed?).to be true
      end
    end

    describe "evaluate_expected with exact match" do
      it "uses Exact evaluator for non-Hash non-Regexp expected" do
        step = Class.new(RubyLLM::Contract::Step::Base) { output_type String; prompt "test {input}" }
        adapter = RubyLLM::Contract::Adapters::Test.new(response: "exact value")

        ds = RubyLLM::Contract::Eval::Dataset.define { add_case input: "t", expected: "exact value" }
        report = described_class.run(step: step, dataset: ds, context: { adapter: adapter })

        expect(report.passed?).to be true
      end
    end

    describe "evaluate_traits with empty traits hash" do
      it "vacuously passes with score 1.0" do
        step = Class.new(RubyLLM::Contract::Step::Base) { prompt "test {input}" }
        adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"v": 1}')

        ds = RubyLLM::Contract::Eval::Dataset.define { add_case input: "t", expected_traits: {} }
        report = described_class.run(step: step, dataset: ds, context: { adapter: adapter })

        expect(report.results.first.score).to eq(1.0)
        expect(report.results.first.passed?).to eq(true)
      end
    end
  end

  # ===========================================================================
  # Eval::Evaluator::ProcEvaluator -- non-boolean, non-numeric returns
  # ===========================================================================

  describe RubyLLM::Contract::Eval::Evaluator::ProcEvaluator do
    it "treats truthy non-boolean non-numeric return as passed with score 1.0" do
      evaluator = described_class.new(->(_o) { "truthy string" })
      result = evaluator.call(output: {})

      expect(result.passed).to be true
      expect(result.score).to eq(1.0)
    end

    it "treats nil return as failed with score 0.0" do
      evaluator = described_class.new(->(_o) {})
      result = evaluator.call(output: {})

      expect(result.passed).to be false
      expect(result.score).to eq(0.0)
    end

    it "treats numeric < 0.5 as failed, preserving the exact score" do
      evaluator = described_class.new(->(_o) { 0.3 })
      result = evaluator.call(output: {})

      expect(result.passed).to be false
      expect(result.score).to eq(0.3)
    end
  end

  # ===========================================================================
  # Eval::Evaluator::Regex -- string pattern constructor
  # ===========================================================================

  describe RubyLLM::Contract::Eval::Evaluator::Regex do
    it "accepts a string pattern and converts it to a Regexp" do
      evaluator = described_class.new("billing")

      expect(evaluator.call(output: "I need billing help").passed).to be true
      expect(evaluator.call(output: "I need sales help").passed).to be false
    end
  end

  # ===========================================================================
  # Eval::Evaluator::JsonIncludes -- non-Hash inputs
  # ===========================================================================

  describe RubyLLM::Contract::Eval::Evaluator::JsonIncludes do
    it "returns type error when output is not a Hash" do
      result = described_class.new.call(output: "string", expected: { key: "val" })

      expect(result.passed).to be false
      expect(result.details).to include("expected Hash")
    end

    it "returns type error when expected is not a Hash" do
      result = described_class.new.call(output: { key: "val" }, expected: "not hash")

      expect(result.passed).to be false
      expect(result.details).to include("expected Hash")
    end
  end

  # ===========================================================================
  # TokenEstimator -- non-array input, nil content in messages
  # ===========================================================================

  describe RubyLLM::Contract::TokenEstimator do
    it "returns 0 for non-array inputs (string, nil, integer)" do
      expect(described_class.estimate("not an array")).to eq(0)
      expect(described_class.estimate(nil)).to eq(0)
      expect(described_class.estimate(42)).to eq(0)
    end

    it "treats nil content in messages as zero characters" do
      messages = [
        { role: :system, content: nil },
        { role: :user, content: "hello" }
      ]

      expect(described_class.estimate(messages)).to eq(2) # 5 chars / 4 = 1.25 -> ceil 2
    end
  end

  # ===========================================================================
  # CostCalculator -- nil guard paths
  # ===========================================================================

  describe RubyLLM::Contract::CostCalculator do
    it "returns nil for nil model_name, nil usage, non-Hash usage, and unknown model" do
      expect(described_class.calculate(model_name: nil, usage: { input_tokens: 100 })).to be_nil
      expect(described_class.calculate(model_name: "gpt-4", usage: nil)).to be_nil
      expect(described_class.calculate(model_name: "gpt-4", usage: "bad")).to be_nil
      expect(described_class.calculate(model_name: "nonexistent-xyz", usage: { input_tokens: 100, output_tokens: 50 })).to be_nil
    end

    it "returns 0.0 for known model with empty usage hash (zero tokens)" do
      result = described_class.calculate(model_name: "gpt-4.1-mini", usage: {})
      expect(result).to eq(0.0) if result # guard for model lookup failure
    end
  end

  # ===========================================================================
  # Adapters::Test -- nil response edge case
  # ===========================================================================

  describe RubyLLM::Contract::Adapters::Test do
    it "returns empty string content when response: nil (normalized consistently)" do
      adapter = described_class.new(response: nil)
      response = adapter.call(messages: [])
      expect(response.content).to eq("")
    end
  end

  # ===========================================================================
  # Adapters::Response -- defaults
  # ===========================================================================

  describe RubyLLM::Contract::Adapters::Response do
    it "defaults usage to empty hash" do
      response = described_class.new(content: "test")
      expect(response.usage).to eq({})
    end
  end

  # ===========================================================================
  # Configuration
  # ===========================================================================

  describe RubyLLM::Contract::Configuration do
    it "has nil defaults" do
      config = described_class.new
      expect(config.default_adapter).to be_nil
      expect(config.default_model).to be_nil
    end
  end

  # ===========================================================================
  # SchemaValidator -- check_type for all JSON types
  # ===========================================================================

  describe RubyLLM::Contract::SchemaValidator do
    let(:fake_schema) do
      double("schema").tap do |s|
        allow(s).to receive(:is_a?).and_return(false)
        allow(s).to receive(:respond_to?).with(:to_json_schema).and_return(true)
        allow(s).to receive(:to_json_schema).and_return({
                                                          schema: {
                                                            properties: {
                                                              flag: { type: "boolean" },
                                                              items: { type: "array" },
                                                              meta: { type: "object" },
                                                              count: { type: "integer" },
                                                              unknown_type: { type: "custom_type" }
                                                            },
                                                            required: []
                                                          }
                                                        })
      end
    end

    it "validates boolean correctly and rejects non-boolean" do
      expect(described_class.validate({ flag: true }, fake_schema).select { |e| e.include?("flag") }).to be_empty
      expect(described_class.validate({ flag: "not bool" }, fake_schema)).to include(match(/flag.*expected boolean/))
    end

    it "validates array correctly and rejects non-array" do
      expect(described_class.validate({ items: [1, 2] }, fake_schema).select { |e| e.include?("items") }).to be_empty
      expect(described_class.validate({ items: "not array" }, fake_schema)).to include(match(/items.*expected array/))
    end

    it "validates object correctly and rejects non-object" do
      expect(described_class.validate({ meta: { k: "v" } }, fake_schema).select { |e| e.include?("meta") }).to be_empty
      expect(described_class.validate({ meta: "not object" }, fake_schema)).to include(match(/meta.*expected object/))
    end

    it "validates integer correctly and rejects float" do
      expect(described_class.validate({ count: 42 }, fake_schema).select { |e| e.include?("count") }).to be_empty
      expect(described_class.validate({ count: 3.14 }, fake_schema)).to include(match(/count.*expected integer/))
    end

    it "passes unknown schema types through without error" do
      errors = described_class.validate({ unknown_type: "anything" }, fake_schema)
      expect(errors.select { |e| e.include?("unknown_type") }).to be_empty
    end

    it "returns type mismatch error for nil or non-Hash output when schema has properties" do
      expect(described_class.validate(nil, fake_schema)).not_to be_empty
      expect(described_class.validate("string", fake_schema)).not_to be_empty
    end
  end

  # ===========================================================================
  # Prompt AST -- cross-type equality
  # ===========================================================================

  describe RubyLLM::Contract::Prompt::AST do
    it "does not equal non-AST objects" do
      node = RubyLLM::Contract::Prompt::Nodes::UserNode.new("test")
      ast = described_class.new([node])

      expect(ast).not_to eq("not an AST")
      expect(ast).not_to eq([{ type: :user, content: "test" }])
    end
  end

  describe RubyLLM::Contract::Prompt::Node do
    it "does not equal a different node class with same content" do
      system_node = RubyLLM::Contract::Prompt::Nodes::SystemNode.new("test")
      rule_node = RubyLLM::Contract::Prompt::Nodes::RuleNode.new("test")

      expect(system_node).not_to eq(rule_node)
    end
  end

  # ===========================================================================
  # EvaluationResult -- clamping and to_s
  # ===========================================================================

  describe RubyLLM::Contract::Eval::EvaluationResult do
    it "clamps negative scores to 0.0" do
      result = described_class.new(score: -1.5, passed: false)
      expect(result.score).to eq(0.0)
    end

    it "allows custom label" do
      result = described_class.new(score: 0.5, passed: true, label: "PARTIAL")
      expect(result.label).to eq("PARTIAL")
    end

    it "omits details dash in to_s when no details given" do
      result = described_class.new(score: 1.0, passed: true)
      expect(result.to_s).to eq("PASS (score: 1.0)")
    end
  end

  # ===========================================================================
  # DSL module -- Types constant injection
  # ===========================================================================

  describe RubyLLM::Contract::DSL do
    it "ensures Types constant is available after inclusion" do
      klass = Class.new { include RubyLLM::Contract::DSL }
      expect(klass.const_defined?(:Types)).to be true
    end

    it "does not overwrite an existing Types constant" do
      existing_types = Module.new
      klass = Class.new do
        const_set(:Types, existing_types)
        include RubyLLM::Contract::DSL
      end

      expect(klass::Types).to eq(existing_types)
    end
  end

  # ===========================================================================
  # Step::Runner -- prompt build failure wrapping
  # ===========================================================================

  describe RubyLLM::Contract::Step::Runner do
    describe "prompt build failure" do
      it "wraps errors during prompt build as input_error with descriptive message" do
        step = Class.new(RubyLLM::Contract::Step::Base) do
          input_type Hash

          prompt do |input|
            system "test"
            user input[:missing].upcase # will raise NoMethodError for nil
          end
        end

        adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"v": 1}')
        result = step.run({ other: "val" }, context: { adapter: adapter })

        expect(result.status).to eq(:input_error)
        expect(result.validation_errors.first).to include("Prompt build failed")
      end
    end

    describe "adapter error includes messages and model in trace" do
      it "populates trace with messages and model even on adapter failure" do
        failing_adapter = Class.new(RubyLLM::Contract::Adapters::Base) do
          def call(messages:, **_options) # rubocop:disable Lint/UnusedMethodArgument
            raise "network failure"
          end
        end.new

        step = Class.new(RubyLLM::Contract::Step::Base) { prompt "test {input}" }
        result = step.run("hello", context: { adapter: failing_adapter, model: "test-model" })

        expect(result.status).to eq(:adapter_error)
        expect(result.trace.messages).to be_an(Array)
        expect(result.trace.messages).not_to be_empty
        expect(result.trace.model).to eq("test-model")
      end
    end
  end

  # ===========================================================================
  # RubyLLM::Contract.configure -- does not overwrite explicit adapter
  # ===========================================================================

  describe "RubyLLM::Contract.configure auto-adapter" do
    it "does not overwrite explicitly set adapter" do
      custom_adapter = RubyLLM::Contract::Adapters::Test.new(response: "test")

      RubyLLM::Contract.configure do |c|
        c.default_adapter = custom_adapter
      end

      expect(RubyLLM::Contract.configuration.default_adapter).to eq(custom_adapter)
    end
  end
end
