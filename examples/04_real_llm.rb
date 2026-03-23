# frozen_string_literal: true

# =============================================================================
# EXAMPLE 4: Real LLM calls via ruby_llm
#
# All previous examples used Adapters::Test with canned responses.
# This example shows how to connect to a real LLM provider
# (OpenAI, Anthropic, Google, etc.) using Adapters::RubyLLM.
#
# REQUIREMENTS:
#   gem install ruby_llm
#   export OPENAI_API_KEY=sk-...       # or any provider key
#
# RUN:
#   ruby examples/04_real_llm.rb
# =============================================================================

require_relative "../lib/ruby_llm/contract"

# =============================================================================
# STEP 1: Configure — single block, API key auto-creates adapter
#
# Just set your API key. The adapter is created automatically.
# =============================================================================

RubyLLM::Contract.configure do |config|
  config.openai_api_key = ENV.fetch("OPENAI_API_KEY", nil)
  # config.anthropic_api_key = ENV.fetch("ANTHROPIC_API_KEY", nil)
  config.default_model = "gpt-4.1-mini"
end

# =============================================================================
# STEP 3: Define a step — identical to what you'd write with Test adapter
#
# The step doesn't know or care which adapter runs it.
# Same types, same prompt, same contract.
# =============================================================================

class ClassifyIntent < RubyLLM::Contract::Step::Base
  input_type String

  output_schema do
    string :intent, enum: %w[sales support billing other]
    number :confidence, minimum: 0.0, maximum: 1.0
  end

  prompt do
    system "You are an intent classifier for a customer support system."
    rule "Return JSON only, no markdown."
    example input: "I want to upgrade my plan",
            output: '{"intent": "sales", "confidence": 0.95}'
    example input: "My invoice is wrong",
            output: '{"intent": "billing", "confidence": 0.9}'
    user "{input}"
  end
end

# =============================================================================
# STEP 4: Run it — real LLM call, full contract enforcement
#
# The adapter sends the prompt to the real model.
# The contract validates the response just like with Test adapter.
# You get real token usage in the trace.
# =============================================================================

puts "Calling LLM..."
result = ClassifyIntent.run("I can't log in to my account")

puts "Status:  #{result.status}"                       # => :ok
puts "Output:  #{result.parsed_output}"                # => {intent: "support", confidence: 0.95}
puts "Model:   #{result.trace[:model]}"                # => "gpt-4.1-mini"
puts "Latency: #{result.trace[:latency_ms]}ms"         # => 823ms (real network time)
puts "Tokens:  #{result.trace[:usage]}"                # => {input_tokens: 142, output_tokens: 18}

if result.ok?
  puts "Intent:  #{result.parsed_output[:intent]}"
else
  puts "FAILED:  #{result.validation_errors}"
end

# =============================================================================
# STEP 5: Override model per call — A/B test different models
#
# Use context to try different models without changing the step definition.
# =============================================================================

puts "\n--- Comparing models ---"

%w[gpt-4.1-mini gpt-4.1-nano].each do |model|
  r = ClassifyIntent.run("I need a refund", context: { model: model })
  puts "#{model}: #{r.parsed_output} (#{r.trace[:latency_ms]}ms, #{r.trace[:usage]})"
end

# =============================================================================
# STEP 6: Control generation params — temperature, max_tokens
#
# Options are forwarded to ruby_llm. Lower temperature = more deterministic.
# =============================================================================

puts "\n--- With temperature 0 ---"
result = ClassifyIntent.run(
  "Do you have an enterprise plan?",
  context: { model: "gpt-4.1-mini", temperature: 0.0, max_tokens: 50 }
)
puts "Output: #{result.parsed_output}"

# =============================================================================
# STEP 7: Same step, different provider — just change the model
#
# If you have an Anthropic key configured, you can switch with one line.
# The prompt, contract, and invariants are provider-agnostic.
# =============================================================================

# Uncomment if you have an Anthropic key:
# puts "\n--- Anthropic ---"
# result = ClassifyIntent.run(
#   "I want to cancel my subscription",
#   context: { model: "claude-sonnet-4-6" }
# )
# puts "Output: #{result.parsed_output}"

# =============================================================================
# STEP 8: Error handling — what happens when things go wrong
#
# Contract enforcement works the same with real LLM responses.
# If the model returns something invalid, you get a clear error.
# =============================================================================

class StrictClassifier < RubyLLM::Contract::Step::Base
  input_type String

  output_schema do
    string :sentiment, enum: %w[positive negative neutral]
  end

  prompt do
    system "Classify the sentiment."
    user "{input}"
  end
end

puts "\n--- Strict classifier ---"
result = StrictClassifier.run("This product is amazing!", context: { model: "gpt-4.1-mini" })

if result.ok?
  puts "Passed: #{result.parsed_output}"
else
  puts "Failed: #{result.status} — #{result.validation_errors}"
  puts "Raw:    #{result.raw_output}"
end

# =============================================================================
# STEP 9: Full power — every prompt feature combined with a real LLM
#
# This step uses EVERY feature from 00_basics.rb in a single definition:
#   - system message (main instruction)
#   - rules (individual requirements)
#   - sections (labeled context blocks)
#   - examples (few-shot input/output pairs)
#   - Hash input (multi-field auto-interpolation)
#   - 1-arity invariants (validate output alone)
#   - 2-arity invariants (cross-validate output against input)
#
# All of it running against a real LLM.
# =============================================================================

class AnalyzeTicket < RubyLLM::Contract::Step::Base
  input_type RubyLLM::Contract::Types::Hash.schema(
    title: RubyLLM::Contract::Types::String,
    body: RubyLLM::Contract::Types::String,
    product: RubyLLM::Contract::Types::String,
    customer_tier: RubyLLM::Contract::Types::String
  )
  output_type Hash

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

  validate("category must be valid") do |o|
    %w[billing technical feature_request account other].include?(o[:category])
  end

  validate("priority must be valid") do |o|
    %w[low medium high urgent].include?(o[:priority])
  end

  validate("sentiment must be valid") do |o|
    %w[positive negative neutral frustrated].include?(o[:sentiment])
  end

  validate("summary must be present") do |o|
    !o[:summary].to_s.strip.empty?
  end

  validate("summary must be concise") do |o|
    o[:summary].to_s.length <= 100
  end

  validate("suggested_action must be present") do |o|
    !o[:suggested_action].to_s.strip.empty?
  end

  # 2-arity: cross-validate output against input
  validate("urgent priority requires justification in body") do |output, input|
    next true unless output[:priority] == "urgent"

    body = input[:body].downcase
    body.include?("data loss") || body.include?("security") ||
      body.include?("breach") || body.include?("leak") || body.include?("deleted")
  end
end

puts "\n--- Full power: AnalyzeTicket ---"

result = AnalyzeTicket.run(
  {
    title: "All my projects disappeared",
    body: "I logged in this morning and all 47 projects are gone. This is a data loss emergency. " \
          "I have a client demo in 2 hours.",
    product: "ProjectHub Pro",
    customer_tier: "enterprise"
  },
  context: { model: "gpt-4.1-mini", temperature: 0.0 }
)

puts "Status:   #{result.status}"
puts "Category: #{result.parsed_output&.dig(:category)}"
puts "Priority: #{result.parsed_output&.dig(:priority)}"
puts "Sentiment:#{result.parsed_output&.dig(:sentiment)}"
puts "Summary:  #{result.parsed_output&.dig(:summary)}"
puts "Action:   #{result.parsed_output&.dig(:suggested_action)}"
puts "Latency:  #{result.trace[:latency_ms]}ms"
puts "Tokens:   #{result.trace[:usage]}"

puts "ERRORS:   #{result.validation_errors}" if result.failed?

# =============================================================================
# STEP 10: Full power — Pipeline + output_schema + invariants + real LLM
#
# This combines everything: 3-step pipeline where each step has its own
# output_schema (provider-enforced), cross-validation invariants,
# and real LLM calls. If any step hallucinates, execution stops.
#
# Use case: meeting transcript → follow-up email
#   Step 1 (listener): extract decisions + action items
#   Step 2 (critic): flag vague owners/deadlines
#   Step 3 (writer): generate send-ready follow-up email
# =============================================================================

class ExtractMeetingItems < RubyLLM::Contract::Step::Base
  input_type String

  output_schema do
    array :decisions do
      string :id
      string :description
      string :made_by
    end
    array :action_items do
      string :id
      string :task
      string :owner
      string :deadline
    end
  end

  prompt do
    system "Extract decisions and action items from a meeting transcript."
    rule "Only include decisions explicitly stated, never infer."
    rule "Assign sequential IDs: D1, D2... for decisions, A1, A2... for action items."
    user "{input}"
  end
end

class AnalyzeAmbiguities < RubyLLM::Contract::Step::Base
  input_type Hash

  output_schema do
    array :decisions do
      string :id
      string :description
      string :made_by
    end
    array :action_items do
      string :id
      string :task
      string :owner
      string :deadline
    end
    array :analyses do
      string :action_item_id
      string :status, enum: %w[clear ambiguous]
      array :issues do
        string :field, enum: %w[owner deadline scope]
        string :problem
        string :clarification_question
      end
    end
  end

  prompt do
    system "Review action items for completeness. Flag vague owners, missing deadlines, unclear scope."
    rule "Pass through the original decisions and action_items unchanged."
    rule "Add an analyses array with one entry per action item."
    user "Decisions: {decisions}\n\nAction items: {action_items}"
  end

  # Cross-validate: every action item from step 1 must be analyzed
  validate("all action items analyzed") do |output, input|
    output[:analyses].map { |a| a[:action_item_id] }.sort ==
      input[:action_items].map { |a| a[:id] }.sort
  end
end

class GenerateMeetingEmail < RubyLLM::Contract::Step::Base
  input_type Hash

  output_schema do
    string :subject
    string :body
  end

  prompt do
    system "Write a professional follow-up email. List decisions, clear action items " \
           "with owners and deadlines, and embed clarification questions for ambiguous items."
    user "Decisions: {decisions}\nAction items: {action_items}\nAnalyses: {analyses}"
  end

  validate("subject must be concise") { |o| o[:subject].length <= 80 }
  validate("body must not be empty") { |o| !o[:body].to_s.strip.empty? }
end

class MeetingFollowUpPipeline < RubyLLM::Contract::Pipeline::Base
  step ExtractMeetingItems,  as: :extract
  step AnalyzeAmbiguities,   as: :analyze
  step GenerateMeetingEmail, as: :email
end

transcript = <<~TRANSCRIPT
  Sarah: Let's go with the new pricing model starting Q3.
  Tom: I'll update the billing system... at some point.
  Sarah: Someone should notify the sales team about the changes.
  Tom: Also, we need to migrate the legacy accounts. Maria, can you handle that?
  Maria: Sure, I'll look into it.
TRANSCRIPT

puts "\n--- Full power: Pipeline + Schema + Invariants + Real LLM ---"
result = MeetingFollowUpPipeline.run(transcript,
                                     context: { model: "gpt-4.1-mini", temperature: 0.0 })

puts "Pipeline status: #{result.status}"
puts "Steps run:       #{result.step_results.length}"

if result.ok?
  puts "\nExtracted:  #{result.outputs_by_step[:extract][:decisions]&.length} decisions, " \
       "#{result.outputs_by_step[:extract][:action_items]&.length} action items"

  ambiguous = result.outputs_by_step[:analyze][:analyses]&.select { |a| a[:status] == "ambiguous" }
  puts "Ambiguous:  #{ambiguous&.length} items need clarification"
  puts "Email subj: #{result.outputs_by_step[:email][:subject]}"
else
  puts "FAILED at:  #{result.failed_step}"
  failed = result.step_results.last[:result]
  puts "Errors:     #{failed.validation_errors}"
end

# =============================================================================
# SUMMARY
#
# 1. Configure ruby_llm (API keys)
# 2. Set adapter: Adapters::RubyLLM.new
# 3. Define steps exactly as before (types, prompt, contract)
# 4. Run — real LLM call with full contract enforcement
# 5. Override model/temperature/max_tokens per call via context
# 6. Switch providers by changing the model name — everything else stays
# 7. Combine ALL features in a single step: system, rules, sections,
#    examples, hash input, 1-arity + 2-arity invariants
# 8. Error handling — contract enforcement with real LLM responses
# 9. Full power single step — AnalyzeTicket with every feature
# 10. Full power pipeline — 3 steps, schemas, invariants, real LLM
#
# The step definition is always provider-agnostic.
# Swap adapters between Test (specs) and RubyLLM (production).
# =============================================================================
