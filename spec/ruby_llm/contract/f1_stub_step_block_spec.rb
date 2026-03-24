# frozen_string_literal: true

require "ruby_llm/contract/rspec"
require "ruby_llm/contract/minitest"

# -----------------------------------------------------------------------
# Test step classes used across both RSpec and Minitest helper specs.
# Each returns a different JSON shape so we can verify per-step routing.
# -----------------------------------------------------------------------
class F1StepAlpha < RubyLLM::Contract::Step::Base
  prompt { user "{input}" }
  output_type RubyLLM::Contract::Types::Hash
  contract { parse :json }
end

class F1StepBeta < RubyLLM::Contract::Step::Base
  prompt { user "{input}" }
  output_type RubyLLM::Contract::Types::Hash
  contract { parse :json }
end

# =========================================================================
# RSpec helpers
# =========================================================================
RSpec.describe "F1: stub_step block form — RSpec helpers" do
  before do
    RubyLLM::Contract.reset_configuration!
    RubyLLM::Contract.step_adapter_overrides.clear
  end

  # ---- stub_all_steps with block: adapter reset after block ----

  describe "stub_all_steps with block" do
    it "restores the previous adapter after the block" do
      original_adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"from":"original"}')
      RubyLLM::Contract.configuration.default_adapter = original_adapter

      stub_all_steps(response: '{"from":"block"}') do
        expect(RubyLLM::Contract.configuration.default_adapter).not_to eq(original_adapter)
        result = F1StepAlpha.run("x")
        expect(result.parsed_output).to eq({ from: "block" })
      end

      expect(RubyLLM::Contract.configuration.default_adapter).to eq(original_adapter)
    end

    it "restores adapter even when block raises" do
      original_adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"ok":true}')
      RubyLLM::Contract.configuration.default_adapter = original_adapter

      begin
        stub_all_steps(response: '{"ok":false}') do
          raise "boom"
        end
      rescue RuntimeError
        nil
      end

      expect(RubyLLM::Contract.configuration.default_adapter).to eq(original_adapter)
    end

    it "still works without a block (backward compatible)" do
      stub_all_steps(response: '{"compat":true}')
      result = F1StepAlpha.run("x")
      expect(result.parsed_output).to eq({ compat: true })
    end
  end

  # ---- stub_step with block: works and cleans up ----

  describe "stub_step with block" do
    it "stubs inside the block and works" do
      stub_step(F1StepAlpha, response: '{"inside":"block"}') do
        result = F1StepAlpha.run("x")
        expect(result.parsed_output).to eq({ inside: "block" })
      end
    end

    it "still works without a block (backward compatible)" do
      stub_step(F1StepAlpha, response: '{"compat":true}')
      result = F1StepAlpha.run("x")
      expect(result.parsed_output).to eq({ compat: true })
    end

    it "routes per-step — different responses per step class" do
      stub_step(F1StepAlpha, response: '{"step":"alpha"}')
      stub_step(F1StepBeta, response: '{"step":"beta"}')

      result_a = F1StepAlpha.run("x")
      result_b = F1StepBeta.run("x")

      expect(result_a.parsed_output).to eq({ step: "alpha" })
      expect(result_b.parsed_output).to eq({ step: "beta" })
    end
  end

  # ---- Nested blocks: inner restores to outer's adapter ----

  describe "nested stub_all_steps blocks" do
    it "inner block restores to outer adapter, not to original" do
      original_adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"level":"original"}')
      RubyLLM::Contract.configuration.default_adapter = original_adapter

      stub_all_steps(response: '{"level":"outer"}') do
        outer_adapter = RubyLLM::Contract.configuration.default_adapter

        stub_all_steps(response: '{"level":"inner"}') do
          result = F1StepAlpha.run("x")
          expect(result.parsed_output).to eq({ level: "inner" })
        end

        # After inner block, should be back to outer adapter
        expect(RubyLLM::Contract.configuration.default_adapter).to eq(outer_adapter)
        result = F1StepAlpha.run("x")
        expect(result.parsed_output).to eq({ level: "outer" })
      end

      # After outer block, should be back to original
      expect(RubyLLM::Contract.configuration.default_adapter).to eq(original_adapter)
    end
  end

  # ---- stub_steps (plural) ----

  describe "stub_steps (plural)" do
    it "stubs multiple steps with different responses in one block" do
      stub_steps(
        F1StepAlpha => { response: '{"step":"alpha"}' },
        F1StepBeta => { response: '{"step":"beta"}' }
      ) do
        result_a = F1StepAlpha.run("x")
        result_b = F1StepBeta.run("x")
        expect(result_a.parsed_output).to eq({ step: "alpha" })
        expect(result_b.parsed_output).to eq({ step: "beta" })
      end
    end

    it "requires a block" do
      expect {
        stub_steps(F1StepAlpha => { response: '{"x":1}' })
      }.to raise_error(ArgumentError, /requires a block/)
    end
  end
end

# =========================================================================
# Minitest helpers — tested from RSpec by including the module directly
# =========================================================================
RSpec.describe "F1: stub_step block form — Minitest helpers" do
  include RubyLLM::Contract::MinitestHelpers

  before do
    RubyLLM::Contract.reset_configuration!
    RubyLLM::Contract.step_adapter_overrides.clear
  end

  # ---- stub_step routes per-step (parity fix) ----

  describe "stub_step per-step routing" do
    it "routes different responses to different step classes" do
      # Set a fallback adapter so unstubbed steps have something
      fallback = RubyLLM::Contract::Adapters::Test.new(response: '{"step":"fallback"}')
      RubyLLM::Contract.configuration.default_adapter = fallback

      stub_step(F1StepAlpha, response: '{"step":"alpha"}')
      stub_step(F1StepBeta, response: '{"step":"beta"}')

      result_a = F1StepAlpha.run("x")
      result_b = F1StepBeta.run("x")

      expect(result_a.parsed_output).to eq({ step: "alpha" })
      expect(result_b.parsed_output).to eq({ step: "beta" })
    end
  end

  # ---- stub_step with block: adapter reset after block ----

  describe "stub_step with block" do
    it "stubs inside the block and cleans up after" do
      fallback = RubyLLM::Contract::Adapters::Test.new(response: '{"step":"fallback"}')
      RubyLLM::Contract.configuration.default_adapter = fallback

      stub_step(F1StepAlpha, response: '{"step":"stubbed"}') do
        result = F1StepAlpha.run("x")
        expect(result.parsed_output).to eq({ step: "stubbed" })
      end

      # After block, step should fall back to the default adapter
      result = F1StepAlpha.run("x")
      expect(result.parsed_output).to eq({ step: "fallback" })
    end

    it "cleans up even when block raises" do
      fallback = RubyLLM::Contract::Adapters::Test.new(response: '{"step":"fallback"}')
      RubyLLM::Contract.configuration.default_adapter = fallback

      begin
        stub_step(F1StepAlpha, response: '{"step":"stubbed"}') do
          raise "boom"
        end
      rescue RuntimeError
        nil
      end

      result = F1StepAlpha.run("x")
      expect(result.parsed_output).to eq({ step: "fallback" })
    end
  end

  # ---- stub_all_steps with block ----

  describe "stub_all_steps with block" do
    it "restores the previous adapter after the block" do
      original = RubyLLM::Contract::Adapters::Test.new(response: '{"from":"original"}')
      RubyLLM::Contract.configuration.default_adapter = original

      stub_all_steps(response: '{"from":"block"}') do
        result = F1StepAlpha.run("x")
        expect(result.parsed_output).to eq({ from: "block" })
      end

      expect(RubyLLM::Contract.configuration.default_adapter).to eq(original)
    end
  end

  # ---- Nested blocks ----

  describe "nested stub_step blocks" do
    it "inner block restores to outer adapter, not to original" do
      fallback = RubyLLM::Contract::Adapters::Test.new(response: '{"level":"fallback"}')
      RubyLLM::Contract.configuration.default_adapter = fallback

      stub_step(F1StepAlpha, response: '{"level":"outer"}') do
        stub_step(F1StepAlpha, response: '{"level":"inner"}') do
          result = F1StepAlpha.run("x")
          expect(result.parsed_output).to eq({ level: "inner" })
        end

        # After inner block, outer stub should still be active
        result = F1StepAlpha.run("x")
        expect(result.parsed_output).to eq({ level: "outer" })
      end

      # After outer block, should fall back to default
      result = F1StepAlpha.run("x")
      expect(result.parsed_output).to eq({ level: "fallback" })
    end
  end

  # ---- stub_steps (plural) ----

  describe "stub_steps (plural)" do
    it "stubs multiple steps with different responses in one block" do
      fallback = RubyLLM::Contract::Adapters::Test.new(response: '{"step":"fallback"}')
      RubyLLM::Contract.configuration.default_adapter = fallback

      stub_steps(
        F1StepAlpha => { response: '{"step":"alpha"}' },
        F1StepBeta => { response: '{"step":"beta"}' }
      ) do
        result_a = F1StepAlpha.run("x")
        result_b = F1StepBeta.run("x")
        expect(result_a.parsed_output).to eq({ step: "alpha" })
        expect(result_b.parsed_output).to eq({ step: "beta" })
      end

      # After block, both should fall back to default
      result_a = F1StepAlpha.run("x")
      result_b = F1StepBeta.run("x")
      expect(result_a.parsed_output).to eq({ step: "fallback" })
      expect(result_b.parsed_output).to eq({ step: "fallback" })
    end

    it "requires a block" do
      expect {
        stub_steps(F1StepAlpha => { response: '{"x":1}' })
      }.to raise_error(ArgumentError, /requires a block/)
    end
  end
end
