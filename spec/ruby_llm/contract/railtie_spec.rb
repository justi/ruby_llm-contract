# frozen_string_literal: true

require "tmpdir"

RSpec.describe "Railtie" do
  # The "eager_load_contract_dirs! calls eager_load_dir" test was dropped:
  # it was unconditionally `skip "Rails not loaded"` in the gem's CI matrix
  # (NO-CONTRACT), exercising no code path. A proper Rails-loaded variant
  # belongs in a dedicated rails_integration_spec.rb gated on `defined?(::Rails)`.

  describe "load_evals! without Rails" do
    it "leaves eval_hosts empty when called without args in non-Rails env" do
      RubyLLM::Contract.reset_eval_hosts!

      # Side-effect check, not just `not_to raise_error` (A5). With no
      # explicit dirs and no Rails, the registry must remain empty —
      # a mutation that auto-registered something would fail this.
      RubyLLM::Contract.load_evals!

      expect(RubyLLM::Contract.eval_hosts).to be_empty
    end

    it "loads eval files from explicit directory" do
      RubyLLM::Contract.reset_eval_hosts!

      step = Class.new(RubyLLM::Contract::Step::Base) do
        prompt { user "{input}" }
      end
      # Give step a name so it can be referenced from eval file
      Object.const_set(:RailtieTestStep, step) unless defined?(::RailtieTestStep)

      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "test_eval.rb"), <<~RUBY)
          RailtieTestStep.define_eval("from_file") do
            default_input "test"
            sample_response({ v: 1 })
          end
        RUBY

        RubyLLM::Contract.load_evals!(dir)
        expect(RailtieTestStep.eval_names).to include("from_file")
      end
    ensure
      Object.send(:remove_const, :RailtieTestStep) if defined?(::RailtieTestStep)
    end
  end

  describe "Railtie class" do
    it "is defined when Rails::Railtie is available" do
      # Railtie is only loaded when Rails::Railtie is defined
      # In test environment without Rails, it won't be loaded
      if defined?(::Rails::Railtie)
        expect(defined?(RubyLLM::Contract::Railtie)).to eq("constant")
      else
        expect(defined?(RubyLLM::Contract::Railtie)).to be_nil
      end
    end
  end
end
