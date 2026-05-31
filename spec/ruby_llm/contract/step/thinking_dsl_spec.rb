# frozen_string_literal: true

class StepThinkingBase < RubyLLM::Contract::Step::Base
  prompt { user "noop" }
  thinking effort: :low
end

class StepThinkingChild < StepThinkingBase
end

class StepThinkingOverride < StepThinkingBase
  thinking effort: :high
end

class StepThinkingReset < StepThinkingBase
  thinking effort: :default
end

class StepReasoningEffortAlias < RubyLLM::Contract::Step::Base
  prompt { user "noop" }
  reasoning_effort :medium
end

class StepThinkingWithBudget < RubyLLM::Contract::Step::Base
  prompt { user "noop" }
  thinking effort: :low, budget: 1024
end

class StepNoThinking < RubyLLM::Contract::Step::Base
  prompt { user "noop" }
end

RSpec.describe "Step thinking DSL" do
  describe ".thinking" do
    it "stores effort + budget as a hash mirroring Agent.thinking" do
      expect(StepThinkingWithBudget.thinking).to eq(effort: :low, budget: 1024)
    end

    it "stores effort only when budget omitted" do
      expect(StepThinkingBase.thinking).to eq(effort: :low)
    end

    it "returns nil when not configured" do
      expect(StepNoThinking.thinking).to be_nil
    end

    it "inherits from superclass when subclass has not set its own" do
      expect(StepThinkingChild.thinking).to eq(effort: :low)
    end

    it "subclass override replaces inherited value" do
      expect(StepThinkingOverride.thinking).to eq(effort: :high)
    end

    it "subclass partial override is replace, NOT merge (matches temperature/model pattern)" do
      child = Class.new(StepThinkingBase) { thinking budget: 999 }
      # Inherited effort :low from StepThinkingBase is dropped — replace, not merge
      expect(child.thinking).to eq(budget: 999)
    end

    it "supports :default reset semantics like temperature/model" do
      expect(StepThinkingReset.thinking).to be_nil
    end
  end

  describe ".reasoning_effort (alias)" do
    it "is implemented as thinking(effort: value)" do
      expect(StepReasoningEffortAlias.thinking).to eq(effort: :medium)
    end

    it "reader returns effort from current thinking" do
      expect(StepReasoningEffortAlias.reasoning_effort).to eq(:medium)
    end

    it "reader returns nil when no thinking configured" do
      expect(StepNoThinking.reasoning_effort).to be_nil
    end

    it ":default on alias clears effort but PRESERVES budget" do
      cls = Class.new(RubyLLM::Contract::Step::Base) do
        prompt { user "noop" }
        thinking effort: :high, budget: 2048
      end
      cls.reasoning_effort(:default)
      expect(cls.thinking).to eq(budget: 2048)
    end

    it ":default on alias clears entire config when no budget was set" do
      cls = Class.new(RubyLLM::Contract::Step::Base) do
        prompt { user "noop" }
        thinking effort: :high
      end
      cls.reasoning_effort(:default)
      expect(cls.thinking).to be_nil
    end
  end

  describe "runtime_settings integration" do
    it "injects full thinking hash into extra_options when class has thinking set" do
      settings = StepThinkingBase.send(:runtime_settings, {})
      expect(settings[:extra_options][:thinking]).to eq(effort: :low)
    end

    it "also seeds reasoning_effort for backward compat with eval_host paths" do
      settings = StepThinkingBase.send(:runtime_settings, {})
      expect(settings[:extra_options][:reasoning_effort]).to eq(:low)
    end

    it "passes thinking with budget when class has both" do
      settings = StepThinkingWithBudget.send(:runtime_settings, {})
      expect(settings[:extra_options][:thinking]).to eq(effort: :low, budget: 1024)
    end

    it "context :reasoning_effort wins for effort but :thinking still travels (budget preservation)" do
      settings = StepThinkingBase.send(:runtime_settings, { reasoning_effort: :high })
      expect(settings[:extra_options][:reasoning_effort]).to eq(:high)
      # :thinking still passed so the adapter can merge effort override
      # while preserving budget. Effort within :thinking is the class
      # default (:low) — the adapter merges :reasoning_effort over it.
      expect(settings[:extra_options][:thinking]).to eq(effort: :low)
    end

    it "context :reasoning_effort preserves class-level :budget through runtime_settings" do
      settings = StepThinkingWithBudget.send(:runtime_settings, { reasoning_effort: :high })
      expect(settings[:extra_options][:reasoning_effort]).to eq(:high)
      # Critical — without thinking pass-through, the budget would silently disappear
      expect(settings[:extra_options][:thinking]).to eq(effort: :low, budget: 1024)
    end

    it "no extra_options[:reasoning_effort] / :thinking when class has no thinking" do
      settings = StepNoThinking.send(:runtime_settings, {})
      expect(settings[:extra_options]).not_to have_key(:reasoning_effort)
      expect(settings[:extra_options]).not_to have_key(:thinking)
    end
  end

  describe "adapter forwarding" do
    let(:fake_chat_class) do
      Class.new do
        attr_reader :thinking_calls, :params_calls, :messages
        def initialize
          @thinking_calls = []
          @params_calls = []
          @messages = []
        end

        def with_thinking(**kwargs)
          @thinking_calls << kwargs
          self
        end

        def with_params(**kwargs)
          @params_calls << kwargs
          self
        end

        def with_temperature(_); self; end
        def with_schema(_); self; end
        def with_instructions(_); self; end
        def add_message(**); end
        def ask(content, with: nil)
          @messages << content
          @last_attachment = with
          OpenStruct.new(content: '{"ok":true}', input_tokens: 10, output_tokens: 5)
        end
      end
    end

    let(:fake_chat) { fake_chat_class.new }
    let(:adapter) { RubyLLM::Contract::Adapters::RubyLLM.new }
    let(:messages) { [{ role: :user, content: "hi" }] }

    before do
      require "ostruct"
      allow(::RubyLLM).to receive(:chat).and_return(fake_chat)
    end

    it "forwards full thinking hash via with_thinking when set" do
      adapter.call(messages: messages, model: "gpt-5-nano",
                   thinking: { effort: :low, budget: 1024 })
      expect(fake_chat.thinking_calls).to eq([{ effort: :low, budget: 1024 }])
    end

    it "forwards effort-only thinking via with_thinking" do
      adapter.call(messages: messages, model: "gpt-5-nano", thinking: { effort: :low })
      expect(fake_chat.thinking_calls).to eq([{ effort: :low }])
    end

    it "skips reasoning_effort with_params when thinking already covered it" do
      adapter.call(messages: messages, model: "gpt-5-nano",
                   thinking: { effort: :low }, reasoning_effort: :low)
      effort_params = fake_chat.params_calls.flat_map { |c| c.keys }
      expect(effort_params).not_to include(:reasoning_effort)
    end

    it "reasoning_effort-only forwards via with_thinking (no with_params call for it)" do
      adapter.call(messages: messages, model: "gpt-5-nano", reasoning_effort: :high)
      expect(fake_chat.thinking_calls).to eq([{ effort: :high }])
      expect(fake_chat.params_calls.flat_map(&:keys)).not_to include(:reasoning_effort)
    end

    it "per-attempt :reasoning_effort OVERRIDES class-level :thinking effort (Bug #1 regression)" do
      # Repro: class-level `thinking effort: :low` + chain attempt with
      # `reasoning_effort: "high"`. Effort must reflect the attempt override,
      # not the class default.
      adapter.call(messages: messages, model: "gpt-5-nano",
                   thinking: { effort: :low }, reasoning_effort: :high)
      expect(fake_chat.thinking_calls).to eq([{ effort: :high }])
    end

    it "per-attempt :reasoning_effort preserves class-level :budget" do
      adapter.call(messages: messages, model: "gpt-5-nano",
                   thinking: { effort: :low, budget: 1024 }, reasoning_effort: :high)
      expect(fake_chat.thinking_calls).to eq([{ effort: :high, budget: 1024 }])
    end

  end

  # Anti-facade F3 (integration gap): every test above either calls
  # `runtime_settings` in isolation OR drives the adapter directly with
  # hand-built `thinking:` kwargs. None proves end-to-end that
  # `Step.run("input")` -> RunnerConfig.build -> adapter actually carries
  # the class-level `thinking` DSL through to the wire. Mutation
  # smoking-gun: passing `extra_options: {}` into RunnerConfig.build in
  # `Step::Base#run_once` would leave every existing test green while
  # silently dropping the DSL.
  describe "end-to-end Step.run forwards thinking DSL to adapter" do
    let(:received_options) { [] }

    let(:spy_adapter) do
      tracker = received_options
      Class.new(RubyLLM::Contract::Adapters::Base) do
        define_method(:call) do |messages:, **opts|
          tracker << opts
          RubyLLM::Contract::Adapters::Response.new(
            content: '{"v": 1}', usage: { input_tokens: 0, output_tokens: 0 }
          )
        end
      end.new
    end

    it "forwards class-level effort-only thinking through Step.run" do
      step = Class.new(RubyLLM::Contract::Step::Base) do
        prompt { user "{input}" }
        thinking effort: :high
      end

      step.run("hello", context: { adapter: spy_adapter })

      expect(received_options.length).to eq(1)
      forwarded = received_options.first
      expect(forwarded[:thinking]).to eq(effort: :high)
      expect(forwarded[:reasoning_effort]).to eq(:high)
    end

    it "forwards class-level thinking with budget through Step.run" do
      step = Class.new(RubyLLM::Contract::Step::Base) do
        prompt { user "{input}" }
        thinking effort: :low, budget: 2048
      end

      step.run("hello", context: { adapter: spy_adapter })

      forwarded = received_options.first
      expect(forwarded[:thinking]).to eq(effort: :low, budget: 2048)
    end

    it "does NOT forward thinking when class has no DSL setting" do
      step = Class.new(RubyLLM::Contract::Step::Base) do
        prompt { user "{input}" }
      end

      step.run("hello", context: { adapter: spy_adapter })

      forwarded = received_options.first
      expect(forwarded).not_to have_key(:thinking)
      expect(forwarded).not_to have_key(:reasoning_effort)
    end
  end
end
