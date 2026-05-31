# frozen_string_literal: true

require "ruby_llm/contract/rake_task"

RSpec.describe RubyLLM::Contract::OptimizeRakeTask do
  let(:task) { described_class.new }

  def with_env(overrides)
    original = overrides.each_with_object({}) { |(k, _), h| h[k] = ENV[k] }
    overrides.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
    yield
  ensure
    original.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end

  describe "#build_context" do

    it "returns empty context by default (offline mode)" do
      with_env("LIVE" => nil, "PROVIDER" => nil) do
        ctx = task.send(:build_context)
        expect(ctx).not_to have_key(:adapter)
        expect(ctx).not_to have_key(:provider)
      end
    end

    it "injects adapter when LIVE=1" do
      with_env("LIVE" => "1", "PROVIDER" => nil) do
        ctx = task.send(:build_context)
        expect(ctx[:adapter]).to be_a(RubyLLM::Contract::Adapters::RubyLLM)
      end
    end

    it "injects adapter and provider when PROVIDER is set" do
      with_env("LIVE" => nil, "PROVIDER" => "openai") do
        ctx = task.send(:build_context)
        expect(ctx[:adapter]).to be_a(RubyLLM::Contract::Adapters::RubyLLM)
        expect(ctx[:provider]).to eq(:openai)
      end
    end

    it "treats empty PROVIDER same as nil (no adapter injected)" do
      with_env("LIVE" => nil, "PROVIDER" => "") do
        ctx = task.send(:build_context)
        expect(ctx).not_to have_key(:adapter)
      end
    end
  end

  describe "EVAL_DIRS support" do
    # Both tests now invoke the REAL rake task body (previously they
    # re-implemented the EVAL_DIRS parsing inline in the spec, which made
    # the `expect.to receive(:load_evals!)` matcher trivially pass — a
    # FACADE: the production task body could be deleted entirely and the
    # tests would still go green).
    #
    # The task aborts with SystemExit on missing STEP, but `load_evals!`
    # is called BEFORE that abort, so we can verify the call shape and
    # let the abort raise.

    it "passes EVAL_DIRS to load_evals! when env is set" do
      with_env("EVAL_DIRS" => "lib/evals,extra/evals", "STEP" => "", "CANDIDATES" => "") do
        expect(RubyLLM::Contract).to receive(:load_evals!).with("lib/evals", "extra/evals").and_return(nil)

        # Task aborts on missing STEP after load_evals!, so swallow the
        # SystemExit to keep this test focused on the EVAL_DIRS contract.
        expect { Rake::Task["ruby_llm_contract:optimize"].reenable; Rake::Task["ruby_llm_contract:optimize"].invoke }
          .to raise_error(SystemExit)
      end
    end

    it "calls load_evals! without args when EVAL_DIRS is unset" do
      with_env("EVAL_DIRS" => nil, "STEP" => "", "CANDIDATES" => "") do
        expect(RubyLLM::Contract).to receive(:load_evals!).with(no_args).and_return(nil)

        expect { Rake::Task["ruby_llm_contract:optimize"].reenable; Rake::Task["ruby_llm_contract:optimize"].invoke }
          .to raise_error(SystemExit)
      end
    end
  end

  describe "LIVE=1 end-to-end" do
    it "online context includes adapter, offline does not" do
      task = described_class.new

      with_env("LIVE" => nil, "PROVIDER" => nil) do
        offline = task.send(:build_context)
        expect(offline).not_to have_key(:adapter)
      end

      with_env("LIVE" => "1", "PROVIDER" => nil) do
        online = task.send(:build_context)
        expect(online).to have_key(:adapter)
        expect(online[:adapter]).to be_a(RubyLLM::Contract::Adapters::RubyLLM)
      end
    end
  end

  describe "#parse_candidates" do
    let(:task) { described_class.new }

    it "parses comma-separated candidates" do
      result = task.send(:parse_candidates, "gpt-5-nano,gpt-5-mini")
      expect(result).to eq([{ model: "gpt-5-nano" }, { model: "gpt-5-mini" }])
    end

    it "parses candidates with reasoning_effort" do
      result = task.send(:parse_candidates, "gpt-5-nano,gpt-5-mini@low,gpt-5-mini")
      expect(result).to include({ model: "gpt-5-mini", reasoning_effort: "low" })
    end

    it "parses JSON array format" do
      json = '[{"model":"gpt-5-mini","reasoning_effort":"low"}]'
      result = task.send(:parse_candidates, json)
      expect(result).to eq([{ model: "gpt-5-mini", reasoning_effort: "low" }])
    end
  end

  describe "#parse_runs" do
    it "accepts a valid integer >= 1" do
      expect(task.send(:parse_runs, "3")).to eq(3)
      expect(task.send(:parse_runs, " 1 ")).to eq(1)
    end

    it "aborts on non-integer input" do
      expect { task.send(:parse_runs, "abc") }.to raise_error(SystemExit, /integer >= 1/)
    end

    it "aborts on zero or negative" do
      expect { task.send(:parse_runs, "0") }.to raise_error(SystemExit, /integer >= 1/)
      expect { task.send(:parse_runs, "-1") }.to raise_error(SystemExit, /integer >= 1/)
    end

    it "aborts on empty string" do
      expect { task.send(:parse_runs, "") }.to raise_error(SystemExit, /integer >= 1/)
    end
  end
end
