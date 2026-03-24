# frozen_string_literal: true

require "tmpdir"

RSpec.describe "Railtie" do
  describe "eager_load_contract_dirs!" do
    it "calls eager_load_dir on existing contract directories" do
      skip "Rails not loaded" unless defined?(::Rails)

      expect { RubyLLM::Contract.send(:eager_load_contract_dirs!) }.not_to raise_error
    end
  end

  describe "load_evals! without Rails" do
    it "does not call eager_load when Rails is not defined" do
      RubyLLM::Contract.reset_eval_hosts!

      # Without Rails, load_evals! with empty dirs is a no-op
      expect { RubyLLM::Contract.load_evals! }.not_to raise_error
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
