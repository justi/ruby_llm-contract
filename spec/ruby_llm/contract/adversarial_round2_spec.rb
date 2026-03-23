# frozen_string_literal: true

# Adversarial QA round 2 -- regression tests for newly discovered bugs.
# Round 1 found 6 bugs; these are NEW bugs that round 1 missed.
# Each describe block covers a specific bug, its fix, and regression guard.

RSpec.describe "Adversarial QA round 2 -- bug regressions" do
  before { RubyLLM::Contract.reset_configuration! }

  # ---------------------------------------------------------------------------
  # BUG 9: Non-string content in prompt nodes causes NoMethodError in renderer.
  #
  # user(42) creates a UserNode with Integer content. The renderer's
  # `interpolate` method calls `.gsub` on it, which raises NoMethodError
  # because Integer has no #gsub.
  #
  # The error is misleadingly reported as :input_error even though the
  # problem is in the prompt definition, not the input.
  #
  # Fix: Renderer#interpolate calls .to_s on non-nil, non-Hash, non-Array
  # content before calling gsub. This mirrors the behavior already present
  # for Hash/Array content (which gets .to_json).
  # ---------------------------------------------------------------------------
  describe "BUG 9: Non-string content in prompt nodes" do
    it "renders Integer content via user() without crashing" do
      step = Class.new(RubyLLM::Contract::Step::Base) do
        prompt { user 42 }
      end

      adapter = RubyLLM::Contract::Adapters::Test.new(response: "ok")
      result = step.run("test", context: { adapter: adapter })

      # Should NOT be :input_error from NoMethodError
      expect(result.status).not_to eq(:input_error),
                                   "user(42) should not cause input_error -- the prompt should render the integer as '42'"
      expect(result.trace.messages.first[:content]).to eq("42")
    end

    it "renders Symbol content via system() without crashing" do
      step = Class.new(RubyLLM::Contract::Step::Base) do
        prompt do
          system :be_helpful
          user "{input}"
        end
      end

      adapter = RubyLLM::Contract::Adapters::Test.new(response: "ok")
      result = step.run("test", context: { adapter: adapter })

      expect(result.status).not_to eq(:input_error),
                                   "system(:be_helpful) should not crash -- the symbol should be rendered as 'be_helpful'"
      system_msg = result.trace.messages.find { |m| m[:role] == :system }
      expect(system_msg[:content]).to eq("be_helpful")
    end

    it "renders Integer content in dynamic prompt without crashing" do
      step = Class.new(RubyLLM::Contract::Step::Base) do
        input_type Hash
        prompt { |input| user input[:count] }
      end

      adapter = RubyLLM::Contract::Adapters::Test.new(response: "ok")
      result = step.run({ count: 42 }, context: { adapter: adapter })

      expect(result.status).not_to eq(:input_error),
                                   "dynamic prompt passing integer to user() should not crash"
      expect(result.trace.messages.first[:content]).to eq("42")
    end
  end

  # ---------------------------------------------------------------------------
  # BUG 10: Section names are subject to {variable} interpolation.
  #
  # The renderer passes the entire "[section_name]\ncontent" string through
  # interpolate(). If the section name contains {input} or any {var} pattern,
  # those get replaced with variable values. Section names should be literal.
  #
  # Fix: Interpolate section content separately from section name. The name
  # is always rendered literally; only the content body is interpolated.
  # ---------------------------------------------------------------------------
  describe "BUG 10: Section name interpolation injection" do
    it "does NOT interpolate {variables} inside section names" do
      ast = RubyLLM::Contract::Prompt::Builder.build do
        section "{input}", "the content"
      end

      messages = RubyLLM::Contract::Prompt::Renderer.render(ast, variables: { input: "INJECTED" })
      content = messages.first[:content]

      # The section name should be literal "{input}", not "INJECTED"
      expect(content).to start_with("[{input}]"),
                         "Section name should be literal, not interpolated. Got: #{content.inspect}"
      expect(content).not_to include("INJECTED")
    end

    it "still interpolates variables in section body content" do
      ast = RubyLLM::Contract::Prompt::Builder.build do
        section "context", "User said: {input}"
      end

      messages = RubyLLM::Contract::Prompt::Renderer.render(ast, variables: { input: "hello" })
      content = messages.first[:content]

      expect(content).to include("[context]")
      expect(content).to include("User said: hello")
    end
  end

  # ---------------------------------------------------------------------------
  # BUG 11: Section names containing newlines or "]" break section format.
  #
  # The renderer formats sections as "[name]\ncontent". If name contains
  # "]\n[INJECTED", the output becomes "[legit]\n[INJECTED]\ncontent",
  # appearing as two separate sections.
  #
  # Fix: Strip/replace newlines and brackets in section names to prevent
  # format corruption.
  # ---------------------------------------------------------------------------
  describe "BUG 11: Section name newline/bracket injection" do
    it "sanitizes newlines from section names" do
      ast = RubyLLM::Contract::Prompt::Builder.build do
        section "legit]\n[INJECTED", "content"
      end

      messages = RubyLLM::Contract::Prompt::Renderer.render(ast, variables: {})
      content = messages.first[:content]

      # Should NOT produce a second bracketed section header
      occurrences = content.scan(/^\[/).length
      expect(occurrences).to eq(1),
                             "Section name injection should be prevented. Got multi-section output: #{content.inspect}"
    end

    it "sanitizes bracket-close from section names" do
      ast = RubyLLM::Contract::Prompt::Builder.build do
        section "name]evil", "content"
      end

      messages = RubyLLM::Contract::Prompt::Renderer.render(ast, variables: {})
      content = messages.first[:content]

      # The section header should be on one line without a premature close bracket
      header_line = content.lines.first.strip
      expect(header_line).to match(/^\[.*\]$/),
                             "Section header should be a single well-formed [name] bracket"
      expect(header_line.scan("]").length).to eq(1),
                                              "Section header should have exactly one closing bracket"
    end
  end

  # ---------------------------------------------------------------------------
  # BUG 13: Pipeline timeout_ms: 0 or negative causes immediate timeout.
  #
  # Pipeline::Runner does not validate timeout_ms. A value of 0 means
  # "elapsed_ms >= 0" is always true after the first step, causing immediate
  # timeout even though the step succeeded. Negative values have the same
  # effect.
  #
  # Fix: Pipeline::Runner raises ArgumentError for non-positive timeout_ms.
  # ---------------------------------------------------------------------------
  describe "BUG 13: Pipeline timeout_ms validation" do
    let(:step_class) do
      Class.new(RubyLLM::Contract::Step::Base) do
        prompt { user "{input}" }
        output_type RubyLLM::Contract::Types::Hash
        contract { parse :json }
      end
    end

    let(:pipeline) do
      sc = step_class
      Class.new(RubyLLM::Contract::Pipeline::Base) do
        step sc, as: :step_a
      end
    end

    it "raises ArgumentError for timeout_ms: 0" do
      expect do
        pipeline.test("hello", responses: { step_a: { data: "ok" } }, timeout_ms: 0)
      end.to raise_error(ArgumentError, /timeout_ms must be positive/)
    end

    it "raises ArgumentError for negative timeout_ms" do
      expect do
        pipeline.test("hello", responses: { step_a: { data: "ok" } }, timeout_ms: -100)
      end.to raise_error(ArgumentError, /timeout_ms must be positive/)
    end

    it "works normally with positive timeout_ms" do
      result = pipeline.test("hello", responses: { step_a: { data: "ok" } }, timeout_ms: 60_000)
      expect(result.status).to eq(:ok)
    end
  end

  # ---------------------------------------------------------------------------
  # BUG 14: define_eval silently overwrites existing eval definitions.
  #
  # Calling define_eval(:smoke) twice on the same step warns and replaces.
  # Reload path suppresses the warning via Thread-local flag.
  # ---------------------------------------------------------------------------
  describe "BUG 14: define_eval with duplicate name warns and replaces" do
    it "warns on duplicate name outside reload" do
      step = Class.new(RubyLLM::Contract::Step::Base) do
        prompt { user "{input}" }
      end

      step.define_eval(:smoke) do
        default_input "test1"
        sample_response({ v: "first" })
      end

      expect(step).to receive(:warn).with(/Redefining eval 'smoke'/i)

      step.define_eval(:smoke) do
        default_input "test2"
        sample_response({ v: "second" })
      end

      expect(step.eval_names).to eq(["smoke"])
    end

    it "allows different eval names on the same step" do
      step = Class.new(RubyLLM::Contract::Step::Base) do
        prompt { user "{input}" }

        define_eval :smoke do
          default_input "test1"
          sample_response "first"
        end

        define_eval :regression do
          default_input "test2"
          sample_response "second"
        end
      end

      defs = step.instance_variable_get(:@eval_definitions)
      expect(defs.keys).to contain_exactly("smoke", "regression")
    end
  end
end
