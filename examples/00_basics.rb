# frozen_string_literal: true

# =============================================================================
# EXAMPLE 0: From zero to ruby_llm-contract
#
# Starting from the simplest case — a plain string prompt —
# and adding one layer at a time.
# =============================================================================

require_relative "../lib/ruby_llm/contract"

# Setup: test adapter returns canned responses (no real LLM needed)
RubyLLM::Contract.configure do |config|
  config.default_adapter = RubyLLM::Contract::Adapters::Test.new(
    response: '{"sentiment": "positive"}'
  )
end

# =============================================================================
# STEP 1: Simplest possible step — plain string prompt
#
# BEFORE (typical Rails code):
#
#   prompt = "Classify the sentiment of this text as positive, negative, or neutral. Return JSON."
#   response = OpenAI::Client.new.chat(messages: [{role: "user", content: prompt + "\n\n" + text}])
#   JSON.parse(response.dig("choices", 0, "message", "content"))
#
# Or with ruby_llm (one-liner, but still no validation):
#
#   RubyLLM.chat.ask("Classify the sentiment: #{text}")
#
# PROBLEM: no validation, no types, no trace, no structure
# =============================================================================

# Option A: with output_schema (recommended — simplest)
class SimpleSentiment < RubyLLM::Contract::Step::Base
  input_type String    # plain Ruby class works!

  output_schema do
    string :sentiment
  end

  prompt do
    user "Classify the sentiment of this text as positive, negative, or neutral. Return JSON.\n\n{input}"
  end
end

result = SimpleSentiment.run("I love this product!")
result.status        # => :ok
result.parsed_output # => {sentiment: "positive"}

# Option B: with output_type (plain Ruby class — JSON parsing is implicit for Hash)
class SimpleSentimentDryTypes < RubyLLM::Contract::Step::Base
  input_type  String
  output_type Hash

  prompt do
    user "Classify the sentiment of this text as positive, negative, or neutral. Return JSON.\n\n{input}"
  end
end

result = SimpleSentimentDryTypes.run("I love this product!")
result.status        # => :ok
result.parsed_output # => {sentiment: "positive"}

# =============================================================================
# STEP 2: Add system message — separate instructions from data
#
# BEFORE:
#   Everything in one string — instructions and data mixed together
#
# AFTER:
#   system = instructions (constant)
#   user = data (variable)
# =============================================================================

class SentimentWithSystem < RubyLLM::Contract::Step::Base
  input_type String

  output_schema do
    string :sentiment
  end

  prompt do
    system "Classify the sentiment of the user's text."
    user "{input}"
  end
end

result = SentimentWithSystem.run("I love this product!")
result.status        # => :ok
result.parsed_output # => {sentiment: "positive"}

# =============================================================================
# STEP 3: Add rules — clear instructions for the model
#
# Rules are individual requirements. One rule per concern.
# Much clearer than a single wall of text.
# =============================================================================

RubyLLM::Contract.configure do |c|
  c.default_adapter = RubyLLM::Contract::Adapters::Test.new(
    response: '{"sentiment": "positive", "confidence": 0.95}'
  )
end

class SentimentWithRules < RubyLLM::Contract::Step::Base
  input_type String

  output_schema do
    string :sentiment, enum: %w[positive negative neutral]
    number :confidence, minimum: 0.0, maximum: 1.0
  end

  prompt do
    system "You are a sentiment classifier."
    rule "Return JSON only."
    rule "Use exactly one of: positive, negative, neutral."
    rule "Include a confidence score from 0.0 to 1.0."
    user "{input}"
  end
end

result = SentimentWithRules.run("I love this product!")
result.status        # => :ok
result.parsed_output # => {sentiment: "positive", confidence: 0.95}

# =============================================================================
# STEP 4: Add invariants — custom business logic on top of schema
#
# Schema handles structure (enums, ranges). Invariants handle logic
# that schema can't express: conditional rules, cross-field checks, etc.
# =============================================================================

class SentimentValidated < RubyLLM::Contract::Step::Base
  input_type String

  output_schema do
    string :sentiment, enum: %w[positive negative neutral]
    number :confidence, minimum: 0.0, maximum: 1.0
  end

  prompt do
    system "You are a sentiment classifier."
    rule "Return JSON only."
    rule "Use exactly one of: positive, negative, neutral."
    rule "Include a confidence score from 0.0 to 1.0."
    user "{input}"
  end

  # Schema already enforces enum + range. Validate adds custom logic:
  validate("high confidence required for extreme sentiments") do |o|
    next true unless %w[positive negative].include?(o[:sentiment])

    o[:confidence] >= 0.7
  end
end

# Happy path:
result = SentimentValidated.run("I love this product!")
result.status        # => :ok
result.parsed_output # => {sentiment: "positive", confidence: 0.95}

# Model returns low confidence for extreme sentiment — invariant catches it:
RubyLLM::Contract.configure do |c|
  c.default_adapter = RubyLLM::Contract::Adapters::Test.new(
    response: '{"sentiment": "positive", "confidence": 0.3}'
  )
end

result = SentimentValidated.run("I love this product!")
result.status            # => :validation_failed
result.validation_errors # => ["high confidence required for extreme sentiments"]

# Model returns non-JSON:
RubyLLM::Contract.configure do |c|
  c.default_adapter = RubyLLM::Contract::Adapters::Test.new(
    response: "I think it's positive"
  )
end

result = SentimentValidated.run("I love this product!")
result.status            # => :parse_error
result.validation_errors # => ["Failed to parse JSON: ..."]

# =============================================================================
# STEP 5: Add examples — show the model what you expect
#
# Few-shot: provide example input → output pairs.
# The model better understands the expected format.
# =============================================================================

RubyLLM::Contract.configure do |c|
  c.default_adapter = RubyLLM::Contract::Adapters::Test.new(
    response: '{"sentiment": "positive", "confidence": 0.92}'
  )
end

class SentimentWithExample < RubyLLM::Contract::Step::Base
  input_type String

  output_schema do
    string :sentiment, enum: %w[positive negative neutral]
    number :confidence, minimum: 0.0, maximum: 1.0
  end

  prompt do
    system "You are a sentiment classifier."
    rule "Return JSON only."
    rule "Use exactly one of: positive, negative, neutral."
    rule "Include a confidence score from 0.0 to 1.0."
    example input: "This is terrible", output: '{"sentiment": "negative", "confidence": 0.9}'
    example input: "It works fine I guess", output: '{"sentiment": "neutral", "confidence": 0.6}'
    user "{input}"
  end
end

result = SentimentWithExample.run("I love this product!")
result.status        # => :ok
result.parsed_output # => {sentiment: "positive", confidence: 0.92}

# =============================================================================
# STEP 6: Sections — replace heredoc string with structured AST
#
# BEFORE (typical heredoc prompt — one big string):
#
#   prompt = <<~PROMPT                                          # AFTER:
#     You are a sentiment classifier for customer support.      # system "You are a sentiment classifier for customer support."
#     Return JSON with sentiment, confidence, and reason.       # rule "Return JSON with sentiment, confidence, and reason."
#                                                               #
#     [CONTEXT]                                                 # section "CONTEXT",
#     We sell software for freelancers.                         #   "We sell software for freelancers."
#                                                               #
#     [SCORING GUIDE]                                           # section "SCORING GUIDE",
#     negative = complaint or frustration                       #   "negative = complaint or frustration\n
#     positive = praise or thanks                               #    positive = praise or thanks\n
#     neutral = question or factual statement                   #    neutral = question or factual statement"
#                                                               #
#     Classify this: #{text}                                    # user "Classify this: {input}"
#   PROMPT                                                      #
#
# PROBLEM: one big string — can't reorder, diff, or reuse individual sections
# AFTER: each part is a separate node in the prompt AST
# =============================================================================

RubyLLM::Contract.configure do |c|
  c.default_adapter = RubyLLM::Contract::Adapters::Test.new(
    response: '{"sentiment": "negative", "confidence": 0.85, "reason": "product complaint"}'
  )
end

class SentimentWithSections < RubyLLM::Contract::Step::Base
  input_type String

  output_schema do
    string :sentiment, enum: %w[positive negative neutral]
    number :confidence, minimum: 0.0, maximum: 1.0
    string :reason
  end

  prompt do
    system "You are a sentiment classifier for customer support."
    rule "Return JSON with sentiment, confidence, and reason."

    section "CONTEXT", "We sell software for freelancers."
    section "SCORING GUIDE", "negative = complaint or frustration\npositive = praise or thanks\nneutral = question or factual statement"

    user "Classify this: {input}"
  end
end

result = SentimentWithSections.run("Your billing page is broken again!")
result.status        # => :ok
result.parsed_output # => {sentiment: "negative", confidence: 0.85, reason: "product complaint"}

# =============================================================================
# STEP 7: Hash input — multiple fields with auto-interpolation
#
# When input is a Hash, each key becomes a template variable.
# {title} resolves to input[:title], {language} to input[:language], etc.
# No manual string building needed.
# =============================================================================

RubyLLM::Contract.configure do |c|
  c.default_adapter = RubyLLM::Contract::Adapters::Test.new(
    response: '{"category": "billing", "priority": "high"}'
  )
end

class ClassifyTicket < RubyLLM::Contract::Step::Base
  input_type RubyLLM::Contract::Types::Hash.schema(
    title: RubyLLM::Contract::Types::String,
    body: RubyLLM::Contract::Types::String,
    language: RubyLLM::Contract::Types::String
  )

  output_schema do
    string :category, enum: %w[billing technical feature_request other]
    string :priority, enum: %w[low medium high urgent]
  end

  prompt do
    system "You classify customer support tickets."
    rule "Return JSON with category and priority."
    rule "Respond in {language}."
    user "Title: {title}\n\nBody: {body}"
  end
end

result = ClassifyTicket.run(
  { title: "Can't update credit card", body: "Payment page gives error 500", language: "en" }
)
result.status        # => :ok
result.parsed_output # => {category: "billing", priority: "high"}

# =============================================================================
# STEP 8: 2-arity invariants — validate output against input
#
# Sometimes you need to check that the output is consistent with the input.
# A 2-arity invariant receives both |output, input| so you can cross-validate.
# =============================================================================

RubyLLM::Contract.configure do |c|
  c.default_adapter = RubyLLM::Contract::Adapters::Test.new(
    response: '{"translation": "Bonjour le monde", "source_lang": "en", "target_lang": "fr"}'
  )
end

class Translate < RubyLLM::Contract::Step::Base
  input_type RubyLLM::Contract::Types::Hash.schema(
    text: RubyLLM::Contract::Types::String,
    target_lang: RubyLLM::Contract::Types::String
  )

  output_schema do
    string :translation, min_length: 1
    string :source_lang
    string :target_lang
  end

  prompt do
    system "Translate the text to the target language."
    rule "Return JSON with translation, source_lang, and target_lang."
    user "Translate to {target_lang}: {text}"
  end

  # Schema handles: translation non-empty, all fields present
  # 2-arity validate: cross-validate output against input
  validate("target_lang must match requested language") do |output, input|
    output[:target_lang] == input[:target_lang]
  end
end

result = Translate.run({ text: "Hello world", target_lang: "fr" })
result.status        # => :ok
result.parsed_output # => {translation: "Bonjour le monde", source_lang: "en", target_lang: "fr"}

# What if model returns wrong target language?
RubyLLM::Contract.configure do |c|
  c.default_adapter = RubyLLM::Contract::Adapters::Test.new(
    response: '{"translation": "Hola mundo", "source_lang": "en", "target_lang": "es"}'
  )
end

result = Translate.run({ text: "Hello world", target_lang: "fr" })
result.status            # => :validation_failed
result.validation_errors # => ["target_lang must match requested language"]

# =============================================================================
# STEP 9: Context override — per-run adapter and model
#
# Global config sets defaults. You can override per call via context.
# Useful for: testing, switching models, A/B testing prompts.
# =============================================================================

RubyLLM::Contract.configure do |c|
  c.default_adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"sentiment": "positive"}')
  c.default_model = "gpt-4.1-mini"
end

# Uses global defaults:
result = SimpleSentiment.run("I love this product!")
result.status        # => :ok
result.trace[:model] # => "gpt-4.1-mini"

# Override adapter and model for this specific call:
other_adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"sentiment": "neutral"}')
result = SimpleSentiment.run("I love this product!", context: { adapter: other_adapter, model: "gpt-5" })
result.status          # => :ok
result.parsed_output   # => {sentiment: "neutral"}
result.trace[:model]   # => "gpt-5"

# =============================================================================
# STEP 10: StepResult — everything you get back from a run
#
# Every .run() returns a StepResult with status, output, errors, and trace.
# =============================================================================

adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"sentiment": "positive", "confidence": 0.92}')
result = SentimentValidated.run("I love this product!", context: { adapter: adapter, model: "gpt-4.1-mini" })

result.status            # => :ok
result.ok?               # => true
result.failed?           # => false
result.raw_output        # => '{"sentiment": "positive", "confidence": 0.92}'
result.parsed_output     # => {sentiment: "positive", confidence: 0.92}
result.validation_errors # => []
result.trace[:model]     # => "gpt-4.1-mini"
result.trace[:latency_ms]# => 0     (instant with test adapter)
result.trace[:messages]  # => [{role: :system, content: "..."}, {role: :user, content: "..."}]

# On failure, you still get everything for debugging:
bad_adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"sentiment": "positive", "confidence": 0.1}')
result = SentimentValidated.run("I love this product!", context: { adapter: bad_adapter })

result.status            # => :validation_failed
result.ok?               # => false
result.failed?           # => true
result.raw_output        # => '{"sentiment": "positive", "confidence": 0.1}'
result.parsed_output     # => {sentiment: "positive", confidence: 0.1}
result.validation_errors # => ["high confidence required for extreme sentiments"]

# =============================================================================
# STEP 11: Pipeline — chain multiple steps with fail-fast
#
# Pipeline::Base composes steps into a sequence.
# Output of step N automatically becomes input to step N+1.
# If any step fails, execution halts immediately.
# =============================================================================

# Step A: classify sentiment
class PipelineSentiment < RubyLLM::Contract::Step::Base
  input_type String

  output_schema do
    string :text
    string :sentiment, enum: %w[positive negative neutral]
  end

  prompt do
    system "Classify sentiment and return the original text."
    user "{input}"
  end
end

# Step B: generate a response based on sentiment
class PipelineRespond < RubyLLM::Contract::Step::Base
  input_type Hash

  output_schema do
    string :response
    string :tone
  end

  prompt do
    system "Generate a customer support response matching the sentiment."
    user "Text: {text}\nSentiment: {sentiment}"
  end
end

# Pipeline: sentiment → respond
class SupportPipeline < RubyLLM::Contract::Pipeline::Base
  step PipelineSentiment, as: :classify
  step PipelineRespond,   as: :respond
end

# Happy path:
RubyLLM::Contract.configure do |c|
  c.default_adapter = RubyLLM::Contract::Adapters::Test.new(
    response: '{"text": "I love this product!", "sentiment": "positive"}'
  )
end

# Note: with Test adapter, both steps get the same canned response.
# With a real LLM, each step would get a different response.
result = SupportPipeline.run("I love this product!")
result.ok?                            # => true
result.outputs_by_step[:classify]     # => {text: "I love this product!", sentiment: "positive"}
result.outputs_by_step[:respond]      # => {text: "I love this product!", sentiment: "positive"}
result.step_results.length            # => 2

# =============================================================================
# SUMMARY
#
# Step 1:  user "{input}"                   — plain string, nothing else
# Step 2:  system + user                    — separate instructions from data
# Step 3:  + output_schema                  — declarative output structure
# Step 4:  + invariants                     — custom business logic on top
# Step 5:  + examples                       — few-shot
# Step 6:  + sections                       — labeled context blocks
# Step 7:  Hash input                       — multiple fields, auto-interpolation
# Step 8:  2-arity invariants               — cross-validate output vs input
# Step 9:  context override                 — per-run adapter and model
# Step 10: StepResult                       — full status, output, errors, trace
# Step 11: Pipeline                         — chain steps with fail-fast
#
# Each step adds one layer. Use as many as you need.
# Even Step 1 gives you: typed input, JSON parsing, and trace.
# =============================================================================
