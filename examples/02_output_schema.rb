# frozen_string_literal: true

# =============================================================================
# EXAMPLE 5: Declarative output schema on SummarizeArticle
#
# Two jobs of output_schema:
#   1. Send the schema to the LLM provider so it returns JSON in that shape.
#   2. Validate the response client-side (cheap models sometimes ignore the
#      provider-side schema hint — validation catches that).
#
# Patterns shown:
#   - Flat schema with enum + constraints
#   - Nested objects in an array (confidence per takeaway — UI renders a
#     confidence bar next to each point)
#   - Schema + cross-field validate (shape is not enough; content must agree)
# =============================================================================

require_relative "../lib/ruby_llm/contract"

RubyLLM::Contract.configure do |c|
  c.default_adapter = RubyLLM::Contract::Adapters::Test.new(
    response: {
      tldr: "Ruby 3.4 lands with frozen string literals, YJIT speedups, parser fixes.",
      takeaways: [
        { text: "Frozen string literals are the default", confidence: 0.95 },
        { text: "YJIT delivers measurable Rails speedups",  confidence: 0.90 },
        { text: "Parser fixes and keyword arg improvements", confidence: 0.80 }
      ],
      tone: "analytical"
    }
  )
end

# =============================================================================
# Pattern 1 — Flat schema (strings, enums, constraints)
# =============================================================================

class SummarizeArticleFlat < RubyLLM::Contract::Step::Base
  prompt "Summarize: {input}"

  output_schema do
    string :tldr, min_length: 20, max_length: 200
    array  :takeaways, of: :string, min_items: 3, max_items: 5
    string :tone, enum: %w[neutral positive negative analytical]
  end
end

# =============================================================================
# Pattern 2 — Nested objects in an array (takeaway + confidence bar)
#
# Without object do...end inside the array block, the schema degrades to
# "array of strings" (only the first child declaration counts). Wrap the
# children in object do...end whenever you want compound items.
# =============================================================================

class SummarizeArticleWithConfidence < RubyLLM::Contract::Step::Base
  prompt "Summarize: {input}"

  output_schema do
    string :tldr, min_length: 20, max_length: 200
    array :takeaways, min_items: 3, max_items: 5 do
      object do
        string :text
        number :confidence, minimum: 0.0, maximum: 1.0
      end
    end
    string :tone, enum: %w[neutral positive negative analytical]
  end
end

r = SummarizeArticleWithConfidence.run("article text")
r.status                          # => :ok
r.parsed_output[:takeaways].first # => {text: "...", confidence: 0.95}

# =============================================================================
# Pattern 3 — Schema + cross-field validate
#
# Schema guarantees shape. It cannot express "if tone is negative, at least
# one takeaway must contain a severity keyword" — that needs a validate block.
# Schema for shape, validate for meaning.
# =============================================================================

class SummarizeArticleWithRules < SummarizeArticleFlat
  validate("takeaways are unique") { |o, _| o[:takeaways].uniq.size == o[:takeaways].size }

  validate("negative tone requires concrete severity") do |output, _|
    next true unless output[:tone] == "negative"
    output[:takeaways].any? { |t| t.match?(/fail|crash|outage|bug|regression/i) }
  end
end

# =============================================================================
# Pattern reference
#
# | Output looks like                       | Schema                                  |
# |-----------------------------------------|-----------------------------------------|
# | {"tldr": "...", "tone": "positive"}     | string :tldr; string :tone, enum: [..]  |
# | {"takeaways": ["a", "b"]}               | array :takeaways, of: :string           |
# | {"takeaways": [{"text": "...",          | array :takeaways do;                    |
# |   "confidence": 0.9}]}                  |   object do;                            |
# |                                         |     string :text;                       |
# |                                         |     number :confidence, minimum: 0.0,   |
# |                                         |             maximum: 1.0;               |
# |                                         |   end;                                  |
# |                                         | end                                     |
# =============================================================================
