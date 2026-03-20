# frozen_string_literal: true

# Integration spec: longest linear Pipeline chain from the Reddit Promo Planner case
# (docs/ideas/05_real_case_reddit_promo_planner.md)
#
# The real Reddit flow has 7 stages, but includes a diamond dependency
# (DiscoverSubreddits needs output from both TargetAudience and PageContexts)
# and an external API call (Reddit search) between LLM stages.
#
# The longest LINEAR chain of pure LLM steps that works with the current gem:
#
#   1. AnalyzeProduct     — URL → product profile with audience groups
#   2. IdentifySubreddits — product profile → subreddits + sample thread
#   3. ClassifyThread     — thread + context → classified thread with score
#   4. PlanComment        — classified thread → comment plan (approach, tone, key points)
#   5. GenerateComment    — comment plan → final Reddit comment
#
# This uses Pipeline::Base, Pipeline::Trace, timeout, invariants,
# 2-arity invariants, sections, rules, examples, and retry_policy.

RSpec.describe "Reddit Promo Planner — 5-step linear pipeline" do
  before { RubyLLM::Contract.reset_configuration! }

  # ===========================================================================
  # Helper: SequenceAdapter — returns different responses per call
  # This is NOT a gem modification. It's a test helper using the public
  # Adapters::Base interface, which is the intended extension point.
  # ===========================================================================

  let(:sequence_adapter_class) do
    Class.new(RubyLLM::Contract::Adapters::Base) do
      def initialize(responses:)
        super()
        @responses = responses
        @call_index = 0
      end

      def call(messages:, **_options)
        response_content = @responses[@call_index] || @responses.last
        @call_index += 1
        RubyLLM::Contract::Adapters::Response.new(
          content: response_content,
          usage: { input_tokens: 100, output_tokens: 50 }
        )
      end
    end
  end

  # ===========================================================================
  # STEP 1: AnalyzeProduct
  # URL → product profile (description, locale, audience groups)
  # ===========================================================================

  let(:analyze_product) do
    Class.new(RubyLLM::Contract::Step::Base) do
      input_type RubyLLM::Contract::Types::String
      output_type RubyLLM::Contract::Types::Hash

      prompt do
        system "You are a marketing analyst. Analyze the product at the given URL."
        rule "Return JSON with: product_description, locale (ISO 639-1), audience_groups (array)."
        rule "audience_groups must contain at least 2 groups."
        rule "locale must be a 2-letter lowercase code."
        user "{input}"
      end

      contract do
        parse :json
        invariant("has product_description") { |o| o[:product_description].to_s.size > 5 }
        invariant("locale is valid") { |o| o[:locale].to_s.match?(/\A[a-z]{2}\z/) }
        invariant("has audience groups") { |o| o[:audience_groups].is_a?(Array) && o[:audience_groups].size >= 2 }
      end
    end
  end

  # ===========================================================================
  # STEP 2: IdentifySubreddits
  # Product profile → relevant subreddits + sample thread for the pipeline
  # ===========================================================================

  let(:identify_subreddits) do
    Class.new(RubyLLM::Contract::Step::Base) do
      input_type RubyLLM::Contract::Types::Hash
      output_type RubyLLM::Contract::Types::Hash

      prompt do
        system "You are a Reddit marketing researcher."
        rule "Given a product profile, identify relevant subreddits and a representative thread."
        rule "Return JSON with: product_description, locale, subreddits (array), thread (object with title, selftext, subreddit, language)."
        user "{input}"
      end

      contract do
        parse :json
        invariant("has subreddits") { |o| o[:subreddits].is_a?(Array) && !o[:subreddits].empty? }
        invariant("has thread") { |o| o[:thread].is_a?(Hash) && o[:thread][:title].to_s.size > 3 }
        invariant("thread has language") { |o| o.dig(:thread, :language).to_s.size == 2 }
      end
    end
  end

  # ===========================================================================
  # STEP 3: ClassifyThread
  # Thread + product context → classified thread (PROMO/FILLER/SKIP + score)
  # ===========================================================================

  let(:classify_thread) do
    Class.new(RubyLLM::Contract::Step::Base) do
      input_type RubyLLM::Contract::Types::Hash
      output_type RubyLLM::Contract::Types::Hash

      prompt do
        system "You are a thread classifier for Reddit marketing."
        rule "Classify the thread as PROMO, FILLER, or SKIP based on product relevance."
        rule "Return JSON with: thread (original), classification, relevance_score (1-10), reasoning."
        rule "PROMO: relevance_score >= 6. FILLER: 3-5. SKIP: 1-2."
        example input: '{"thread":{"title":"Best invoicing tool?"},"product_description":"invoicing SaaS"}',
                output: '{"classification":"PROMO","relevance_score":9,"reasoning":"Direct product fit"}'
        user "{input}"
      end

      contract do
        parse :json
        invariant("valid classification") { |o| %w[PROMO FILLER SKIP].include?(o[:classification]) }
        invariant("relevance_score in range") { |o| o[:relevance_score].is_a?(Integer) && o[:relevance_score].between?(1, 10) }

        invariant("PROMO score >= 6") do |o|
          o[:classification] != "PROMO" || o[:relevance_score] >= 6
        end

        invariant("SKIP score <= 2") do |o|
          o[:classification] != "SKIP" || o[:relevance_score] <= 2
        end
      end
    end
  end

  # ===========================================================================
  # STEP 4: PlanComment
  # Classified thread → comment plan (approach, tone, key points, link strategy)
  # ===========================================================================

  let(:plan_comment) do
    Class.new(RubyLLM::Contract::Step::Base) do
      input_type RubyLLM::Contract::Types::Hash
      output_type RubyLLM::Contract::Types::Hash

      prompt do
        system "You are a Reddit comment strategist."
        rule "Plan a helpful, non-spammy comment for the classified thread."
        rule "Return JSON with: approach, tone, key_points (array), link_strategy, target_length."
        rule "tone must be one of: casual, professional, empathetic."
        section "GUIDELINES", "Never use aggressive marketing language.\nBe genuinely helpful first.\nMention product naturally."
        user "{input}"
      end

      contract do
        parse :json
        invariant("has approach") { |o| o[:approach].to_s.size > 5 }
        invariant("valid tone") { |o| %w[casual professional empathetic].include?(o[:tone]) }
        invariant("has key_points") { |o| o[:key_points].is_a?(Array) && !o[:key_points].empty? }
        invariant("has link_strategy") { |o| o[:link_strategy].to_s.size > 3 }
      end
    end
  end

  # ===========================================================================
  # STEP 5: GenerateComment
  # Comment plan → final Reddit comment text
  # ===========================================================================

  let(:generate_comment) do
    Class.new(RubyLLM::Contract::Step::Base) do
      input_type RubyLLM::Contract::Types::Hash
      output_type RubyLLM::Contract::Types::Hash

      prompt do
        system "You are a helpful Reddit commenter promoting a SaaS product."
        rule "Write the comment based on the plan."
        rule "Return JSON with: comment (string), word_count (integer)."
        rule "No markdown headers (## or ###)."
        rule "Include product link naturally, maximum once."
        rule "Keep it conversational."
        section "ANTI-SPAM", "Never use: buy now, limited offer, click here, act fast, discount."
        user "{input}"
      end

      contract do
        parse :json

        invariant("comment long enough") { |o| o[:comment].to_s.strip.size > 30 }
        invariant("no markdown headers") { |o| !o[:comment].to_s.match?(/^\#{2,}/) }
        invariant("has word_count") { |o| o[:word_count].is_a?(Integer) && o[:word_count] > 0 }

        invariant("no spam phrases") do |o|
          comment = o[:comment].to_s.downcase
          %w[buy\ now limited\ offer click\ here act\ fast discount].none? { |p| comment.include?(p) }
        end

        invariant("contains a link") do |o|
          o[:comment].to_s.match?(%r{https?://})
        end
      end
    end
  end

  # ===========================================================================
  # Canned responses for each step (realistic LLM output)
  # ===========================================================================

  let(:step1_response) do
    {
      product_description: "InvoiceNinja — open-source invoicing and billing platform for freelancers and small businesses",
      locale: "en",
      audience_groups: ["freelancers", "small business owners", "accountants"]
    }.to_json
  end

  let(:step2_response) do
    {
      product_description: "InvoiceNinja — invoicing platform for freelancers",
      locale: "en",
      subreddits: ["r/smallbusiness", "r/freelance", "r/Entrepreneur"],
      thread: {
        title: "What invoicing tool do you use for your freelance business?",
        selftext: "I've been using spreadsheets but it's getting out of hand. Looking for something affordable that handles recurring invoices and late payment reminders.",
        subreddit: "r/freelance",
        language: "en"
      }
    }.to_json
  end

  let(:step3_response) do
    {
      thread: {
        title: "What invoicing tool do you use for your freelance business?",
        subreddit: "r/freelance",
        language: "en"
      },
      classification: "PROMO",
      relevance_score: 9,
      reasoning: "Thread directly asks for invoicing tool recommendations — perfect fit for InvoiceNinja"
    }.to_json
  end

  let(:step4_response) do
    {
      approach: "Share personal experience with invoicing pain points, then mention InvoiceNinja as the solution that worked",
      tone: "casual",
      key_points: [
        "Empathize with spreadsheet frustration",
        "Mention recurring invoices feature",
        "Highlight late payment reminders",
        "Note it's open-source and affordable"
      ],
      link_strategy: "Drop link naturally after mentioning the tool by name",
      target_length: "medium"
    }.to_json
  end

  let(:step5_response) do
    {
      comment: "I was in the exact same boat — spreadsheets worked until I had more than 10 clients, " \
               "then it became a nightmare tracking who paid and who didn't. I switched to InvoiceNinja " \
               "(https://invoiceninja.com) about a year ago and it's been great. The recurring invoices " \
               "are set-and-forget, and the automatic payment reminders saved me so many awkward \"hey, " \
               "did you get my invoice?\" emails. It's open-source too, so you can self-host if you want " \
               "to keep costs down. Worth checking out!",
      word_count: 89
    }.to_json
  end

  # ===========================================================================
  # INDIVIDUAL STEP TESTS
  # ===========================================================================

  describe "individual steps" do
    it "Step 1: AnalyzeProduct — extracts audience profile from URL" do
      adapter = RubyLLM::Contract::Adapters::Test.new(response: step1_response)
      result = analyze_product.run("https://invoiceninja.com", context: { adapter: adapter })

      expect(result.status).to eq(:ok)
      expect(result.parsed_output[:locale]).to eq("en")
      expect(result.parsed_output[:audience_groups].size).to eq(3)
    end

    it "Step 2: IdentifySubreddits — finds subreddits and sample thread" do
      adapter = RubyLLM::Contract::Adapters::Test.new(response: step2_response)
      input = JSON.parse(step1_response, symbolize_names: true)
      result = identify_subreddits.run(input, context: { adapter: adapter })

      expect(result.status).to eq(:ok)
      expect(result.parsed_output[:subreddits]).to include("r/freelance")
      expect(result.parsed_output[:thread][:title]).to include("invoicing")
    end

    it "Step 3: ClassifyThread — classifies as PROMO with high relevance" do
      adapter = RubyLLM::Contract::Adapters::Test.new(response: step3_response)
      input = JSON.parse(step2_response, symbolize_names: true)
      result = classify_thread.run(input, context: { adapter: adapter })

      expect(result.status).to eq(:ok)
      expect(result.parsed_output[:classification]).to eq("PROMO")
      expect(result.parsed_output[:relevance_score]).to eq(9)
    end

    it "Step 4: PlanComment — creates comment strategy" do
      adapter = RubyLLM::Contract::Adapters::Test.new(response: step4_response)
      input = JSON.parse(step3_response, symbolize_names: true)
      result = plan_comment.run(input, context: { adapter: adapter })

      expect(result.status).to eq(:ok)
      expect(result.parsed_output[:tone]).to eq("casual")
      expect(result.parsed_output[:key_points].size).to eq(4)
    end

    it "Step 5: GenerateComment — produces the final comment" do
      adapter = RubyLLM::Contract::Adapters::Test.new(response: step5_response)
      input = JSON.parse(step4_response, symbolize_names: true)
      result = generate_comment.run(input, context: { adapter: adapter })

      expect(result.status).to eq(:ok)
      expect(result.parsed_output[:comment]).to include("InvoiceNinja")
      expect(result.parsed_output[:comment]).to include("https://invoiceninja.com")
      expect(result.parsed_output[:word_count]).to eq(89)
    end
  end

  # ===========================================================================
  # CONTRACT FAILURES — each step catches its own problems
  # ===========================================================================

  describe "contract enforcement" do
    it "Step 1 rejects invalid locale" do
      bad_response = { product_description: "A tool", locale: "ENGLISH", audience_groups: ["devs", "ops"] }.to_json
      adapter = RubyLLM::Contract::Adapters::Test.new(response: bad_response)
      result = analyze_product.run("https://example.com", context: { adapter: adapter })

      expect(result.status).to eq(:validation_failed)
      expect(result.validation_errors).to include("locale is valid")
    end

    it "Step 3 rejects PROMO with low relevance" do
      bad_response = { classification: "PROMO", relevance_score: 3, reasoning: "Weak fit" }.to_json
      adapter = RubyLLM::Contract::Adapters::Test.new(response: bad_response)
      input = JSON.parse(step2_response, symbolize_names: true)
      result = classify_thread.run(input, context: { adapter: adapter })

      expect(result.status).to eq(:validation_failed)
      expect(result.validation_errors).to include("PROMO score >= 6")
    end

    it "Step 5 rejects spammy comments" do
      spammy = { comment: "BUY NOW at https://example.com - limited offer!", word_count: 10 }.to_json
      adapter = RubyLLM::Contract::Adapters::Test.new(response: spammy)
      input = JSON.parse(step4_response, symbolize_names: true)
      result = generate_comment.run(input, context: { adapter: adapter })

      expect(result.status).to eq(:validation_failed)
      expect(result.validation_errors).to include("no spam phrases")
    end

    it "Step 5 rejects comments without links" do
      no_link = { comment: "I totally recommend checking out some invoicing tools, they helped me a lot with my business!", word_count: 15 }.to_json
      adapter = RubyLLM::Contract::Adapters::Test.new(response: no_link)
      input = JSON.parse(step4_response, symbolize_names: true)
      result = generate_comment.run(input, context: { adapter: adapter })

      expect(result.status).to eq(:validation_failed)
      expect(result.validation_errors).to include("contains a link")
    end
  end

  # ===========================================================================
  # 5-STEP PIPELINE — the full linear chain
  # ===========================================================================

  describe "5-step Pipeline" do
    let(:adapter) do
      sequence_adapter_class.new(responses: [
        step1_response,
        step2_response,
        step3_response,
        step4_response,
        step5_response
      ])
    end

    let(:pipeline) do
      s1 = analyze_product
      s2 = identify_subreddits
      s3 = classify_thread
      s4 = plan_comment
      s5 = generate_comment

      Class.new(RubyLLM::Contract::Pipeline::Base).tap do |p|
        p.step s1, as: :analyze
        p.step s2, as: :subreddits
        p.step s3, as: :classify
        p.step s4, as: :plan
        p.step s5, as: :comment
      end
    end

    it "executes all 5 steps successfully" do
      result = pipeline.run("https://invoiceninja.com", context: { adapter: adapter })

      expect(result.status).to eq(:ok)
      expect(result.outputs_by_step.keys).to eq(%i[analyze subreddits classify plan comment])
    end

    it "final output is the generated comment" do
      result = pipeline.run("https://invoiceninja.com", context: { adapter: adapter })

      comment = result.outputs_by_step[:comment]
      expect(comment[:comment]).to include("InvoiceNinja")
      expect(comment[:comment]).to include("https://invoiceninja.com")
    end

    it "all intermediate outputs are accessible" do
      result = pipeline.run("https://invoiceninja.com", context: { adapter: adapter })

      expect(result.outputs_by_step[:analyze][:locale]).to eq("en")
      expect(result.outputs_by_step[:subreddits][:subreddits]).to include("r/freelance")
      expect(result.outputs_by_step[:classify][:classification]).to eq("PROMO")
      expect(result.outputs_by_step[:plan][:tone]).to eq("casual")
      expect(result.outputs_by_step[:comment][:word_count]).to eq(89)
    end

    it "populates pipeline trace with all 5 step traces" do
      result = pipeline.run("https://invoiceninja.com", context: { adapter: adapter })

      expect(result.trace).to be_a(RubyLLM::Contract::Pipeline::Trace)
      expect(result.trace.trace_id).to be_a(String)
      expect(result.trace.trace_id).not_to be_empty
      expect(result.trace.step_traces.size).to eq(5)
      expect(result.trace.total_latency_ms).to be >= 0
      expect(result.trace.total_usage).to eq({ input_tokens: 500, output_tokens: 250 })
    end

    it "halts on step failure (fail-fast)" do
      # Step 3 returns bad classification → pipeline stops
      bad_adapter = sequence_adapter_class.new(responses: [
        step1_response,
        step2_response,
        { classification: "PROMO", relevance_score: 2, reasoning: "Bad" }.to_json, # fails invariant
        step4_response,
        step5_response
      ])

      result = pipeline.run("https://invoiceninja.com", context: { adapter: bad_adapter })

      expect(result.status).to eq(:validation_failed)
      expect(result.failed_step).to eq(:classify)
      expect(result.outputs_by_step.keys).to eq(%i[analyze subreddits])
      expect(result.trace.step_traces.size).to eq(3) # 2 ok + 1 failed
    end

    it "supports timeout" do
      slow_adapter_class = Class.new(RubyLLM::Contract::Adapters::Base) do
        define_method(:initialize) do |responses:|
          super()
          @responses = responses
          @call_index = 0
        end

        define_method(:call) do |messages:, **_options|
          sleep(0.03) # 30ms per step
          response_content = @responses[@call_index] || @responses.last
          @call_index += 1
          RubyLLM::Contract::Adapters::Response.new(
            content: response_content,
            usage: { input_tokens: 100, output_tokens: 50 }
          )
        end
      end

      slow_adapter = slow_adapter_class.new(responses: [
        step1_response, step2_response, step3_response, step4_response, step5_response
      ])

      # 30ms per step × 5 steps = 150ms total. Timeout at 80ms → should stop after ~2-3 steps
      result = pipeline.run("https://invoiceninja.com",
                            context: { adapter: slow_adapter },
                            timeout_ms: 80)

      expect(result.status).to eq(:timeout)
      expect(result.outputs_by_step.keys.size).to be < 5
      expect(result.trace.total_latency_ms).to be >= 60
    end
  end

  # ===========================================================================
  # EVAL — dataset-based quality check on the comment generation step
  # ===========================================================================

  describe "eval: comment quality dataset" do
    it "evaluates comment generation against a dataset" do
      dataset = RubyLLM::Contract::Eval::Dataset.define do
        add_case "invoicing thread — good comment",
                 input: { approach: "empathize then recommend", tone: "casual", key_points: ["recurring invoices"], link_strategy: "natural mention", target_length: "medium" },
                 expected: { comment: /InvoiceNinja/ }

        add_case "invoicing thread — has link",
                 input: { approach: "share experience", tone: "casual", key_points: ["payment reminders"], link_strategy: "after product mention", target_length: "short" },
                 expected: { comment: %r{https?://} }
      end

      adapter = RubyLLM::Contract::Adapters::Test.new(response: step5_response)

      report = RubyLLM::Contract::Eval::Runner.run(
        step: generate_comment,
        dataset: dataset,
        context: { adapter: adapter }
      )

      expect(report.score).to eq(1.0)
      expect(report.passed?).to be true
    end
  end

  # ===========================================================================
  # 2-ARITY INVARIANTS — cross-validate output against input
  # (e.g., comment language must match thread language)
  # ===========================================================================

  describe "2-arity invariants: output vs input cross-validation" do
    let(:language_aware_comment) do
      Class.new(RubyLLM::Contract::Step::Base) do
        input_type RubyLLM::Contract::Types::Hash
        output_type RubyLLM::Contract::Types::Hash

        prompt do
          system "Write a Reddit comment in {thread_language}."
          rule "Return JSON with comment and detected_language."
          user "Thread: {thread_title}\n\n{thread_selftext}"
        end

        contract do
          parse :json

          invariant("comment not empty") { |o| o[:comment].to_s.strip.size > 10 }

          invariant("language matches thread") do |output, input|
            output[:detected_language] == input[:thread_language]
          end
        end
      end
    end

    it "passes when output language matches input language" do
      adapter = RubyLLM::Contract::Adapters::Test.new(
        response: { comment: "Polecam InvoiceNinja do fakturowania!", detected_language: "pl" }.to_json
      )
      result = language_aware_comment.run(
        { thread_title: "Jaki program do faktur?", thread_selftext: "Szukam narzedzia", thread_language: "pl" },
        context: { adapter: adapter }
      )

      expect(result.status).to eq(:ok)
    end

    it "fails when output language doesn't match input" do
      adapter = RubyLLM::Contract::Adapters::Test.new(
        response: { comment: "I recommend InvoiceNinja for invoicing!", detected_language: "en" }.to_json
      )
      result = language_aware_comment.run(
        { thread_title: "Jaki program do faktur?", thread_selftext: "Szukam narzedzia", thread_language: "pl" },
        context: { adapter: adapter }
      )

      expect(result.status).to eq(:validation_failed)
      expect(result.validation_errors).to include("language matches thread")
    end
  end

  # ===========================================================================
  # RETRY POLICY WITH MODEL ESCALATION
  # Start with cheap model, escalate to expensive on failure
  # ===========================================================================

  describe "retry policy with model escalation" do
    let(:step_with_retry) do
      Class.new(RubyLLM::Contract::Step::Base) do
        input_type RubyLLM::Contract::Types::String
        output_type RubyLLM::Contract::Types::Hash

        prompt do
          system "Classify the thread."
          rule "Return JSON with classification: PROMO, FILLER, or SKIP."
          user "{input}"
        end

        contract do
          parse :json
          invariant("valid classification") { |o| %w[PROMO FILLER SKIP].include?(o[:classification]) }
        end

        retry_policy do
          attempts 3
          escalate "gpt-4.1-nano", "gpt-4.1-mini", "gpt-4.1"
          retry_on :validation_failed, :parse_error
        end
      end
    end

    it "succeeds on first attempt — no escalation needed" do
      adapter = RubyLLM::Contract::Adapters::Test.new(
        response: { classification: "PROMO" }.to_json
      )
      result = step_with_retry.run("Best invoicing tool?", context: { adapter: adapter })

      expect(result.status).to eq(:ok)
      expect(result.parsed_output[:classification]).to eq("PROMO")
    end

    it "retries and escalates model on failure" do
      call_count = 0
      counting_adapter = Class.new(RubyLLM::Contract::Adapters::Base) do
        define_method(:call) do |messages:, **_options|
          call_count += 1
          # First two calls return bad output, third returns good
          content = if call_count < 3
                      { classification: "INVALID" }.to_json
                    else
                      { classification: "PROMO" }.to_json
                    end
          RubyLLM::Contract::Adapters::Response.new(content: content, usage: { input_tokens: 50, output_tokens: 20 })
        end
      end.new

      result = step_with_retry.run("Best invoicing tool?", context: { adapter: counting_adapter })

      expect(result.status).to eq(:ok)
      expect(call_count).to eq(3)
    end

    it "returns last failure after exhausting all attempts" do
      adapter = RubyLLM::Contract::Adapters::Test.new(
        response: { classification: "INVALID" }.to_json
      )
      result = step_with_retry.run("thread", context: { adapter: adapter })

      expect(result.status).to eq(:validation_failed)
      expect(result.trace[:attempts]).to be_a(Array)
      expect(result.trace[:attempts].size).to eq(3)
      expect(result.trace[:attempts].map { |a| a[:model] }).to eq(%w[gpt-4.1-nano gpt-4.1-mini gpt-4.1])
    end

    it "does not retry on :input_error" do
      call_count = 0
      counting_adapter = Class.new(RubyLLM::Contract::Adapters::Base) do
        define_method(:call) do |messages:, **_options|
          call_count += 1
          RubyLLM::Contract::Adapters::Response.new(content: "{}", usage: { input_tokens: 0, output_tokens: 0 })
        end
      end.new

      # Integer input fails input_type validation — should NOT retry
      result = step_with_retry.run(42, context: { adapter: counting_adapter })

      expect(result.status).to eq(:input_error)
      expect(call_count).to eq(0) # adapter never called
    end
  end

  # ===========================================================================
  # PLAIN RUBY CLASS TYPES (GH-9) — input_type String instead of Types::String
  # ===========================================================================

  describe "plain Ruby class types" do
    let(:step_with_plain_types) do
      Class.new(RubyLLM::Contract::Step::Base) do
        input_type String
        output_type Hash

        prompt do
          system "Classify the thread."
          user "{input}"
        end

        contract do
          parse :json
        end
      end
    end

    it "accepts String input with plain class type" do
      adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"classification": "PROMO"}')
      result = step_with_plain_types.run("Best invoicing tool?", context: { adapter: adapter })

      expect(result.status).to eq(:ok)
    end

    it "rejects non-String input" do
      adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"classification": "PROMO"}')
      result = step_with_plain_types.run(42, context: { adapter: adapter })

      expect(result.status).to eq(:input_error)
    end
  end

  # ===========================================================================
  # STEP::TRACE NAMED ACCESSORS (GH-9) — trace.model vs trace[:model]
  # ===========================================================================

  describe "Step::Trace named accessors" do
    it "supports both named and hash-style access" do
      adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"v": 1}')
      s = Class.new(RubyLLM::Contract::Step::Base) do
        input_type RubyLLM::Contract::Types::String
        output_type RubyLLM::Contract::Types::Hash
        prompt { user "{input}" }
        contract { parse :json }
      end

      result = s.run("test", context: { adapter: adapter, model: "gpt-4.1-mini" })

      # Named accessors
      expect(result.trace.model).to eq("gpt-4.1-mini")
      expect(result.trace.latency_ms).to be_a(Integer)
      expect(result.trace.messages).to be_an(Array)
      expect(result.trace.usage).to be_a(Hash)

      # Backward-compatible hash access
      expect(result.trace[:model]).to eq(result.trace.model)
      expect(result.trace[:latency_ms]).to eq(result.trace.latency_ms)

      # Frozen
      expect(result.trace).to be_frozen
    end
  end

  # ===========================================================================
  # UNIFIED CONFIGURE (GH-9) — single block with API key forwarding
  # ===========================================================================

  describe "unified configure block" do
    it "forwards API key to RubyLLM and auto-creates adapter" do
      RubyLLM::Contract.reset_configuration!

      RubyLLM::Contract.configure do |c|
        c.default_model = "gpt-4.1-mini"
      end

      expect(RubyLLM::Contract.configuration.default_adapter).to be_a(RubyLLM::Contract::Adapters::RubyLLM)
      expect(RubyLLM::Contract.configuration.default_model).to eq("gpt-4.1-mini")
    end
  end

  # ===========================================================================
  # VALIDATE ALIAS (GH-8) — validate("desc") { |o| ... } instead of invariant
  # ===========================================================================

  describe "`validate` alias for `invariant`" do
    let(:step_with_validate) do
      Class.new(RubyLLM::Contract::Step::Base) do
        input_type RubyLLM::Contract::Types::String
        output_type RubyLLM::Contract::Types::Hash

        prompt do
          system "Classify the thread."
          user "{input}"
        end

        contract do
          parse :json
          validate("classification must be valid") { |o| %w[PROMO FILLER SKIP].include?(o[:classification]) }
          validate("has reasoning") { |o| o[:reasoning].to_s.size > 3 }
        end
      end
    end

    it "works identically to invariant" do
      adapter = RubyLLM::Contract::Adapters::Test.new(
        response: { classification: "PROMO", reasoning: "Direct product fit" }.to_json
      )
      result = step_with_validate.run("thread", context: { adapter: adapter })

      expect(result.status).to eq(:ok)
    end

    it "reports failures from validate blocks" do
      adapter = RubyLLM::Contract::Adapters::Test.new(
        response: { classification: "INVALID", reasoning: "" }.to_json
      )
      result = step_with_validate.run("thread", context: { adapter: adapter })

      expect(result.status).to eq(:validation_failed)
      expect(result.validation_errors).to include("classification must be valid")
      expect(result.validation_errors).to include("has reasoning")
    end
  end

  # ===========================================================================
  # EVAL_CASE CONVENIENCE (GH-7) — inline single-case eval on any step
  # ===========================================================================

  describe "eval_case convenience method" do
    it "evaluates a single case inline without defining a dataset" do
      adapter = RubyLLM::Contract::Adapters::Test.new(response: step5_response)

      eval_result = generate_comment.eval_case(
        input: { approach: "empathize", tone: "casual", key_points: ["invoicing"], link_strategy: "natural", target_length: "medium" },
        expected: { comment: /InvoiceNinja/ },
        context: { adapter: adapter }
      )

      expect(eval_result[:passed]).to be true
      expect(eval_result[:score]).to eq(1.0)
    end

    it "returns failure for non-matching output" do
      adapter = RubyLLM::Contract::Adapters::Test.new(
        response: { comment: "Check out some tools at https://example.com", word_count: 8 }.to_json
      )

      eval_result = generate_comment.eval_case(
        input: { approach: "recommend", tone: "casual", key_points: [], link_strategy: "direct", target_length: "short" },
        expected: { comment: /InvoiceNinja/ },
        context: { adapter: adapter }
      )

      expect(eval_result[:passed]).to be false
    end
  end
end
