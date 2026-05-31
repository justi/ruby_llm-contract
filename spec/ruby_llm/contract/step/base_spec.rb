# frozen_string_literal: true

class TestClassifyIntent < RubyLLM::Contract::Step::Base
  input_type  RubyLLM::Contract::Types::String
  output_type RubyLLM::Contract::Types::Hash

  prompt do
    system "Classify the user's intent."
    rule   "Return JSON only."
    rule   "Allowed intents: sales, support, billing."
    user   "{input}"
  end

  contract do
    parse :json
    invariant("must include intent") { |output| output[:intent].to_s != "" }
    invariant("intent must be allowed") { |output| %w[sales support billing].include?(output[:intent]) }
  end
end

RSpec.describe RubyLLM::Contract::Step::Base do
  before { RubyLLM::Contract.reset_configuration! }

  describe "class macros" do
    it "has input_type accessor" do
      expect(TestClassifyIntent.input_type).to eq(RubyLLM::Contract::Types::String)
    end

    it "has output_type accessor" do
      expect(TestClassifyIntent.output_type).to eq(RubyLLM::Contract::Types::Hash)
    end

    it "prompt block renders the configured system instructions and rules" do
      # Previously asserted only `be_a(Proc)` — a mutation that replaced the
      # prompt block with `-> {}` (empty Proc) would have passed. Now the
      # block is exercised end-to-end through `build_messages` so the
      # assertion catches both: (a) prompt not being a Proc, and (b) the
      # Proc being empty / not capturing the DSL contents.
      messages = TestClassifyIntent.build_messages("hello")
      system_contents = messages.select { |m| m[:role] == :system }.map { |m| m[:content] }

      expect(system_contents).to include(a_string_including("Classify the user's intent."))
      expect(system_contents).to include(a_string_including("Allowed intents: sales, support, billing."))
    end

    it "contract accessor exposes the declared invariants" do
      # Previously asserted only `be_a(Definition)` — a mutation that
      # replaced the macro with `Definition.new` (empty) would have passed.
      # Now we pin the two invariants the test class actually declared.
      definition = TestClassifyIntent.contract

      expect(definition.invariants.map(&:description)).to eq(
        ["must include intent", "intent must be allowed"]
      )
    end
  end

  describe ".run" do
    context "with valid input and valid adapter response" do
      it "returns :ok with parsed output" do
        adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"intent":"sales"}')
        result = TestClassifyIntent.run("I need help with sales", context: { adapter: adapter })

        expect(result.status).to eq(:ok)
        expect(result.ok?).to be true
        expect(result.parsed_output).to eq({ intent: "sales" })
      end
    end

    context "with invalid input" do
      it "returns :input_error" do
        adapter = RubyLLM::Contract::Adapters::Test.new(response: "unused")
        result = TestClassifyIntent.run(123, context: { adapter: adapter })

        expect(result.status).to eq(:input_error)
        expect(result.failed?).to be true
        expect(result.validation_errors).not_to be_empty
      end
    end

    context "with adapter returning JSON that fails invariant" do
      it "returns :validation_failed" do
        adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"intent":"unknown"}')
        result = TestClassifyIntent.run("help me", context: { adapter: adapter })

        expect(result.status).to eq(:validation_failed)
        expect(result.validation_errors).to include("intent must be allowed")
        expect(result.raw_output).to eq('{"intent":"unknown"}')
        expect(result.parsed_output).to eq({ intent: "unknown" })
      end
    end

    context "with adapter returning malformed JSON" do
      it "returns :parse_error" do
        adapter = RubyLLM::Contract::Adapters::Test.new(response: "not json")
        result = TestClassifyIntent.run("help me", context: { adapter: adapter })

        expect(result.status).to eq(:parse_error)
        expect(result.raw_output).to eq("not json")
      end
    end

    context "adapter resolution" do
      it "uses global default adapter when no context adapter" do
        adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"intent":"billing"}')
        RubyLLM::Contract.configure { |c| c.default_adapter = adapter }

        result = TestClassifyIntent.run("I need help with my invoice")

        expect(result.status).to eq(:ok)
        expect(result.parsed_output).to eq({ intent: "billing" })
      end

      it "uses context adapter over global default" do
        global_adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"intent":"sales"}')
        context_adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"intent":"billing"}')
        RubyLLM::Contract.configure { |c| c.default_adapter = global_adapter }

        result = TestClassifyIntent.run("help", context: { adapter: context_adapter })

        expect(result.parsed_output).to eq({ intent: "billing" })
      end

      it "raises RubyLLM::Contract::Error when no adapter is configured" do
        expect do
          TestClassifyIntent.run("help")
        end.to raise_error(RubyLLM::Contract::Error, /No adapter configured/)
      end
    end

    context "with model in context" do
      it "passes model to trace" do
        adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"intent":"sales"}')
        result = TestClassifyIntent.run("help", context: { adapter: adapter, model: "gpt-4.1-mini" })

        expect(result.trace[:model]).to eq("gpt-4.1-mini")
      end
    end
  end

  describe "2-arity validate (receives input)" do
    it "passes input to the validate block alongside output" do
      step = Class.new(RubyLLM::Contract::Step::Base) do
        input_type String
        prompt "Translate: {input}"
        validate("output language matches requested") do |output, input|
          output[:requested] == input
        end
      end

      adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"requested": "hello"}')
      result = step.run("hello", context: { adapter: adapter })
      expect(result.status).to eq(:ok)
    end

    it "fails when 2-arity validate returns false" do
      step = Class.new(RubyLLM::Contract::Step::Base) do
        input_type String
        prompt "Process: {input}"
        validate("output echoes input") do |output, input|
          output[:echo] == input
        end
      end

      adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"echo": "wrong"}')
      result = step.run("expected", context: { adapter: adapter })
      expect(result.status).to eq(:validation_failed)
      expect(result.validation_errors).to include("output echoes input")
    end
  end

  describe ".define_eval duplicate name" do
    it "warns and replaces when defining an eval with a duplicate name" do
      step = Class.new(RubyLLM::Contract::Step::Base) do
        prompt "test {input}"
      end

      step.define_eval("smoke") do
        default_input "test"
      end

      # The `warn` here is a side-effect channel, not a SUT internal — A3
      # (stub-receipt) brittleness, paired with the unconditional
      # `eval_names == ["smoke"]` behavioural check below that proves dedup
      # actually replaced rather than appended. The pair turns A3 into a
      # legitimate diagnostic surface: a mutation that drops the warn AND
      # the dedup would fail the behavioural check.
      expect(step).to receive(:warn).with(/Redefining eval 'smoke'/i)

      step.define_eval("smoke") do
        default_input "test again"
      end

      expect(step.eval_names).to eq(["smoke"])
    end
  end

  describe "reasoning_effort forwarding" do
    it "passes reasoning_effort from context through to adapter" do
      step = Class.new(described_class) { prompt "test {input}" }
      adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"v": 1}')

      allow(adapter).to receive(:call).and_call_original

      step.run("hello", context: { adapter: adapter, reasoning_effort: "low" })

      expect(adapter).to have_received(:call).with(
        hash_including(messages: anything, reasoning_effort: "low")
      )
    end
  end

  describe ".recommend" do
    # The two scenarios split because `recommend`'s output branches on
    # whether pricing is known — keeping them as one `if rec.best ... else`
    # test silently skipped half the assertions on any given run (A7).
    # Now each path is deterministically forced and unconditionally asserted.

    let(:recommend_step) do
      Class.new(described_class) do
        input_type String
        output_type Hash
        prompt { user "{input}" }
        validate("has intent") { |o| !o[:intent].to_s.empty? }

        define_eval("smoke") do
          default_input "test query"
          verify "has intent", { intent: /billing/ }
        end
      end
    end

    let(:recommend_adapter) do
      RubyLLM::Contract::Adapters::Test.new(
        response: '{"intent": "billing", "confidence": 0.9}',
        usage: { input_tokens: 100, output_tokens: 50 }
      )
    end

    it "returns a Recommendation with rationale for each candidate" do
      rec = recommend_step.recommend(
        "smoke",
        candidates: [{ model: "gpt-4.1-nano" }, { model: "gpt-4.1-mini" }],
        min_score: 0.5,
        context: { adapter: recommend_adapter }
      )

      expect(rec).to be_a(RubyLLM::Contract::Eval::Recommendation)
      expect(rec).to be_frozen
      expect(rec.score).to eq(1.0)
      expect(rec.rationale.length).to eq(2)
    end

    it "emits an unknown-pricing warning when candidate models have no registered pricing" do
      # Unknown-pricing path: candidate model names must NOT be in
      # CostCalculator's registry (RubyLLM ships pricing for `gpt-4.1-*`,
      # so those would resolve and break the assertion). Made-up names
      # guarantee `find_model` returns nil → `best` is nil and `warnings`
      # carries the diagnosis. Pinned deterministically.
      rec = recommend_step.recommend(
        "smoke",
        candidates: [{ model: "totally-fake-model-AAA" }, { model: "totally-fake-model-BBB" }],
        min_score: 0.5,
        context: { adapter: recommend_adapter }
      )

      expect(rec.best).to be_nil
      expect(rec.warnings).to include(match(/unknown pricing/i))
    end

    it "selects a best candidate when pricing is registered for all candidates" do
      # Known-pricing path: register custom pricing for both candidates so
      # `best` resolves to a non-nil winner with a retry_chain and DSL
      # output. Tears down custom registry afterwards.
      RubyLLM::Contract::CostCalculator.register_model("test-cheap",  input_per_1m: 0.10, output_per_1m: 0.40)
      RubyLLM::Contract::CostCalculator.register_model("test-pricey", input_per_1m: 1.00, output_per_1m: 4.00)

      rec = recommend_step.recommend(
        "smoke",
        candidates: [{ model: "test-cheap" }, { model: "test-pricey" }],
        min_score: 0.5,
        context: { adapter: recommend_adapter }
      )

      expect(rec.best).to be_a(Hash)
      expect(rec.best).to have_key(:model)
      expect(rec.retry_chain).not_to be_empty
      # `to_dsl` emits `model "X"` when retry_chain collapses to a single
      # winner, or `retry_policy do escalate(...) end` when it chains.
      # Either way the chosen model name must appear — that's the
      # content contract.
      expect(rec.to_dsl).to include(rec.best[:model])
    ensure
      RubyLLM::Contract::CostCalculator.reset_custom_models!
    end
  end

  describe ".current_model_config" do
    it "returns first config from retry_policy when present" do
      step = Class.new(described_class) do
        prompt "test {input}"
        retry_policy do
          escalate({ model: "gpt-4.1-nano" }, { model: "gpt-4.1-mini", reasoning_effort: "high" })
        end
      end

      config = step.send(:current_model_config)
      expect(config).to eq({ model: "gpt-4.1-nano" })
    end

    it "returns model hash when no retry_policy" do
      step = Class.new(described_class) do
        prompt "test {input}"
        model "gpt-4.1-mini"
      end

      config = step.send(:current_model_config)
      expect(config).to eq({ model: "gpt-4.1-mini" })
    end

    it "returns default_model hash when no model set" do
      RubyLLM::Contract.configure { |c| c.default_model = "gpt-5-mini" }

      step = Class.new(described_class) do
        prompt "test {input}"
      end

      config = step.send(:current_model_config)
      expect(config).to eq({ model: "gpt-5-mini" })
    end
  end
end
