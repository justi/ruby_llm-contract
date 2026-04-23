# frozen_string_literal: true

# =============================================================================
# EXAMPLE 3: SummarizeArticle v2 — growing prompt with a keywords field
#
# A common evolution in a real Rails app: the UI card shipped with TL;DR,
# takeaways, and tone. Marketing now wants a "topic pills" row under the
# card — a sorted list of keywords with a confidence score so the UI can
# render stronger keywords larger.
#
# You could build a second step, but it is one more LLM call per article
# and the model already has the full context. Better: add one field to
# the existing SummarizeArticle step. The prompt grows, the schema grows,
# the validates grow — the contract keeps all three in lockstep.
#
# Run: ruby examples/03_summarize_with_keywords.rb
#
# Expected output:
#
#   Status:    ok
#   TL;DR:     Ruby 3.4 brings frozen string literals, YJIT speedups, parser fixes.
#   Tone:      analytical
#
#   Keywords (sorted by probability):
#     0.95  ###################  Ruby 3.4
#     0.9   ##################   frozen string literals
#     0.85  #################    YJIT
#     0.7   ##############       Rails workloads
#     0.6   ############         parser fixes
# =============================================================================

require_relative "../lib/ruby_llm/contract"

ARTICLE = <<~ARTICLE
  Ruby 3.4 ships with frozen string literals on by default, measurable YJIT
  speedups on Rails workloads, and tightened Warning.warn category filtering.
  Parser fixes and faster keyword argument handling land alongside.
ARTICLE

GOOD_RESPONSE = {
  tldr: "Ruby 3.4 brings frozen string literals, YJIT speedups, parser fixes.",
  takeaways: [
    "Frozen string literals are the default in Ruby 3.4",
    "YJIT delivers measurable Rails speedups",
    "Parser fixes and keyword argument handling improve"
  ],
  tone: "analytical",
  keywords: [
    { text: "Ruby 3.4",              probability: 0.95 },
    { text: "frozen string literals", probability: 0.90 },
    { text: "YJIT",                   probability: 0.85 },
    { text: "Rails workloads",        probability: 0.70 },
    { text: "parser fixes",           probability: 0.60 }
  ]
}.freeze

# =============================================================================
# SummarizeArticle v2: original three fields + keywords
# =============================================================================

class SummarizeArticleWithKeywords < RubyLLM::Contract::Step::Base
  prompt <<~PROMPT
    Summarize this article for a UI card. Return a short TL;DR,
    3 to 5 key takeaways, a tone label, and a ranked list of keywords.

    For keywords: extract 3 to 8 phrases (1-3 words each) that appear in
    or directly relate to the article. Give each a relevance probability
    between 0.0 and 1.0. Sort by probability descending.

    {input}
  PROMPT

  output_schema do
    string :tldr, min_length: 20, max_length: 200
    array  :takeaways, of: :string, min_items: 3, max_items: 5
    string :tone, enum: %w[neutral positive negative analytical]
    array :keywords, min_items: 3, max_items: 8 do
      object do
        string :text, description: "1-3 word keyword or phrase"
        number :probability, minimum: 0.0, maximum: 1.0
      end
    end
  end

  validate("TL;DR fits the card") { |o, _| o[:tldr].length <= 200 }

  validate("keywords sorted by probability descending") do |o, _|
    probs = o[:keywords].map { |k| k[:probability] }
    probs == probs.sort.reverse
  end

  validate("keywords are unique (case-insensitive)") do |o, _|
    words = o[:keywords].map { |k| k[:text].downcase.strip }
    words.uniq.size == words.size
  end

  # Cross-validation: catches hallucinated keywords not in the source text.
  # "At least 70% of keywords must appear in the article (case-insensitive)."
  validate("keywords relate to the source article") do |output, input|
    text = input.downcase
    grounded = output[:keywords].count { |k| text.include?(k[:text].downcase) }
    grounded >= (output[:keywords].size * 0.7).ceil
  end
end

adapter = RubyLLM::Contract::Adapters::Test.new(response: GOOD_RESPONSE)
result = SummarizeArticleWithKeywords.run(ARTICLE, context: { adapter: adapter })

puts "Status:    #{result.status}"                      # => :ok
puts "TL;DR:     #{result.parsed_output[:tldr]}"
puts "Tone:      #{result.parsed_output[:tone]}"
puts
puts "Keywords (sorted by probability):"
result.parsed_output[:keywords].each do |k|
  bar = "#" * (k[:probability] * 20).round
  puts "  #{k[:probability].to_s.ljust(5)} #{bar.ljust(20)} #{k[:text]}"
end

# =============================================================================
# What this showcases
#
# - One step, growing contract: the original SummarizeArticle schema + three
#   rules, extended with a fourth field and three more rules. The prompt,
#   schema, and validates all grow together and stay in sync.
# - Array of objects with per-item constraints (probability 0.0-1.0).
# - Cross-validation against the input (hallucination catch).
# - Uniqueness rule that schema cannot express on its own.
# =============================================================================
