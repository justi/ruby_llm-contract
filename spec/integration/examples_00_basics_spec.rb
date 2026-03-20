# frozen_string_literal: true

# Tests for every scenario in examples/00_basics.rb.
# Each step from the tutorial has at least one test here.

RSpec.describe "examples/00_basics.rb scenarios" do
  before { RubyLLM::Contract.reset_configuration! }

  # ===========================================================================
  # STEP 1: Simplest possible step — user-only prompt
  # ===========================================================================

  step1 = Class.new(RubyLLM::Contract::Step::Base) do
    input_type  RubyLLM::Contract::Types::String
    output_type RubyLLM::Contract::Types::Hash

    prompt do
      user "Classify the sentiment of this text as positive, negative, or neutral. Return JSON.\n\n{input}"
    end

    contract do
      parse :json
    end
  end

  describe "Step 1: plain string prompt" do
    it "returns :ok with parsed JSON" do
      adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"sentiment": "positive"}')
      result = step1.run("I love this product!", context: { adapter: adapter })

      expect(result.status).to eq(:ok)
      expect(result.parsed_output).to eq({ sentiment: "positive" })
    end
  end

  # ===========================================================================
  # STEP 2: system + user — separate instructions from data
  # ===========================================================================

  step2 = Class.new(RubyLLM::Contract::Step::Base) do
    input_type  RubyLLM::Contract::Types::String
    output_type RubyLLM::Contract::Types::Hash

    prompt do
      system "Classify the sentiment of the user's text. Return JSON with a 'sentiment' key."
      user "{input}"
    end

    contract do
      parse :json
    end
  end

  describe "Step 2: system + user" do
    it "returns :ok with parsed JSON" do
      adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"sentiment": "positive"}')
      result = step2.run("I love this product!", context: { adapter: adapter })

      expect(result.status).to eq(:ok)
      expect(result.parsed_output).to eq({ sentiment: "positive" })
    end

    it "renders system and user as separate messages" do
      adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"sentiment": "positive"}')
      result = step2.run("I love this product!", context: { adapter: adapter })

      messages = result.trace[:messages]
      expect(messages[0]).to eq({ role: :system, content: "Classify the sentiment of the user's text. Return JSON with a 'sentiment' key." })
      expect(messages[1]).to eq({ role: :user, content: "I love this product!" })
    end
  end

  # ===========================================================================
  # STEP 3: rules — requirements as a list
  # ===========================================================================

  step3 = Class.new(RubyLLM::Contract::Step::Base) do
    input_type  RubyLLM::Contract::Types::String
    output_type RubyLLM::Contract::Types::Hash

    prompt do
      system "You are a sentiment classifier."
      rule "Return JSON only."
      rule "Use exactly one of: positive, negative, neutral."
      rule "Include a confidence score from 0.0 to 1.0."
      user "{input}"
    end

    contract do
      parse :json
    end
  end

  describe "Step 3: rules" do
    it "returns :ok with sentiment and confidence" do
      adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"sentiment": "positive", "confidence": 0.95}')
      result = step3.run("I love this product!", context: { adapter: adapter })

      expect(result.status).to eq(:ok)
      expect(result.parsed_output).to eq({ sentiment: "positive", confidence: 0.95 })
    end

    it "renders each rule as a separate system message" do
      adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"sentiment": "positive", "confidence": 0.95}')
      result = step3.run("I love this product!", context: { adapter: adapter })

      messages = result.trace[:messages]
      expect(messages.count { |m| m[:role] == :system }).to eq(4) # system + 3 rules
    end
  end

  # ===========================================================================
  # STEP 4: invariants — output validation
  # ===========================================================================

  step4 = Class.new(RubyLLM::Contract::Step::Base) do
    input_type  RubyLLM::Contract::Types::String
    output_type RubyLLM::Contract::Types::Hash

    prompt do
      system "You are a sentiment classifier."
      rule "Return JSON only."
      rule "Use exactly one of: positive, negative, neutral."
      rule "Include a confidence score from 0.0 to 1.0."
      user "{input}"
    end

    contract do
      parse :json

      invariant("sentiment must be valid") do |o|
        %w[positive negative neutral].include?(o[:sentiment])
      end

      invariant("confidence must be between 0 and 1") do |o|
        o[:confidence].is_a?(Numeric) && o[:confidence].between?(0.0, 1.0)
      end
    end
  end

  describe "Step 4: invariants" do
    it "returns :ok when output passes all invariants" do
      adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"sentiment": "positive", "confidence": 0.95}')
      result = step4.run("I love this product!", context: { adapter: adapter })

      expect(result.status).to eq(:ok)
      expect(result.parsed_output).to eq({ sentiment: "positive", confidence: 0.95 })
    end

    it "returns :validation_failed when model returns bad values" do
      adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"sentiment": "maybe", "confidence": 2.5}')
      result = step4.run("I love this product!", context: { adapter: adapter })

      expect(result.status).to eq(:validation_failed)
      expect(result.validation_errors).to contain_exactly(
        "sentiment must be valid",
        "confidence must be between 0 and 1"
      )
    end

    it "returns :parse_error when model returns non-JSON" do
      adapter = RubyLLM::Contract::Adapters::Test.new(response: "I think it's positive")
      result = step4.run("I love this product!", context: { adapter: adapter })

      expect(result.status).to eq(:parse_error)
      expect(result.validation_errors.first).to match(/Failed to parse JSON/)
    end
  end

  # ===========================================================================
  # STEP 5: examples — few-shot
  # ===========================================================================

  step5 = Class.new(RubyLLM::Contract::Step::Base) do
    input_type  RubyLLM::Contract::Types::String
    output_type RubyLLM::Contract::Types::Hash

    prompt do
      system "You are a sentiment classifier."
      rule "Return JSON only."
      rule "Use exactly one of: positive, negative, neutral."
      rule "Include a confidence score from 0.0 to 1.0."
      example input: "This is terrible", output: '{"sentiment": "negative", "confidence": 0.9}'
      example input: "It works fine I guess", output: '{"sentiment": "neutral", "confidence": 0.6}'
      user "{input}"
    end

    contract do
      parse :json

      invariant("sentiment must be valid") do |o|
        %w[positive negative neutral].include?(o[:sentiment])
      end
    end
  end

  describe "Step 5: examples (few-shot)" do
    it "returns :ok with parsed output" do
      adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"sentiment": "positive", "confidence": 0.92}')
      result = step5.run("I love this product!", context: { adapter: adapter })

      expect(result.status).to eq(:ok)
      expect(result.parsed_output).to eq({ sentiment: "positive", confidence: 0.92 })
    end

    it "renders examples as user/assistant pairs in messages" do
      adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"sentiment": "positive", "confidence": 0.92}')
      result = step5.run("I love this product!", context: { adapter: adapter })

      messages = result.trace[:messages]
      roles = messages.map { |m| m[:role] }
      # system, 3x rule, example1 user, example1 assistant, example2 user, example2 assistant, user
      expect(roles).to eq(%i[system system system system user assistant user assistant user])
    end
  end

  # ===========================================================================
  # STEP 6: sections — labeled context blocks (heredoc replacement)
  # ===========================================================================

  step6 = Class.new(RubyLLM::Contract::Step::Base) do
    input_type  RubyLLM::Contract::Types::String
    output_type RubyLLM::Contract::Types::Hash

    prompt do
      system "You are a sentiment classifier for customer support."
      rule "Return JSON with sentiment, confidence, and reason."
      section "CONTEXT", "We sell software for freelancers."
      section "SCORING GUIDE",
              "negative = complaint or frustration\npositive = praise or thanks\nneutral = question or factual statement"
      user "Classify this: {input}"
    end

    contract do
      parse :json

      invariant("sentiment must be valid") do |o|
        %w[positive negative neutral].include?(o[:sentiment])
      end
    end
  end

  describe "Step 6: sections (heredoc replacement)" do
    it "returns :ok with parsed output" do
      adapter = RubyLLM::Contract::Adapters::Test.new(
        response: '{"sentiment": "negative", "confidence": 0.85, "reason": "product complaint"}'
      )
      result = step6.run("Your billing page is broken again!", context: { adapter: adapter })

      expect(result.status).to eq(:ok)
      expect(result.parsed_output).to eq({ sentiment: "negative", confidence: 0.85, reason: "product complaint" })
    end

    it "renders sections as labeled system messages" do
      adapter = RubyLLM::Contract::Adapters::Test.new(
        response: '{"sentiment": "negative", "confidence": 0.85, "reason": "product complaint"}'
      )
      result = step6.run("Your billing page is broken!", context: { adapter: adapter })

      messages = result.trace[:messages]
      expect(messages[2]).to eq({ role: :system, content: "[CONTEXT]\nWe sell software for freelancers." })
      expect(messages[3][:content]).to start_with("[SCORING GUIDE]\n")
      expect(messages[4]).to eq({ role: :user, content: "Classify this: Your billing page is broken!" })
    end
  end

  # ===========================================================================
  # STEP 7: Hash input — multiple fields with auto-interpolation
  # ===========================================================================

  step7 = Class.new(RubyLLM::Contract::Step::Base) do
    input_type RubyLLM::Contract::Types::Hash.schema(
      title: RubyLLM::Contract::Types::String,
      body: RubyLLM::Contract::Types::String,
      language: RubyLLM::Contract::Types::String
    )
    output_type RubyLLM::Contract::Types::Hash

    prompt do
      system "You classify customer support tickets."
      rule "Return JSON with category and priority."
      rule "Respond in {language}."
      rule "Categories: billing, technical, feature_request, other."
      rule "Priorities: low, medium, high, urgent."
      user "Title: {title}\n\nBody: {body}"
    end

    contract do
      parse :json

      invariant("category must be valid") do |o|
        %w[billing technical feature_request other].include?(o[:category])
      end

      invariant("priority must be valid") do |o|
        %w[low medium high urgent].include?(o[:priority])
      end
    end
  end

  describe "Step 7: Hash input with auto-interpolation" do
    it "returns :ok with parsed output" do
      adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"category": "billing", "priority": "high"}')
      result = step7.run(
        { title: "Can't update credit card", body: "Payment page gives error 500", language: "en" },
        context: { adapter: adapter }
      )

      expect(result.status).to eq(:ok)
      expect(result.parsed_output).to eq({ category: "billing", priority: "high" })
    end

    it "interpolates Hash keys into prompt templates" do
      adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"category": "billing", "priority": "high"}')
      result = step7.run(
        { title: "Can't update credit card", body: "Payment page gives error 500", language: "en" },
        context: { adapter: adapter }
      )

      messages = result.trace[:messages]
      rule_msg = messages.find { |m| m[:content].include?("Respond in") }
      expect(rule_msg[:content]).to eq("Respond in en.")

      user_msg = messages.find { |m| m[:role] == :user }
      expect(user_msg[:content]).to eq("Title: Can't update credit card\n\nBody: Payment page gives error 500")
    end
  end

  # ===========================================================================
  # STEP 8: 2-arity invariants — validate output against input
  # ===========================================================================

  step8 = Class.new(RubyLLM::Contract::Step::Base) do
    input_type RubyLLM::Contract::Types::Hash.schema(
      text: RubyLLM::Contract::Types::String,
      target_lang: RubyLLM::Contract::Types::String
    )
    output_type RubyLLM::Contract::Types::Hash

    prompt do
      system "Translate the text to the target language."
      rule "Return JSON with translation, source_lang, and target_lang."
      user "Translate to {target_lang}: {text}"
    end

    contract do
      parse :json

      invariant("translation must not be empty") do |o|
        o[:translation].to_s.strip.length > 0
      end

      invariant("target_lang must match requested language") do |output, input|
        output[:target_lang] == input[:target_lang]
      end
    end
  end

  describe "Step 8: 2-arity invariants" do
    it "returns :ok when output matches input" do
      adapter = RubyLLM::Contract::Adapters::Test.new(
        response: '{"translation": "Bonjour le monde", "source_lang": "en", "target_lang": "fr"}'
      )
      result = step8.run({ text: "Hello world", target_lang: "fr" }, context: { adapter: adapter })

      expect(result.status).to eq(:ok)
      expect(result.parsed_output).to eq({ translation: "Bonjour le monde", source_lang: "en", target_lang: "fr" })
    end

    it "returns :validation_failed when model returns wrong target language" do
      adapter = RubyLLM::Contract::Adapters::Test.new(
        response: '{"translation": "Hola mundo", "source_lang": "en", "target_lang": "es"}'
      )
      result = step8.run({ text: "Hello world", target_lang: "fr" }, context: { adapter: adapter })

      expect(result.status).to eq(:validation_failed)
      expect(result.validation_errors).to include("target_lang must match requested language")
    end
  end

  # ===========================================================================
  # STEP 9: Context override — per-run adapter and model
  # ===========================================================================

  describe "Step 9: context override" do
    it "uses global defaults" do
      RubyLLM::Contract.configure do |c|
        c.default_adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"sentiment": "positive"}')
        c.default_model = "gpt-4.1-mini"
      end

      result = step1.run("I love this product!")

      expect(result.status).to eq(:ok)
      expect(result.trace[:model]).to eq("gpt-4.1-mini")
    end

    it "overrides adapter and model per call" do
      RubyLLM::Contract.configure do |c|
        c.default_adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"sentiment": "positive"}')
        c.default_model = "gpt-4.1-mini"
      end

      other_adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"sentiment": "neutral"}')
      result = step1.run("I love this product!", context: { adapter: other_adapter, model: "gpt-5" })

      expect(result.status).to eq(:ok)
      expect(result.parsed_output).to eq({ sentiment: "neutral" })
      expect(result.trace[:model]).to eq("gpt-5")
    end
  end

  # ===========================================================================
  # STEP 10: StepResult — everything you get back
  # ===========================================================================

  describe "Step 10: StepResult" do
    it "exposes all fields on success" do
      adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"sentiment": "positive", "confidence": 0.92}')
      result = step4.run("I love this product!", context: { adapter: adapter, model: "gpt-4.1-mini" })

      expect(result.status).to eq(:ok)
      expect(result.ok?).to be true
      expect(result.failed?).to be false
      expect(result.raw_output).to eq('{"sentiment": "positive", "confidence": 0.92}')
      expect(result.parsed_output).to eq({ sentiment: "positive", confidence: 0.92 })
      expect(result.validation_errors).to be_empty
      expect(result.trace[:model]).to eq("gpt-4.1-mini")
      expect(result.trace[:latency_ms]).to be_a(Integer)
      expect(result.trace[:messages]).to be_an(Array)
    end

    it "exposes all fields on failure" do
      adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"sentiment": "maybe"}')
      result = step4.run("I love this product!", context: { adapter: adapter })

      expect(result.status).to eq(:validation_failed)
      expect(result.ok?).to be false
      expect(result.failed?).to be true
      expect(result.raw_output).to eq('{"sentiment": "maybe"}')
      expect(result.parsed_output).to eq({ sentiment: "maybe" })
      expect(result.validation_errors).to contain_exactly(
        "sentiment must be valid",
        "confidence must be between 0 and 1"
      )
    end
  end
end
