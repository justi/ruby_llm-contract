# frozen_string_literal: true

require "tmpdir"
require "ruby_llm/contract/rspec"
require "ruby_llm/contract/rake_task"

RSpec.describe "F3: EvalHistory auto-append in RakeTask (ADR-0016)" do
  before do
    RubyLLM::Contract.reset_configuration!
    RubyLLM::Contract.reset_eval_hosts!
  end

  def build_report(name, cases, step_name: nil)
    results = cases.map do |c|
      RubyLLM::Contract::Eval::CaseResult.new(
        name: c[:name], input: "test", output: c[:output] || {},
        expected: c[:expected] || {}, step_status: :ok,
        score: c[:passed] ? 1.0 : 0.0, passed: c[:passed],
        details: c[:details], cost: c[:cost] || 0.001
      )
    end
    RubyLLM::Contract::Eval::Report.new(
      dataset_name: name, results: results, step_name: step_name
    )
  end

  # ===========================================================================
  # Attribute defaults
  # ===========================================================================

  describe "track_history attribute" do
    it "defaults to false" do
      task = RubyLLM::Contract::RakeTask.new(:"test_history_default_#{rand(10_000)}")
      expect(task.track_history).to be false
    end

    it "can be set to true" do
      task = RubyLLM::Contract::RakeTask.new(:"test_history_set_#{rand(10_000)}") do |t|
        t.track_history = true
      end
      expect(task.track_history).to be true
    end
  end

  # ===========================================================================
  # Integration: history files created when track_history is true
  # ===========================================================================

  describe "history saving during task execution" do
    let(:step) do
      Class.new(RubyLLM::Contract::Step::Base) do
        input_type String
        output_type Hash
        prompt { user "Classify: {input}" }
        validate("has priority") { |o| %w[urgent high medium low].include?(o[:priority]) }
      end
    end

    it "saves history for all reports when track_history is true" do
      step.define_eval("smoke") do
        add_case "billing", input: "charged twice", expected: { priority: "high" }
      end

      adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"priority": "high"}')

      Dir.mktmpdir do |dir|
        Dir.chdir(dir) do
          task = RubyLLM::Contract::RakeTask.new(:"test_history_save_#{rand(10_000)}") do |t|
            t.context = { adapter: adapter }
            t.track_history = true
          end

          Rake::Task[task.name].invoke

          history_files = Dir.glob(File.join(dir, ".eval_history", "**", "*.jsonl"))
          expect(history_files).not_to be_empty

          content = File.read(history_files.first)
          run_data = JSON.parse(content.strip, symbolize_names: true)
          expect(run_data[:score]).to eq(1.0)
          expect(run_data[:pass_rate]).to eq("1/1")
        end
      end
    end

    it "saves both passed and failed reports" do
      step.define_eval("mixed") do
        add_case "good", input: "billing issue", expected: { priority: "high" }
        add_case "bad", input: "unknown", expected: { priority: "urgent" }
      end

      adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"priority": "high"}')

      Dir.mktmpdir do |dir|
        Dir.chdir(dir) do
          task = RubyLLM::Contract::RakeTask.new(:"test_history_mixed_#{rand(10_000)}") do |t|
            t.context = { adapter: adapter }
            t.track_history = true
            t.minimum_score = 0.0 # allow failures through the gate
          end

          Rake::Task[task.name].invoke

          history_files = Dir.glob(File.join(dir, ".eval_history", "**", "*.jsonl"))
          expect(history_files).not_to be_empty

          # The report includes both pass and fail cases — history records the combined score
          content = File.read(history_files.first)
          run_data = JSON.parse(content.strip, symbolize_names: true)
          expect(run_data[:score]).to eq(0.5) # 1 pass, 1 fail
          expect(run_data[:pass_rate]).to eq("1/2")
        end
      end
    end

    it "does not create history files when track_history is false" do
      step.define_eval("no_history") do
        add_case "billing", input: "charged twice", expected: { priority: "high" }
      end

      adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"priority": "high"}')

      Dir.mktmpdir do |dir|
        Dir.chdir(dir) do
          task = RubyLLM::Contract::RakeTask.new(:"test_no_history_#{rand(10_000)}") do |t|
            t.context = { adapter: adapter }
            t.track_history = false
          end

          Rake::Task[task.name].invoke

          history_files = Dir.glob(File.join(dir, ".eval_history", "**", "*.jsonl"))
          expect(history_files).to be_empty
        end
      end
    end

    it "passes model from context to save_history!" do
      step.define_eval("model_track") do
        add_case "billing", input: "charged twice", expected: { priority: "high" }
      end

      adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"priority": "high"}')

      Dir.mktmpdir do |dir|
        Dir.chdir(dir) do
          task = RubyLLM::Contract::RakeTask.new(:"test_history_model_#{rand(10_000)}") do |t|
            t.context = { adapter: adapter, model: "gpt-4o-mini" }
            t.track_history = true
          end

          Rake::Task[task.name].invoke

          history_files = Dir.glob(File.join(dir, ".eval_history", "**", "*.jsonl"))
          expect(history_files).not_to be_empty
          # Model name should appear in the filename
          expect(history_files.first).to include("gpt-4o-mini")
        end
      end
    end

    it "resolves lazy context (Proc) before extracting model" do
      step.define_eval("lazy_history") do
        add_case "billing", input: "charged twice", expected: { priority: "high" }
      end

      adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"priority": "high"}')

      Dir.mktmpdir do |dir|
        Dir.chdir(dir) do
          task = RubyLLM::Contract::RakeTask.new(:"test_lazy_history_#{rand(10_000)}") do |t|
            t.context = -> { { adapter: adapter, model: "gpt-4o" } }
            t.track_history = true
          end

          Rake::Task[task.name].invoke

          history_files = Dir.glob(File.join(dir, ".eval_history", "**", "*.jsonl"))
          expect(history_files).not_to be_empty
          expect(history_files.first).to include("gpt-4o")
        end
      end
    end
  end
end
