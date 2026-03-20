# frozen_string_literal: true

RSpec.describe RubyLLM::Contract::Configuration do
  before { RubyLLM::Contract.reset_configuration! }

  describe "RubyLLM::Contract.configuration" do
    it "returns a Configuration instance" do
      expect(RubyLLM::Contract.configuration).to be_a(described_class)
    end
  end

  describe "RubyLLM::Contract.configure" do
    it "yields the configuration" do
      RubyLLM::Contract.configure do |config|
        expect(config).to be_a(described_class)
      end
    end

    it "allows setting default_adapter" do
      adapter = RubyLLM::Contract::Adapters::Test.new(response: "test")
      RubyLLM::Contract.configure { |c| c.default_adapter = adapter }
      expect(RubyLLM::Contract.configuration.default_adapter).to eq(adapter)
    end

    it "allows setting default_model" do
      RubyLLM::Contract.configure { |c| c.default_model = "gpt-4.1-mini" }
      expect(RubyLLM::Contract.configuration.default_model).to eq("gpt-4.1-mini")
    end

    it "auto-creates RubyLLM adapter when no adapter set" do
      RubyLLM::Contract.configure { |c| c.default_model = "gpt-4.1-mini" }
      expect(RubyLLM::Contract.configuration.default_adapter).to be_a(RubyLLM::Contract::Adapters::RubyLLM)
    end

    it "does not overwrite explicitly set adapter" do
      adapter = RubyLLM::Contract::Adapters::Test.new(response: "test")
      RubyLLM::Contract.configure { |c| c.default_adapter = adapter }
      expect(RubyLLM::Contract.configuration.default_adapter).to eq(adapter)
    end
  end

  describe "RubyLLM::Contract.reset_configuration!" do
    it "resets to defaults" do
      RubyLLM::Contract.configure { |c| c.default_model = "some-model" }
      RubyLLM::Contract.reset_configuration!
      expect(RubyLLM::Contract.configuration.default_model).to be_nil
    end
  end

  describe "defaults" do
    it "has nil default_adapter" do
      expect(described_class.new.default_adapter).to be_nil
    end

    it "has nil default_model" do
      expect(described_class.new.default_model).to be_nil
    end
  end
end
