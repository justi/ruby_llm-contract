# frozen_string_literal: true

# =============================================================================
# EXAMPLE 5: Declarative output schema (ruby_llm-schema)
#
# Replace manual invariants with a schema DSL.
# The schema is sent to the LLM provider for structured output enforcement.
#
# With Test adapter: schema defines expectations, parsing is auto-inferred.
# With RubyLLM adapter: schema is also enforced server-side by the provider.
# =============================================================================

require_relative "../lib/ruby_llm/contract"

# =============================================================================
# STEP 1: BEFORE — legacy approach with output_type + manual invariants
#
# Every enum, range, and required field is a separate invariant.
# Works, but verbose. This is what you'd write WITHOUT output_schema.
# =============================================================================

RubyLLM::Contract.configure do |c|
  c.default_adapter = RubyLLM::Contract::Adapters::Test.new(
    response: '{"intent": "sales", "confidence": 0.95}'
  )
end

class ClassifyIntentBefore < RubyLLM::Contract::Step::Base
  input_type  String
  output_type Hash

  prompt do
    system "Classify the user's intent."
    rule "Return JSON only."
    user "{input}"
  end

  validate("must include intent") { |o| o[:intent].to_s != "" }
  validate("intent must be allowed") { |o| %w[sales support billing].include?(o[:intent]) }
  validate("confidence must be a number") { |o| o[:confidence].is_a?(Numeric) }
  validate("confidence in range") { |o| o[:confidence]&.between?(0.0, 1.0) }
end

result = ClassifyIntentBefore.run("I want to buy")
result.status        # => :ok
result.parsed_output # => {intent: "sales", confidence: 0.95}

# =============================================================================
# STEP 2: AFTER — output_schema replaces structural invariants
#
# Same constraints, but declared as a schema.
# No `output_type`, no `parse :json`, no structural invariants.
# =============================================================================

class ClassifyIntentAfter < RubyLLM::Contract::Step::Base
  input_type String

  output_schema do
    string :intent, enum: %w[sales support billing]
    number :confidence, minimum: 0.0, maximum: 1.0
  end

  prompt do
    system "Classify the user's intent."
    rule "Return JSON only."
    user "{input}"
  end
end

result = ClassifyIntentAfter.run("I want to buy")
result.status        # => :ok
result.parsed_output # => {intent: "sales", confidence: 0.95}

# =============================================================================
# STEP 3: Schema + invariants — best of both worlds
#
# Schema handles structure (types, enums, ranges).
# Invariants handle business logic (cross-validation, conditionals).
# =============================================================================

RubyLLM::Contract.configure do |c|
  c.default_adapter = RubyLLM::Contract::Adapters::Test.new(
    response: '{"category": "account", "priority": "urgent", "summary": "Projects disappeared"}'
  )
end

class AnalyzeTicket < RubyLLM::Contract::Step::Base
  input_type RubyLLM::Contract::Types::Hash.schema(
    title: RubyLLM::Contract::Types::String,
    body: RubyLLM::Contract::Types::String
  )

  output_schema do
    string :category, enum: %w[billing technical feature_request account other]
    string :priority, enum: %w[low medium high urgent]
    string :summary, description: "One-sentence summary"
  end

  prompt do
    system "Analyze support tickets."
    rule "Return JSON with category, priority, and summary."
    user "Title: {title}\n\nBody: {body}"
  end

  # Schema handles: valid category, valid priority, summary present
  # Validate handles: cross-validation with input
  validate("urgent requires justification") do |output, input|
    next true unless output[:priority] == "urgent"

    body = input[:body].downcase
    body.include?("data loss") || body.include?("security") || body.include?("deleted")
  end
end

# Justified urgent:
result = AnalyzeTicket.run({
  title: "Projects disappeared",
  body: "All my projects are gone. This is a data loss emergency."
})
result.status # => :ok

# Unjustified urgent:
RubyLLM::Contract.configure do |c|
  c.default_adapter = RubyLLM::Contract::Adapters::Test.new(
    response: '{"category": "technical", "priority": "urgent", "summary": "Page is slow"}'
  )
end

result = AnalyzeTicket.run({
  title: "Slow page",
  body: "Dashboard takes 5 seconds to load."
})
result.status            # => :validation_failed
result.validation_errors # => ["urgent requires justification"]

# =============================================================================
# STEP 4: Complex schema — nested objects, arrays, optional fields
# =============================================================================

RubyLLM::Contract.configure do |c|
  c.default_adapter = RubyLLM::Contract::Adapters::Test.new(
    response: '{"locale": "en", "groups": [{"who": "Freelancers", "pain_points": ["invoicing", "time tracking"]}]}'
  )
end

class ProfileAudience < RubyLLM::Contract::Step::Base
  input_type RubyLLM::Contract::Types::Hash.schema(
    product: RubyLLM::Contract::Types::String,
    market: RubyLLM::Contract::Types::String
  )

  output_schema do
    string :locale, description: "ISO 639-1 language code"
    array :groups, min_items: 1, max_items: 4 do
      string :who, description: "Audience segment name"
      array :pain_points, of: :string, min_items: 1
    end
  end

  prompt do
    system "Generate target audience profiles."
    user "Product: {product}, Market: {market}"
  end
end

result = ProfileAudience.run({ product: "InvoiceApp", market: "US freelancers" })
result.status        # => :ok
result.parsed_output # => {locale: "en", groups: [{who: "Freelancers", pain_points: [...]}]}

# =============================================================================
# STEP 5: Schema is provider-agnostic
#
# With Test adapter: schema auto-infers JSON parsing, no provider enforcement.
# With RubyLLM adapter: schema is ALSO sent to provider (structured output).
# The step definition doesn't change.
# =============================================================================

# To use with a real LLM and get provider-side enforcement:
#
#   RubyLLM.configure { |c| c.openai_api_key = ENV["OPENAI_API_KEY"] }
#   adapter = RubyLLM::Contract::Adapters::RubyLLM.new
#   result = ClassifyIntentAfter.run("I want to buy",
#     context: { adapter: adapter, model: "gpt-4.1-mini" })
#
# The provider enforces the schema — the model MUST return valid JSON
# matching the schema. Parse errors become nearly impossible.

# =============================================================================
# STEP 6: Pipeline with schemas — each step has its own schema
#
# Pipeline + output_schema = fully typed, provider-enforced multi-step flow.
# Each step declares its output schema. Data threads automatically.
# =============================================================================

RubyLLM::Contract.configure do |c|
  c.default_adapter = RubyLLM::Contract::Adapters::Test.new(
    response: '{"category": "billing", "priority": "high", "summary": "Payment page broken"}'
  )
end

class TriageTicket < RubyLLM::Contract::Step::Base
  input_type RubyLLM::Contract::Types::Hash.schema(title: RubyLLM::Contract::Types::String, body: RubyLLM::Contract::Types::String)

  output_schema do
    string :category, enum: %w[billing technical feature_request account other]
    string :priority, enum: %w[low medium high urgent]
    string :summary
  end

  prompt do
    system "Triage support ticket."
    user "Title: {title}\nBody: {body}"
  end
end

class SuggestAction < RubyLLM::Contract::Step::Base
  input_type Hash

  output_schema do
    string :action
    string :team, enum: %w[engineering support billing product]
    boolean :escalate
  end

  prompt do
    system "Suggest action for a triaged ticket."
    user "Category: {category}, Priority: {priority}, Summary: {summary}"
  end
end

class TicketPipeline < RubyLLM::Contract::Pipeline::Base
  step TriageTicket,  as: :triage
  step SuggestAction, as: :action
end

# Both steps share the test adapter, so they get the same canned response.
# With a real LLM, step 2 would get a different response based on step 1's output.
result = TicketPipeline.run(
  { title: "Payment page broken", body: "Error 500 on checkout" }
)
result.ok?                        # => true
result.outputs_by_step[:triage]   # => {category: "billing", priority: "high", summary: "..."}
result.outputs_by_step[:action]   # => same canned response (test adapter)
result.step_results.length        # => 2

# =============================================================================
# SUMMARY
#
# Step 1: BEFORE — output_type + parse :json + structural invariants
# Step 2: AFTER — output_schema replaces all of that
# Step 3: Schema + invariants — schema for structure, invariants for logic
# Step 4: Complex schemas — nested objects, arrays, constraints
# Step 5: Provider-agnostic — same schema works with Test and RubyLLM
# Step 6: Pipeline + schemas — fully typed multi-step composition
#
# output_schema is optional. Existing steps with output_type + invariants
# continue to work unchanged.
# =============================================================================
