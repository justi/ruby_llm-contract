# frozen_string_literal: true

RSpec.describe RubyLLM::Contract::Prompt::Renderer do
  describe ".render" do
    it "renders system, rule, user nodes to correct messages in order" do
      ast = RubyLLM::Contract::Prompt::Builder.build do
        system "Classify the user's intent."
        rule "Return JSON only."
        user "{input}"
      end

      messages = described_class.render(ast, variables: { input: "hello" })

      expect(messages).to eq([
                               { role: :system, content: "Classify the user's intent." },
                               { role: :system, content: "Return JSON only." },
                               { role: :user, content: "hello" }
                             ])
    end

    it "interpolates {input} placeholder in user node" do
      ast = RubyLLM::Contract::Prompt::Builder.build do
        user "{input}"
      end

      messages = described_class.render(ast, variables: { input: "I need help" })
      expect(messages[0][:content]).to eq("I need help")
    end

    it "produces identical results for the same AST and variables" do
      ast = RubyLLM::Contract::Prompt::Builder.build do
        system "System"
        user "{input}"
      end

      result1 = described_class.render(ast, variables: { input: "test" })
      result2 = described_class.render(ast, variables: { input: "test" })

      expect(result1).to eq(result2)
    end

    it "renders ExampleNode as user/assistant message pair" do
      ast = RubyLLM::Contract::Prompt::Builder.build do
        example input: "What is 2+2?", output: "4"
      end

      messages = described_class.render(ast)

      expect(messages).to eq([
                               { role: :user, content: "What is 2+2?" },
                               { role: :assistant, content: "4" }
                             ])
    end

    it "renders SectionNode as system message with bracketed name prefix" do
      ast = RubyLLM::Contract::Prompt::Builder.build do
        section "Output Format", "Return a JSON object."
      end

      messages = described_class.render(ast)

      expect(messages).to eq([
                               { role: :system, content: "[Output Format]\nReturn a JSON object." }
                             ])
    end

    it "leaves a placeholder as-is when no matching variable is provided" do
      ast = RubyLLM::Contract::Prompt::Builder.build do
        user "{missing_var}"
      end

      messages = described_class.render(ast, variables: {})
      expect(messages[0][:content]).to eq("{missing_var}")
    end

    it "interpolates multiple variables" do
      ast = RubyLLM::Contract::Prompt::Builder.build do
        user "{greeting} {name}"
      end

      messages = described_class.render(ast, variables: { greeting: "Hello", name: "World" })
      expect(messages[0][:content]).to eq("Hello World")
    end

    it "renders full heredoc replacement: system + rule + sections + user" do
      # This test mirrors the Step 6 example from 00_basics.rb:
      # a typical heredoc prompt converted to structured AST nodes.
      #
      # BEFORE (heredoc):
      #   <<~PROMPT
      #     You are a sentiment classifier for customer support.
      #     Return JSON with sentiment, confidence, and reason.
      #
      #     [CONTEXT]
      #     We sell software for freelancers.
      #
      #     [SCORING GUIDE]
      #     negative = complaint or frustration
      #     positive = praise or thanks
      #     neutral = question or factual statement
      #
      #     Classify this: #{text}
      #   PROMPT

      ast = RubyLLM::Contract::Prompt::Builder.build do
        system "You are a sentiment classifier for customer support."
        rule "Return JSON with sentiment, confidence, and reason."
        section "CONTEXT", "We sell software for freelancers."
        section "SCORING GUIDE",
                "negative = complaint or frustration\npositive = praise or thanks\nneutral = question or factual statement"
        user "Classify this: {input}"
      end

      messages = described_class.render(ast, variables: { input: "Your billing page is broken!" })

      expect(messages).to eq([
                               { role: :system, content: "You are a sentiment classifier for customer support." },
                               { role: :system, content: "Return JSON with sentiment, confidence, and reason." },
                               { role: :system, content: "[CONTEXT]\nWe sell software for freelancers." },
                               { role: :system,
                                 content: "[SCORING GUIDE]\nnegative = complaint or frustration\npositive = praise or thanks\nneutral = question or factual statement" },
                               { role: :user, content: "Classify this: Your billing page is broken!" }
                             ])
    end

    it "omits messages with nil content" do
      ast = RubyLLM::Contract::Prompt::Builder.build(input: { text: nil }) do |input|
        system "Classify intent."
        section "CONTEXT", input[:text]
        user "do it"
      end

      messages = described_class.render(ast, variables: {})

      expect(messages).to eq([
                               { role: :system, content: "Classify intent." },
                               { role: :user, content: "do it" }
                             ])
    end

    it "omits messages with blank content" do
      ast = RubyLLM::Contract::Prompt::Builder.build(input: { ctx: "" }) do |input|
        system "Classify."
        section "DATA", input[:ctx]
        rule "Return JSON."
        user "go"
      end

      messages = described_class.render(ast, variables: {})

      expect(messages).to eq([
                               { role: :system, content: "Classify." },
                               { role: :system, content: "Return JSON." },
                               { role: :user, content: "go" }
                             ])
    end

    it "omits example nodes with nil input or output" do
      ast = RubyLLM::Contract::Prompt::Builder.build do
        system "Classify."
        example input: nil, output: nil
        user "go"
      end

      messages = described_class.render(ast, variables: {})

      expect(messages.size).to eq(2)
      expect(messages.map { |m| m[:role] }).to eq(%i[system user])
    end

    it "omits section where name is present but content is nil" do
      ast = RubyLLM::Contract::Prompt::Builder.build(input: nil) do |_input|
        system "Hello."
        section "EMPTY", nil
        user "test"
      end

      messages = described_class.render(ast, variables: {})
      contents = messages.map { |m| m[:content] }

      expect(contents).not_to include(a_string_matching(/EMPTY/))
      expect(messages.size).to eq(2)
    end

    it "sanitizes section names by stripping brackets and newlines" do
      ast = RubyLLM::Contract::Prompt::Builder.build do
        section "[INJECTED]\nEvil", "content"
      end

      messages = described_class.render(ast, variables: {})
      content = messages.first[:content]

      expect(content).not_to include("\n[")
      expect(content).to start_with("[")
      # The sanitized name should not contain raw brackets or newlines
      name_part = content.split("\n").first
      expect(name_part).not_to include("[[")
      expect(name_part).not_to include("]\n")
    end

    it "coerces non-String content (Integer) to String via interpolate" do
      ast = RubyLLM::Contract::Prompt::Builder.build do
        user 42
      end

      messages = described_class.render(ast, variables: {})
      expect(messages.first[:content]).to eq("42")
    end

    it "coerces Symbol content to String via interpolate" do
      ast = RubyLLM::Contract::Prompt::Builder.build do
        system :classify
      end

      messages = described_class.render(ast, variables: {})
      expect(messages.first[:content]).to eq("classify")
    end

    it "interpolates Hash/Array variables as JSON strings" do
      ast = RubyLLM::Contract::Prompt::Builder.build do
        user "data: {data}"
      end

      messages = described_class.render(ast, variables: { data: { key: "val" } })
      expect(messages.first[:content]).to include('"key"')
      expect(messages.first[:content]).to include('"val"')
    end
  end
end
