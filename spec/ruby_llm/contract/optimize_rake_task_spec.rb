# frozen_string_literal: true

require "ruby_llm/contract/rake_task"

RSpec.describe RubyLLM::Contract::OptimizeRakeTask do
  describe "#build_context" do
    let(:task) { described_class.new }

    def with_env(overrides)
      original = overrides.each_with_object({}) { |(k, _), h| h[k] = ENV[k] }
      overrides.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
      yield
    ensure
      original.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
    end

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

    it "does not use ActiveSupport String#presence" do
      # Verify that .presence is NOT called — plain Ruby .empty? is used instead.
      # This ensures the task works outside Rails/ActiveSupport.
      with_env("LIVE" => nil, "PROVIDER" => "") do
        ctx = task.send(:build_context)
        expect(ctx).not_to have_key(:adapter)
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
end
