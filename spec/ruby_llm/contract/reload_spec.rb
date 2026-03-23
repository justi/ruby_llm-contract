# frozen_string_literal: true

RSpec.describe "Eval reload lifecycle" do
  before do
    RubyLLM::Contract.reset_configuration!
    RubyLLM::Contract.reset_eval_hosts!
  end

  describe "load_evals! preserves inline, clears file-sourced" do
    it "inline define_eval survives load_evals!" do
      step = Class.new(RubyLLM::Contract::Step::Base) do
        prompt { user "{input}" }
      end

      step.define_eval("inline_eval") do
        default_input "test"
        sample_response({ v: 1 })
      end

      expect(step.eval_names).to include("inline_eval")

      Dir.mktmpdir do |dir|
        RubyLLM::Contract.load_evals!(dir)
      end

      expect(step.eval_names).to include("inline_eval")
    end

    it "reload flag suppresses warning on redefine" do
      step = Class.new(RubyLLM::Contract::Step::Base) do
        prompt { user "{input}" }
      end

      step.define_eval("smoke") do
        default_input "test"
        sample_response({ v: 1 })
      end

      # During reload, redefine should NOT warn
      Thread.current[:ruby_llm_contract_reloading] = true
      expect do
        step.define_eval("smoke") do
          default_input "test2"
          sample_response({ v: 2 })
        end
      end.not_to output.to_stderr
    ensure
      Thread.current[:ruby_llm_contract_reloading] = false
    end

    it "outside reload, redefine DOES warn" do
      step = Class.new(RubyLLM::Contract::Step::Base) do
        prompt { user "{input}" }
      end

      step.define_eval("smoke") do
        default_input "test"
        sample_response({ v: 1 })
      end

      expect(step).to receive(:warn).with(/Redefining eval 'smoke'/i)

      step.define_eval("smoke") do
        default_input "test2"
        sample_response({ v: 2 })
      end
    end
  end

  describe "live_eval_hosts filters stale hosts" do
    it "run_all_evals skips hosts with no eval definitions" do
      step = Class.new(RubyLLM::Contract::Step::Base) do
        prompt { user "{input}" }
      end

      step.define_eval("smoke") do
        default_input "test"
        sample_response({ v: 1 })
      end

      # Host is registered
      expect(RubyLLM::Contract.eval_hosts).to include(step)

      # Clear its evals (simulates reload where eval file was deleted)
      step.clear_file_sourced_evals!
      # For this test, the eval was defined inline (not file-sourced),
      # so we need to directly clear to simulate deletion
      step.instance_variable_set(:@eval_definitions, {})

      # run_all_evals should skip it (live_eval_hosts filters)
      results = RubyLLM::Contract.run_all_evals
      expect(results.keys).not_to include(step)
    end
  end
end
