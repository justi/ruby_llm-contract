# frozen_string_literal: true

# Tests for every scenario in examples/04_real_llm.rb.
# Uses Adapters::Test (mocked ruby_llm) so these run in CI with zero API calls.
# Each step from the example has at least one test here.

RSpec.describe "examples/04_real_llm.rb scenarios" do
  before { RubyLLM::Contract.reset_configuration! }

  # ===========================================================================
  # STEP 3: ClassifyIntent — system + rules + examples + invariants
  # ===========================================================================

  classify_intent = Class.new(RubyLLM::Contract::Step::Base) do
    input_type  RubyLLM::Contract::Types::String
    output_type RubyLLM::Contract::Types::Hash

    prompt do
      system "You are an intent classifier for a customer support system."
      rule "Return JSON only, no markdown."
      rule "Use exactly one of these intents: sales, support, billing, other."
      rule "Include a confidence score from 0.0 to 1.0."
      example input: "I want to upgrade my plan",
              output: '{"intent": "sales", "confidence": 0.95}'
      example input: "My invoice is wrong",
              output: '{"intent": "billing", "confidence": 0.9}'
      user "{input}"
    end

    contract do
      parse :json
      invariant("must include intent") { |o| o[:intent].to_s != "" }
      invariant("intent must be allowed") { |o| %w[sales support billing other].include?(o[:intent]) }
      invariant("confidence must be a number") { |o| o[:confidence].is_a?(Numeric) }
    end
  end

  describe "Step 3: ClassifyIntent with examples (few-shot)" do
    it "returns :ok with valid intent and confidence" do
      adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"intent": "support", "confidence": 0.92}')
      result = classify_intent.run("I can't log in to my account", context: { adapter: adapter })

      expect(result.status).to eq(:ok)
      expect(result.parsed_output).to eq({ intent: "support", confidence: 0.92 })
    end

    it "renders examples as user/assistant pairs" do
      adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"intent": "support", "confidence": 0.9}')
      result = classify_intent.run("Help me", context: { adapter: adapter })

      messages = result.trace[:messages]
      roles = messages.map { |m| m[:role] }
      # system + 3 rules + example1(user,assistant) + example2(user,assistant) + user
      expect(roles).to eq(%i[system system system system user assistant user assistant user])
    end

    it "rejects unknown intent" do
      adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"intent": "refund", "confidence": 0.8}')
      result = classify_intent.run("I need a refund", context: { adapter: adapter })

      expect(result.status).to eq(:validation_failed)
      expect(result.validation_errors).to include("intent must be allowed")
    end

    it "rejects missing intent" do
      adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"confidence": 0.8}')
      result = classify_intent.run("Hello", context: { adapter: adapter })

      expect(result.status).to eq(:validation_failed)
      expect(result.validation_errors).to include("must include intent")
    end

    it "rejects non-numeric confidence" do
      adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"intent": "sales", "confidence": "high"}')
      result = classify_intent.run("Buy!", context: { adapter: adapter })

      expect(result.status).to eq(:validation_failed)
      expect(result.validation_errors).to include("confidence must be a number")
    end
  end

  # ===========================================================================
  # STEP 4: Trace metadata (model, latency, usage)
  # ===========================================================================

  describe "Step 4: trace metadata" do
    it "includes model, latency_ms, usage, and messages" do
      adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"intent": "billing", "confidence": 0.9}')
      result = classify_intent.run("Invoice issue", context: { adapter: adapter, model: "gpt-4.1-mini" })

      expect(result.trace[:model]).to eq("gpt-4.1-mini")
      expect(result.trace[:latency_ms]).to be_a(Integer)
      expect(result.trace[:usage]).to eq({ input_tokens: 0, output_tokens: 0 })
      expect(result.trace[:messages]).to be_an(Array)
      expect(result.trace[:messages].length).to eq(9)
    end
  end

  # ===========================================================================
  # STEP 5: Model override per call
  # ===========================================================================

  describe "Step 5: model override per call" do
    it "uses the model from context" do
      adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"intent": "billing", "confidence": 0.9}')

      r1 = classify_intent.run("Refund", context: { adapter: adapter, model: "gpt-4.1-mini" })
      r2 = classify_intent.run("Refund", context: { adapter: adapter, model: "gpt-4.1-nano" })

      expect(r1.trace[:model]).to eq("gpt-4.1-mini")
      expect(r2.trace[:model]).to eq("gpt-4.1-nano")
    end
  end

  # ===========================================================================
  # STEP 6: Temperature and max_tokens forwarding
  #
  # We can't verify forwarding with Test adapter (it ignores options),
  # but we verify the step runs cleanly with these options passed.
  # ===========================================================================

  describe "Step 6: generation params" do
    it "accepts temperature and max_tokens in context without error" do
      adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"intent": "sales", "confidence": 0.95}')
      result = classify_intent.run(
        "Enterprise plan?",
        context: { adapter: adapter, model: "gpt-4.1-mini", temperature: 0.0, max_tokens: 50 }
      )

      expect(result.status).to eq(:ok)
    end
  end

  # ===========================================================================
  # STEP 8: StrictClassifier — strict key validation
  # ===========================================================================

  strict_classifier = Class.new(RubyLLM::Contract::Step::Base) do
    input_type  RubyLLM::Contract::Types::String
    output_type RubyLLM::Contract::Types::Hash

    prompt do
      system "Classify the sentiment."
      rule "Return JSON with exactly one key: sentiment."
      rule "Value must be: positive, negative, or neutral."
      user "{input}"
    end

    contract do
      parse :json

      invariant("only allowed keys") do |o|
        o.keys == [:sentiment]
      end

      invariant("sentiment must be valid") do |o|
        %w[positive negative neutral].include?(o[:sentiment])
      end
    end
  end

  describe "Step 8: StrictClassifier" do
    it "passes with exactly one valid key" do
      adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"sentiment": "positive"}')
      result = strict_classifier.run("Amazing!", context: { adapter: adapter })

      expect(result.status).to eq(:ok)
      expect(result.parsed_output).to eq({ sentiment: "positive" })
    end

    it "fails when extra keys are present" do
      adapter = RubyLLM::Contract::Adapters::Test.new(
        response: '{"sentiment": "positive", "confidence": 0.9}'
      )
      result = strict_classifier.run("Amazing!", context: { adapter: adapter })

      expect(result.status).to eq(:validation_failed)
      expect(result.validation_errors).to include("only allowed keys")
    end

    it "fails with non-JSON response" do
      adapter = RubyLLM::Contract::Adapters::Test.new(response: "It's positive!")
      result = strict_classifier.run("Amazing!", context: { adapter: adapter })

      expect(result.status).to eq(:parse_error)
    end
  end

  # ===========================================================================
  # STEP 9: AnalyzeTicket — full power (every feature combined)
  # ===========================================================================

  analyze_ticket = Class.new(RubyLLM::Contract::Step::Base) do
    input_type RubyLLM::Contract::Types::Hash.schema(
      title: RubyLLM::Contract::Types::String,
      body: RubyLLM::Contract::Types::String,
      product: RubyLLM::Contract::Types::String,
      customer_tier: RubyLLM::Contract::Types::String
    )
    output_type RubyLLM::Contract::Types::Hash

    prompt do
      system "You are a support ticket analyzer for a SaaS company."

      rule "Return JSON only, no markdown, no explanation."
      rule "Include all required fields: category, priority, sentiment, summary, suggested_action."
      rule "Categories: billing, technical, feature_request, account, other."
      rule "Priorities: low, medium, high, urgent."
      rule "Sentiments: positive, negative, neutral, frustrated."
      rule "Summary must be one sentence, max 100 characters."

      section "PRODUCT CONTEXT", "Product: {product}\nCustomer tier: {customer_tier}"

      section "PRIORITY RULES",
              "urgent = data loss or security issue\n" \
              "high = service down or billing error\n" \
              "medium = feature broken but workaround exists\n" \
              "low = question, feedback, or cosmetic issue"

      example input: "Title: Can't export CSV\n\nBody: Export button returns 500 error since yesterday.",
              output: '{"category":"technical","priority":"high","sentiment":"frustrated",' \
                      '"summary":"CSV export returns 500 error","suggested_action":"escalate to engineering"}'

      example input: "Title: Dark mode request\n\nBody: Would love dark mode for late night work!",
              output: '{"category":"feature_request","priority":"low","sentiment":"positive",' \
                      '"summary":"Requests dark mode feature","suggested_action":"add to feature backlog"}'

      user "Title: {title}\n\nBody: {body}"
    end

    contract do
      parse :json

      invariant("category must be valid") do |o|
        %w[billing technical feature_request account other].include?(o[:category])
      end

      invariant("priority must be valid") do |o|
        %w[low medium high urgent].include?(o[:priority])
      end

      invariant("sentiment must be valid") do |o|
        %w[positive negative neutral frustrated].include?(o[:sentiment])
      end

      invariant("summary must be present") do |o|
        !o[:summary].to_s.strip.empty?
      end

      invariant("summary must be concise") do |o|
        o[:summary].to_s.length <= 100
      end

      invariant("suggested_action must be present") do |o|
        !o[:suggested_action].to_s.strip.empty?
      end

      invariant("urgent priority requires justification in body") do |output, input|
        next true unless output[:priority] == "urgent"

        body = input[:body].downcase
        body.include?("data loss") || body.include?("security") ||
          body.include?("breach") || body.include?("leak") || body.include?("deleted")
      end
    end
  end

  let(:valid_ticket_input) do
    {
      title: "All my projects disappeared",
      body: "I logged in this morning and all 47 projects are gone. This is a data loss emergency.",
      product: "ProjectHub Pro",
      customer_tier: "enterprise"
    }
  end

  let(:valid_ticket_response) do
    '{"category":"account","priority":"urgent","sentiment":"frustrated",' \
      '"summary":"All projects disappeared after login","suggested_action":"escalate to engineering immediately"}'
  end

  describe "Step 9: AnalyzeTicket — full power" do
    describe "happy path" do
      it "returns :ok with all fields" do
        adapter = RubyLLM::Contract::Adapters::Test.new(response: valid_ticket_response)
        result = analyze_ticket.run(valid_ticket_input, context: { adapter: adapter })

        expect(result.status).to eq(:ok)
        expect(result.parsed_output[:category]).to eq("account")
        expect(result.parsed_output[:priority]).to eq("urgent")
        expect(result.parsed_output[:sentiment]).to eq("frustrated")
        expect(result.parsed_output[:summary]).to be_a(String)
        expect(result.parsed_output[:suggested_action]).to be_a(String)
      end
    end

    describe "prompt structure" do
      it "renders system, rules, sections, examples, and user in correct order" do
        adapter = RubyLLM::Contract::Adapters::Test.new(response: valid_ticket_response)
        result = analyze_ticket.run(valid_ticket_input, context: { adapter: adapter })

        messages = result.trace[:messages]
        roles = messages.map { |m| m[:role] }

        # system(1) + rules(6) + sections(2) + example1(user,assistant) + example2(user,assistant) + user(1)
        expected = %i[system system system system system system system system system
                      user assistant user assistant user]
        expect(roles).to eq(expected)
      end

      it "interpolates Hash input keys into sections" do
        adapter = RubyLLM::Contract::Adapters::Test.new(response: valid_ticket_response)
        result = analyze_ticket.run(valid_ticket_input, context: { adapter: adapter })

        messages = result.trace[:messages]
        product_section = messages.find { |m| m[:content].include?("[PRODUCT CONTEXT]") }
        expect(product_section[:content]).to include("Product: ProjectHub Pro")
        expect(product_section[:content]).to include("Customer tier: enterprise")
      end

      it "interpolates Hash input keys into user message" do
        adapter = RubyLLM::Contract::Adapters::Test.new(response: valid_ticket_response)
        result = analyze_ticket.run(valid_ticket_input, context: { adapter: adapter })

        messages = result.trace[:messages]
        user_msg = messages.last
        expect(user_msg[:role]).to eq(:user)
        expect(user_msg[:content]).to include("Title: All my projects disappeared")
        expect(user_msg[:content]).to include("Body: I logged in this morning")
      end
    end

    describe "category invariant" do
      it "rejects unknown category" do
        bad = '{"category":"spam","priority":"low","sentiment":"neutral","summary":"test","suggested_action":"ignore"}'
        adapter = RubyLLM::Contract::Adapters::Test.new(response: bad)
        result = analyze_ticket.run(valid_ticket_input, context: { adapter: adapter })

        expect(result.status).to eq(:validation_failed)
        expect(result.validation_errors).to include("category must be valid")
      end
    end

    describe "priority invariant" do
      it "rejects unknown priority" do
        bad = '{"category":"technical","priority":"critical","sentiment":"neutral",' \
              '"summary":"test","suggested_action":"fix"}'
        adapter = RubyLLM::Contract::Adapters::Test.new(response: bad)
        result = analyze_ticket.run(valid_ticket_input, context: { adapter: adapter })

        expect(result.status).to eq(:validation_failed)
        expect(result.validation_errors).to include("priority must be valid")
      end
    end

    describe "sentiment invariant" do
      it "rejects unknown sentiment" do
        bad = '{"category":"technical","priority":"low","sentiment":"angry","summary":"test","suggested_action":"fix"}'
        adapter = RubyLLM::Contract::Adapters::Test.new(response: bad)
        result = analyze_ticket.run(valid_ticket_input, context: { adapter: adapter })

        expect(result.status).to eq(:validation_failed)
        expect(result.validation_errors).to include("sentiment must be valid")
      end
    end

    describe "summary invariants" do
      it "rejects empty summary" do
        bad = '{"category":"technical","priority":"low","sentiment":"neutral","summary":"","suggested_action":"fix"}'
        adapter = RubyLLM::Contract::Adapters::Test.new(response: bad)
        result = analyze_ticket.run(valid_ticket_input, context: { adapter: adapter })

        expect(result.status).to eq(:validation_failed)
        expect(result.validation_errors).to include("summary must be present")
      end

      it "rejects summary over 100 characters" do
        long_summary = "a" * 101
        bad = "{\"category\":\"technical\",\"priority\":\"low\"," \
              "\"sentiment\":\"neutral\",\"summary\":\"#{long_summary}\"," \
              "\"suggested_action\":\"fix\"}"
        adapter = RubyLLM::Contract::Adapters::Test.new(response: bad)
        result = analyze_ticket.run(valid_ticket_input, context: { adapter: adapter })

        expect(result.status).to eq(:validation_failed)
        expect(result.validation_errors).to include("summary must be concise")
      end
    end

    describe "suggested_action invariant" do
      it "rejects empty suggested_action" do
        bad = '{"category":"technical","priority":"low","sentiment":"neutral","summary":"test","suggested_action":""}'
        adapter = RubyLLM::Contract::Adapters::Test.new(response: bad)
        result = analyze_ticket.run(valid_ticket_input, context: { adapter: adapter })

        expect(result.status).to eq(:validation_failed)
        expect(result.validation_errors).to include("suggested_action must be present")
      end
    end

    describe "2-arity invariant: urgent priority requires justification" do
      it "allows urgent when body mentions data loss" do
        adapter = RubyLLM::Contract::Adapters::Test.new(response: valid_ticket_response)
        result = analyze_ticket.run(valid_ticket_input, context: { adapter: adapter })

        expect(result.status).to eq(:ok)
      end

      it "rejects urgent when body has no justification" do
        unjustified_input = {
          title: "Page is slow",
          body: "The dashboard takes 5 seconds to load. Please fix.",
          product: "ProjectHub Pro",
          customer_tier: "enterprise"
        }
        urgent = '{"category":"technical","priority":"urgent","sentiment":"frustrated",' \
                 '"summary":"Dashboard is slow","suggested_action":"optimize queries"}'
        adapter = RubyLLM::Contract::Adapters::Test.new(response: urgent)
        result = analyze_ticket.run(unjustified_input, context: { adapter: adapter })

        expect(result.status).to eq(:validation_failed)
        expect(result.validation_errors).to include("urgent priority requires justification in body")
      end

      it "allows non-urgent priority without justification" do
        non_urgent_input = {
          title: "Page is slow",
          body: "The dashboard takes 5 seconds to load.",
          product: "ProjectHub Pro",
          customer_tier: "free"
        }
        high = '{"category":"technical","priority":"high","sentiment":"frustrated",' \
               '"summary":"Dashboard is slow","suggested_action":"optimize queries"}'
        adapter = RubyLLM::Contract::Adapters::Test.new(response: high)
        result = analyze_ticket.run(non_urgent_input, context: { adapter: adapter })

        expect(result.status).to eq(:ok)
      end
    end

    describe "multiple invariant failures collected" do
      it "reports all failures without short-circuiting" do
        bad = '{"category":"spam","priority":"critical","sentiment":"angry","summary":"","suggested_action":""}'
        adapter = RubyLLM::Contract::Adapters::Test.new(response: bad)
        result = analyze_ticket.run(valid_ticket_input, context: { adapter: adapter })

        expect(result.status).to eq(:validation_failed)
        expect(result.validation_errors).to include("category must be valid")
        expect(result.validation_errors).to include("priority must be valid")
        expect(result.validation_errors).to include("sentiment must be valid")
        expect(result.validation_errors).to include("summary must be present")
        expect(result.validation_errors).to include("suggested_action must be present")
        expect(result.validation_errors.length).to be >= 5
      end
    end

    describe "parse error" do
      it "returns :parse_error for non-JSON response" do
        adapter = RubyLLM::Contract::Adapters::Test.new(response: "I'll analyze that ticket for you...")
        result = analyze_ticket.run(valid_ticket_input, context: { adapter: adapter })

        expect(result.status).to eq(:parse_error)
        expect(result.raw_output).to eq("I'll analyze that ticket for you...")
      end
    end

    describe "input validation" do
      it "returns :input_error for missing required fields" do
        adapter = RubyLLM::Contract::Adapters::Test.new(response: valid_ticket_response)
        result = analyze_ticket.run({ title: "test" }, context: { adapter: adapter })

        expect(result.status).to eq(:input_error)
      end
    end
  end
end
