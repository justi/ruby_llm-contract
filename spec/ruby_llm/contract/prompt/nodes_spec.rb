# frozen_string_literal: true

RSpec.describe "Prompt AST Nodes" do
  describe RubyLLM::Contract::Prompt::Nodes::SystemNode do
    subject(:node) { described_class.new("You are a helpful assistant.") }

    it "has type :system" do
      expect(node.type).to eq(:system)
    end

    it "stores content" do
      expect(node.content).to eq("You are a helpful assistant.")
    end

    it "is frozen" do
      expect(node).to be_frozen
    end

    it "returns correct to_h" do
      expect(node.to_h).to eq({ type: :system, content: "You are a helpful assistant." })
    end

    it "equals another SystemNode with the same content" do
      other = described_class.new("You are a helpful assistant.")
      expect(node).to eq(other)
    end

    it "does not equal a SystemNode with different content" do
      other = described_class.new("Different content")
      expect(node).not_to eq(other)
    end
  end

  describe RubyLLM::Contract::Prompt::Nodes::RuleNode do
    subject(:node) { described_class.new("Return JSON only.") }

    it "has type :rule" do
      expect(node.type).to eq(:rule)
    end

    it "stores content" do
      expect(node.content).to eq("Return JSON only.")
    end

    it "is frozen" do
      expect(node).to be_frozen
    end

    it "returns correct to_h" do
      expect(node.to_h).to eq({ type: :rule, content: "Return JSON only." })
    end

    it "equals another RuleNode with the same content" do
      other = described_class.new("Return JSON only.")
      expect(node).to eq(other)
    end
  end

  describe RubyLLM::Contract::Prompt::Nodes::ExampleNode do
    subject(:node) { described_class.new(input: "What is 2+2?", output: "4") }

    it "has type :example" do
      expect(node.type).to eq(:example)
    end

    it "stores input and output separately" do
      expect(node.input).to eq("What is 2+2?")
      expect(node.output).to eq("4")
    end

    it "has nil content" do
      expect(node.content).to be_nil
    end

    it "is frozen" do
      expect(node).to be_frozen
    end

    it "returns correct to_h" do
      expect(node.to_h).to eq({ type: :example, input: "What is 2+2?", output: "4" })
    end

    it "equals another ExampleNode with the same input and output" do
      other = described_class.new(input: "What is 2+2?", output: "4")
      expect(node).to eq(other)
    end

    it "does not equal an ExampleNode with different input" do
      other = described_class.new(input: "What is 3+3?", output: "4")
      expect(node).not_to eq(other)
    end
  end

  describe RubyLLM::Contract::Prompt::Nodes::UserNode do
    subject(:node) { described_class.new("{input}") }

    it "has type :user" do
      expect(node.type).to eq(:user)
    end

    it "stores content with placeholder" do
      expect(node.content).to eq("{input}")
    end

    it "is frozen" do
      expect(node).to be_frozen
    end

    it "returns correct to_h" do
      expect(node.to_h).to eq({ type: :user, content: "{input}" })
    end
  end

  describe RubyLLM::Contract::Prompt::Nodes::SectionNode do
    subject(:node) { described_class.new("Output Format", "Return a JSON object.") }

    it "has type :section" do
      expect(node.type).to eq(:section)
    end

    it "stores name" do
      expect(node.name).to eq("Output Format")
    end

    it "stores content" do
      expect(node.content).to eq("Return a JSON object.")
    end

    it "is frozen" do
      expect(node).to be_frozen
    end

    it "returns correct to_h" do
      expect(node.to_h).to eq({ type: :section, name: "Output Format", content: "Return a JSON object." })
    end

    it "equals another SectionNode with the same name and content" do
      other = described_class.new("Output Format", "Return a JSON object.")
      expect(node).to eq(other)
    end

    it "does not equal a SectionNode with different name" do
      other = described_class.new("Input Format", "Return a JSON object.")
      expect(node).not_to eq(other)
    end
  end
end
