# frozen_string_literal: true

RSpec.describe RubyLLM::Contract::Prompt::AST do
  let(:system_node) { RubyLLM::Contract::Prompt::Nodes::SystemNode.new("System instruction") }
  let(:rule_node) { RubyLLM::Contract::Prompt::Nodes::RuleNode.new("A rule") }
  let(:user_node) { RubyLLM::Contract::Prompt::Nodes::UserNode.new("{input}") }
  let(:ast) { described_class.new([system_node, rule_node, user_node]) }

  describe "#nodes" do
    it "returns the nodes in insertion order" do
      expect(ast.nodes).to eq([system_node, rule_node, user_node])
    end

    it "returns a frozen array" do
      expect(ast.nodes).to be_frozen
    end
  end

  describe "immutability" do
    it "is frozen after construction" do
      expect(ast).to be_frozen
    end

    it "prevents modification of the nodes array" do
      expect { ast.nodes << RubyLLM::Contract::Prompt::Nodes::RuleNode.new("new rule") }.to raise_error(FrozenError)
    end
  end

  describe "#each" do
    it "iterates in insertion order" do
      collected = ast.map(&:type)
      expect(collected).to eq(%i[system rule user])
    end
  end

  describe "Enumerable" do
    it "supports map" do
      types = ast.map(&:type)
      expect(types).to eq(%i[system rule user])
    end
  end

  describe "#size" do
    it "returns the correct count" do
      expect(ast.size).to eq(3)
    end
  end

  describe "#[]" do
    it "returns the correct node by index" do
      expect(ast[0]).to eq(system_node)
      expect(ast[1]).to eq(rule_node)
      expect(ast[2]).to eq(user_node)
    end
  end

  describe "#==" do
    it "returns true for ASTs with identical nodes" do
      other = described_class.new([system_node, rule_node, user_node])
      expect(ast).to eq(other)
    end

    it "returns false for ASTs with different nodes" do
      other = described_class.new([system_node])
      expect(ast).not_to eq(other)
    end
  end

  describe "#to_a" do
    it "returns array of hashes" do
      expected = [
        { type: :system, content: "System instruction" },
        { type: :rule, content: "A rule" },
        { type: :user, content: "{input}" }
      ]
      expect(ast.to_a).to eq(expected)
    end
  end
end
