# frozen_string_literal: true

require "ruby_llm/contract/rspec"
require "ruby_llm/contract/minitest"
require "ruby_llm/contract/rake_task"
require "tmpdir"

# Step classes for testing
class AuditStepA < RubyLLM::Contract::Step::Base
  prompt { user "{input}" }
  output_type RubyLLM::Contract::Types::Hash
  contract { parse :json }
end

class AuditStepB < RubyLLM::Contract::Step::Base
  prompt { user "{input}" }
  output_type RubyLLM::Contract::Types::Hash
  contract { parse :json }
end

RSpec.describe "Audit bugfixes" do
  before do
    RubyLLM::Contract.reset_configuration!
    RubyLLM::Contract.step_adapter_overrides.clear
    RubyLLM::Contract::CostCalculator.reset_custom_models!
  end

  # -----------------------------------------------------------------------
  # Bug 1: RakeTask abort before save_all_history!
  # -----------------------------------------------------------------------
  describe "Bug 1: RakeTask saves history before aborting on failure" do
    it "saves history even when gate fails" do
      Dir.mktmpdir do |dir|
        Dir.chdir(dir) do
          step = Class.new(RubyLLM::Contract::Step::Base) do
            prompt { user "{input}" }
          end

          adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"priority":"low"}')
          step.define_eval("failing") do
            add_case "wrong", input: "test", expected: { priority: "high" }
          end

          task_name = :"audit_history_#{rand(1000)}"
          task = RubyLLM::Contract::RakeTask.new(task_name) do |t|
            t.context = { adapter: adapter }
            t.track_history = true
            t.minimum_score = 1.0 # will fail — score is 0
          end

          # Task should abort but history should be saved
          expect {
            Rake::Task[task_name].invoke
          }.to raise_error(SystemExit)

          history_files = Dir[File.join(dir, ".eval_history", "*.jsonl")]
          expect(history_files).not_to be_empty
        end
      end
    end
  end

  # -----------------------------------------------------------------------
  # Bug 2: RSpec stub_step block form actually scopes
  # -----------------------------------------------------------------------
  describe "Bug 2: RSpec stub_step block form truly scopes" do
    it "stub is not active after block returns" do
      fallback = RubyLLM::Contract::Adapters::Test.new(response: '{"from":"fallback"}')
      RubyLLM::Contract.configuration.default_adapter = fallback

      stub_step(AuditStepA, response: '{"from":"stubbed"}') do
        result = AuditStepA.run("x")
        expect(result.parsed_output).to eq({ from: "stubbed" })
      end

      # After block: should use fallback, not "stubbed"
      result = AuditStepA.run("x")
      expect(result.parsed_output).to eq({ from: "fallback" })
    end

    it "stub_steps cleanup works after block" do
      fallback = RubyLLM::Contract::Adapters::Test.new(response: '{"from":"fallback"}')
      RubyLLM::Contract.configuration.default_adapter = fallback

      stub_steps(
        AuditStepA => { response: '{"from":"a"}' },
        AuditStepB => { response: '{"from":"b"}' }
      ) do
        expect(AuditStepA.run("x").parsed_output).to eq({ from: "a" })
        expect(AuditStepB.run("x").parsed_output).to eq({ from: "b" })
      end

      # After block: both should use fallback
      expect(AuditStepA.run("x").parsed_output).to eq({ from: "fallback" })
      expect(AuditStepB.run("x").parsed_output).to eq({ from: "fallback" })
    end
  end

  # -----------------------------------------------------------------------
  # Bug 3: StepAdapterOverride handles nil context and string keys
  # -----------------------------------------------------------------------
  describe "Bug 3: StepAdapterOverride edge cases" do
    include RubyLLM::Contract::MinitestHelpers

    it "handles context: nil without NoMethodError" do
      fallback = RubyLLM::Contract::Adapters::Test.new(response: '{"ok":true}')
      RubyLLM::Contract.configuration.default_adapter = fallback

      # This should not raise NoMethodError
      result = AuditStepA.run("x", context: nil)
      expect(result.ok?).to be true
    end

    it "respects string key 'adapter' in context" do
      custom_adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"from":"custom"}')
      override_adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"from":"override"}')

      stub_step(AuditStepA, response: '{"from":"override"}')

      # String key "adapter" should be respected, not overwritten by thread-local
      result = AuditStepA.run("x", context: { "adapter" => custom_adapter })
      expect(result.parsed_output).to eq({ from: "custom" })
    end
  end

  # -----------------------------------------------------------------------
  # Bug 4: CostCalculator rejects negative prices
  # -----------------------------------------------------------------------
  describe "Bug 4: CostCalculator.register_model rejects negative prices" do
    it "rejects negative input_per_1m" do
      expect {
        RubyLLM::Contract::CostCalculator.register_model("ft:neg",
          input_per_1m: -1.0, output_per_1m: 1.0)
      }.to raise_error(ArgumentError, /input_per_1m must be non-negative/)
    end

    it "rejects negative output_per_1m" do
      expect {
        RubyLLM::Contract::CostCalculator.register_model("ft:neg",
          input_per_1m: 1.0, output_per_1m: -1.0)
      }.to raise_error(ArgumentError, /output_per_1m must be non-negative/)
    end

    it "accepts zero prices" do
      expect {
        RubyLLM::Contract::CostCalculator.register_model("ft:free",
          input_per_1m: 0.0, output_per_1m: 0.0)
      }.not_to raise_error
    end
  end

  # -----------------------------------------------------------------------
  # Bug 5: non-block stub_step overwrites explicit context[:adapter]
  # -----------------------------------------------------------------------
  describe "Bug 5: non-block stub_step respects explicit adapter in context" do
    it "uses caller's adapter when context[:adapter] is set" do
      stub_step(AuditStepA, response: '{"from":"stubbed"}')

      custom_adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"from":"custom"}')
      result = AuditStepA.run("x", context: { adapter: custom_adapter })
      expect(result.parsed_output).to eq({ from: "custom" })
    end

    it "uses caller's adapter when context has string key" do
      stub_step(AuditStepA, response: '{"from":"stubbed"}')

      custom_adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"from":"custom"}')
      result = AuditStepA.run("x", context: { "adapter" => custom_adapter })
      expect(result.parsed_output).to eq({ from: "custom" })
    end
  end

  # -----------------------------------------------------------------------
  # Bug 6: save_all_history! respects string key "model"
  # -----------------------------------------------------------------------
  describe "Bug 6: track_history handles string key model in context" do
    it "includes model in history filename from string key context" do
      Dir.mktmpdir do |dir|
        Dir.chdir(dir) do
          step = Class.new(RubyLLM::Contract::Step::Base) do
            prompt { user "{input}" }
          end

          adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"ok":true}')
          step.define_eval("strkey") do
            add_case "test", input: "hello", expected: { ok: true }
          end

          task_name = :"audit_strkey_#{rand(1000)}"
          RubyLLM::Contract::RakeTask.new(task_name) do |t|
            t.context = { "adapter" => adapter, "model" => "gpt-4o" }
            t.track_history = true
            t.fail_on_empty = false
          end

          Rake::Task[task_name].invoke

          history_files = Dir[File.join(dir, ".eval_history", "*.jsonl")]
          expect(history_files.any? { |f| f.include?("gpt-4o") }).to be true
        end
      end
    end
  end
end
