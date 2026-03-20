# frozen_string_literal: true

RSpec.describe RubyLLM::Contract::Prompt::Builder do
  describe ".build" do
    it "produces nodes in declaration order" do
      ast = described_class.build do
        system "Classify the user's intent."
        rule "Return JSON only."
        user "{input}"
      end

      expect(ast.nodes.map(&:type)).to eq(%i[system rule user])
    end

    it "produces a SystemNode with correct content" do
      ast = described_class.build do
        system "System instruction"
      end

      expect(ast[0]).to be_a(RubyLLM::Contract::Prompt::Nodes::SystemNode)
      expect(ast[0].content).to eq("System instruction")
    end

    it "produces a RuleNode with correct content" do
      ast = described_class.build do
        rule "A rule"
      end

      expect(ast[0]).to be_a(RubyLLM::Contract::Prompt::Nodes::RuleNode)
      expect(ast[0].content).to eq("A rule")
    end

    it "produces an ExampleNode with input and output" do
      ast = described_class.build do
        example input: "What is 2+2?", output: "4"
      end

      node = ast[0]
      expect(node).to be_a(RubyLLM::Contract::Prompt::Nodes::ExampleNode)
      expect(node.input).to eq("What is 2+2?")
      expect(node.output).to eq("4")
    end

    it "produces a UserNode with content" do
      ast = described_class.build do
        user "{input}"
      end

      expect(ast[0]).to be_a(RubyLLM::Contract::Prompt::Nodes::UserNode)
      expect(ast[0].content).to eq("{input}")
    end

    it "produces a SectionNode with name and content" do
      ast = described_class.build do
        section "Output Format", "Return a JSON object."
      end

      node = ast[0]
      expect(node).to be_a(RubyLLM::Contract::Prompt::Nodes::SectionNode)
      expect(node.name).to eq("Output Format")
      expect(node.content).to eq("Return a JSON object.")
    end

    it "returns an immutable AST" do
      ast = described_class.build do
        system "Test"
      end

      expect(ast).to be_frozen
    end
  end

  describe "#build" do
    it "works with instance method" do
      block = proc do
        system "Hello"
        user "{input}"
      end

      builder = described_class.new(block)
      ast = builder.build

      expect(ast.size).to eq(2)
      expect(ast[0].type).to eq(:system)
      expect(ast[1].type).to eq(:user)
    end
  end
end
