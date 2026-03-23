# frozen_string_literal: true

class ClassifyIntent < RubyLLM::Contract::Step::Base
  input_type  RubyLLM::Contract::Types::String
  output_type RubyLLM::Contract::Types::Hash

  prompt do
    system "Classify the user's intent."
    rule   "Return JSON only."
    rule   "Allowed intents: sales, support, billing."
    user   "{input}"
  end

  contract do
    parse :json
    invariant("must include intent") { |output| output[:intent].to_s != "" }
    invariant("intent must be allowed") { |output| %w[sales support billing].include?(output[:intent]) }
  end
end

RSpec.describe "Step end-to-end integration" do
  before { RubyLLM::Contract.reset_configuration! }

  let(:multi_invariant_step) do
    Class.new(RubyLLM::Contract::Step::Base) do
      input_type  RubyLLM::Contract::Types::String
      output_type RubyLLM::Contract::Types::Hash

      prompt do
        system "Extract data."
        user "{input}"
      end

      contract do
        parse :json
        invariant("must include name") { |o| o[:name].to_s != "" }
        invariant("must include age") { |o| o[:age].to_s != "" }
      end
    end
  end

  context "when happy path" do
    it "returns :ok with correct parsed output" do
      adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"intent":"billing"}')
      RubyLLM::Contract.configure { |c| c.default_adapter = adapter }

      result = ClassifyIntent.run("I need help with my invoice")

      expect(result.status).to eq(:ok)
      expect(result.ok?).to be true
      expect(result.parsed_output).to eq({ intent: "billing" })
      expect(result.raw_output).to eq('{"intent":"billing"}')
      expect(result.validation_errors).to be_empty
    end

    it "includes trace metadata" do
      adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"intent":"sales"}')
      result = ClassifyIntent.run("I need help", context: { adapter: adapter, model: "gpt-4.1-mini" })

      expect(result.trace[:messages]).to be_an(Array)
      expect(result.trace[:messages].length).to be >= 3
      expect(result.trace[:model]).to eq("gpt-4.1-mini")
      expect(result.trace[:latency_ms]).to be_a(Integer)
      expect(result.trace[:latency_ms]).to be >= 0
      expect(result.trace[:usage]).to be_a(Hash)
    end

    it "renders the prompt correctly with input interpolation" do
      adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"intent":"sales"}')
      result = ClassifyIntent.run("I need help", context: { adapter: adapter })

      messages = result.trace[:messages]
      user_msg = messages.find { |m| m[:role] == :user }
      expect(user_msg[:content]).to eq("I need help")
    end
  end

  context "when input error path" do
    it "returns :input_error for invalid input type" do
      adapter = RubyLLM::Contract::Adapters::Test.new(response: "unused")
      result = ClassifyIntent.run(42, context: { adapter: adapter })

      expect(result.status).to eq(:input_error)
      expect(result.failed?).to be true
      expect(result.validation_errors).not_to be_empty
      expect(result.raw_output).to be_nil
    end
  end

  context "when parse error path" do
    it "returns :parse_error for malformed JSON" do
      adapter = RubyLLM::Contract::Adapters::Test.new(response: "not json")
      result = ClassifyIntent.run("help me", context: { adapter: adapter })

      expect(result.status).to eq(:parse_error)
      expect(result.raw_output).to eq("not json")
      expect(result.parsed_output).to be_nil
    end
  end

  context "when validation failure path" do
    it "returns :validation_failed with invariant errors" do
      adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"intent":"unknown"}')
      result = ClassifyIntent.run("help me", context: { adapter: adapter })

      expect(result.status).to eq(:validation_failed)
      expect(result.validation_errors).to include("intent must be allowed")
      expect(result.raw_output).to eq('{"intent":"unknown"}')
      expect(result.parsed_output).to eq({ intent: "unknown" })
    end
  end

  context "when multiple invariant failures" do
    it "collects all failing invariant descriptions (no short-circuit)" do
      adapter = RubyLLM::Contract::Adapters::Test.new(response: "{}") # empty hash: both invariants fail
      result = multi_invariant_step.run("test", context: { adapter: adapter })

      expect(result.status).to eq(:validation_failed)
      expect(result.validation_errors).to contain_exactly("must include name", "must include age")
    end
  end

  context "when context adapter override" do
    it "uses context adapter instead of global default" do
      global_adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"intent":"sales"}')
      context_adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"intent":"support"}')
      RubyLLM::Contract.configure { |c| c.default_adapter = global_adapter }

      result = ClassifyIntent.run("help", context: { adapter: context_adapter })

      expect(result.status).to eq(:ok)
      expect(result.parsed_output).to eq({ intent: "support" })
    end
  end

  context "when adapter error path" do
    it "returns :adapter_error with trace containing messages and model" do
      error_adapter = Class.new(RubyLLM::Contract::Adapters::Base) do
        def call(**)
          raise StandardError, "connection refused"
        end
      end.new

      result = ClassifyIntent.run("help me", context: { adapter: error_adapter, model: "gpt-4.1-mini" })

      expect(result.status).to eq(:adapter_error)
      expect(result.failed?).to be true
      expect(result.validation_errors).to include("connection refused")
      expect(result.trace[:messages]).to be_an(Array)
      expect(result.trace[:model]).to eq("gpt-4.1-mini")
    end
  end

  context "when prompt has only system/section/rule nodes (no user message)" do
    let(:system_only_step) do
      Class.new(RubyLLM::Contract::Step::Base) do
        input_type RubyLLM::Contract::Types::Hash

        prompt do |input|
          system "You generate tags. Return valid JSON."
          section "CONTEXT", input[:context]
          rule "Return 3-5 tags."
        end

        contract do
          parse :json
          invariant("has tags") { |o| o[:tags].is_a?(Array) && o[:tags].size >= 1 }
        end
      end
    end

    it "succeeds end-to-end without a user node" do
      adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"tags":["ruby","llm"]}')

      result = system_only_step.run({ context: "A Ruby gem for LLM pipelines" }, context: { adapter: adapter })

      expect(result.status).to eq(:ok)
      expect(result.parsed_output[:tags]).to eq(%w[ruby llm])
    end

    it "produces valid messages with no nil content" do
      adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"tags":["x"]}')

      result = system_only_step.run({ context: "test" }, context: { adapter: adapter })

      result.trace[:messages].each do |msg|
        expect(msg[:content]).not_to be_nil, "message with role=#{msg[:role]} has nil content"
        expect(msg[:content].to_s.strip).not_to be_empty, "message with role=#{msg[:role]} has blank content"
      end
    end
  end

  context "when dynamic prompt has nil/blank sections" do
    let(:nullable_step) do
      Class.new(RubyLLM::Contract::Step::Base) do
        input_type RubyLLM::Contract::Types::Hash

        prompt do |input|
          system "Classify."
          section "PRODUCT", input[:product_context]
          section "PAGES", input[:pages_section] if input[:pages_section].to_s.strip != ""
          rule "Return JSON."
          user "Do it now."
        end

        contract do
          parse :json
          invariant("has result") { |o| o[:result].to_s != "" }
        end
      end
    end

    it "skips sections with nil content" do
      adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"result":"ok"}')

      result = nullable_step.run(
        { product_context: nil, pages_section: "" },
        context: { adapter: adapter }
      )

      expect(result.status).to eq(:ok)
      messages = result.trace[:messages]
      messages.each do |msg|
        expect(msg[:content].to_s.strip).not_to be_empty,
                                                "nil/blank content leaked to messages: #{msg.inspect}"
      end
    end

    it "includes sections with actual content" do
      adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"result":"ok"}')

      result = nullable_step.run(
        { product_context: "Acme Corp", pages_section: nil },
        context: { adapter: adapter }
      )

      expect(result.status).to eq(:ok)
      contents = result.trace[:messages].map { |m| m[:content] }.join("\n")
      expect(contents).to include("Acme Corp")
    end
  end

  context "when prompt block raises an exception (e.g. nil access)" do
    let(:crashing_step) do
      Class.new(RubyLLM::Contract::Step::Base) do
        input_type RubyLLM::Contract::Types::Hash

        prompt do |input|
          system "Classify."
          section "DATA", input[:data].upcase # will crash if data is nil
          user "go"
        end

        contract { parse :json }
      end
    end

    it "returns :input_error with descriptive message instead of raw exception" do
      adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"x":1}')

      result = crashing_step.run({ data: nil }, context: { adapter: adapter })

      expect(result.status).to eq(:input_error)
      expect(result.validation_errors.first).to include("Prompt build failed")
    end
  end

  context "with the reference DSL from the spec" do
    it "works end-to-end" do
      adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"intent":"billing"}')

      result = ClassifyIntent.run("I need help with my invoice", context: { adapter: adapter, model: "gpt-4.1-mini" })

      expect(result.status).to eq(:ok)
      expect(result.parsed_output).to eq({ intent: "billing" })
    end
  end
end
