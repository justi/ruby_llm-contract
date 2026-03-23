# frozen_string_literal: true

# =============================================================================
# EXAMPLE 7: Keyword Extraction with probability scoring
#
# One article in, up to 15 keywords out — each with a relevance
# probability. Schema enforces structure (array bounds, number range).
# Invariants enforce logic (sorted, no duplicates, keywords from text).
#
# Shows:
#   - Array output_schema with nested objects
#   - min_items / max_items constraints
#   - number range (probability 0.0–1.0)
#   - Invariant: sorted order (schema can't express this)
#   - Invariant: uniqueness (schema can't express this)
#   - Invariant: cross-validation — keywords must appear in source text
#   - retry_policy for model escalation
# =============================================================================

require_relative "../lib/ruby_llm/contract"

# =============================================================================
# STEP DEFINITION
# =============================================================================

class ExtractKeywords < RubyLLM::Contract::Step::Base
  input_type String

  output_schema do
    array :keywords, min_items: 1, max_items: 15 do
      string :keyword, description: "1-3 word keyword or phrase"
      number :probability, minimum: 0.0, maximum: 1.0
    end
  end

  prompt do
    system "Extract the most relevant keywords from the article."
    rule "Return up to 15 keywords, each with a relevance probability (0.0 to 1.0)."
    rule "Sort by probability descending (most relevant first)."
    rule "Each keyword must be 1-3 words."
    rule "Keywords must actually appear in or directly relate to the text."

    example input: "Ruby on Rails is a web framework written in Ruby.",
            output: '{"keywords":[{"keyword":"Ruby on Rails","probability":0.95},{"keyword":"web framework","probability":0.85},{"keyword":"Ruby","probability":0.75}]}'

    user "{input}"
  end

  validate("sorted by probability descending") do |o|
    probs = o[:keywords].map { |k| k[:probability] }
    probs == probs.sort.reverse
  end

  validate("no duplicate keywords") do |o|
    words = o[:keywords].map { |k| k[:keyword].downcase.strip }
    words.uniq.length == words.length
  end

  validate("keywords relate to source text") do |output, input|
    text = input.downcase
    matches = output[:keywords].count { |k| text.include?(k[:keyword].downcase) }
    matches >= (output[:keywords].length * 0.7).ceil
  end

  retry_policy models: %w[gpt-4.1-nano gpt-4.1-mini]
end

# =============================================================================
# TEST WITH CANNED RESPONSES
# =============================================================================

article = <<~ARTICLE
  Artificial intelligence is transforming the way developers build software.
  Machine learning models, particularly large language models like GPT and Claude,
  are being integrated into development workflows for code generation, testing,
  and documentation. Ruby developers are adopting gems like ruby_llm to interact
  with these models through a clean API. The challenge remains in ensuring output
  quality — without contracts and validation, LLM responses can hallucinate or
  produce structurally invalid data that breaks downstream systems.
ARTICLE

puts "=" * 60
puts "KEYWORD EXTRACTION"
puts "=" * 60

# Happy path — good keywords
good_response = {
  keywords: [
    { keyword: "artificial intelligence", probability: 0.95 },
    { keyword: "machine learning", probability: 0.90 },
    { keyword: "large language models", probability: 0.88 },
    { keyword: "Ruby developers", probability: 0.82 },
    { keyword: "code generation", probability: 0.78 },
    { keyword: "output quality", probability: 0.72 },
    { keyword: "ruby_llm", probability: 0.70 },
    { keyword: "LLM responses", probability: 0.65 },
    { keyword: "validation", probability: 0.60 }
  ]
}.to_json

adapter = RubyLLM::Contract::Adapters::Test.new(response: good_response)
result = ExtractKeywords.run(article, context: { adapter: adapter })

puts "\n--- Happy path ---"
puts "Status: #{result.status}"
result.parsed_output[:keywords].each do |k|
  bar = "#" * (k[:probability] * 20).round
  puts "  #{k[:probability].to_s.ljust(5)} #{bar.ljust(20)} #{k[:keyword]}"
end

# Bad: unsorted probabilities
puts "\n--- Invariant catches: unsorted ---"
unsorted = {
  keywords: [
    { keyword: "Ruby", probability: 0.60 },
    { keyword: "AI", probability: 0.95 },
    { keyword: "testing", probability: 0.80 }
  ]
}.to_json

r2 = ExtractKeywords.run(article, context: { adapter: RubyLLM::Contract::Adapters::Test.new(response: unsorted) })
puts "Status: #{r2.status}"
puts "Errors: #{r2.validation_errors}"

# Bad: duplicate keywords
puts "\n--- Invariant catches: duplicates ---"
dupes = {
  keywords: [
    { keyword: "machine learning", probability: 0.95 },
    { keyword: "Machine Learning", probability: 0.90 },
    { keyword: "AI", probability: 0.80 }
  ]
}.to_json

r3 = ExtractKeywords.run(article, context: { adapter: RubyLLM::Contract::Adapters::Test.new(response: dupes) })
puts "Status: #{r3.status}"
puts "Errors: #{r3.validation_errors}"

# Bad: hallucinated keywords not in text
puts "\n--- Invariant catches: hallucinated keywords ---"
hallucinated = {
  keywords: [
    { keyword: "blockchain", probability: 0.95 },
    { keyword: "cryptocurrency", probability: 0.90 },
    { keyword: "NFT marketplace", probability: 0.85 },
    { keyword: "artificial intelligence", probability: 0.80 }
  ]
}.to_json

r4 = ExtractKeywords.run(article, context: { adapter: RubyLLM::Contract::Adapters::Test.new(response: hallucinated) })
puts "Status: #{r4.status}"
puts "Errors: #{r4.validation_errors}"

# =============================================================================
# PIPELINE: Article → Keywords → Related Topics
# =============================================================================

puts "\n\n#{"=" * 60}"
puts "PIPELINE: Article → Keywords → Related Topics"
puts "=" * 60

class SuggestRelatedTopics < RubyLLM::Contract::Step::Base
  input_type Hash

  output_schema do
    array :topics, min_items: 3, max_items: 5 do
      string :title
      string :angle, description: "Unique angle or hook for the topic"
    end
  end

  prompt do
    system "Suggest related article topics based on the extracted keywords."
    rule "Each topic must have a unique angle, not just repeat the keywords."
    rule "Topics should be interesting to the same audience."
    user "Keywords: {keywords}"
  end

  validate("topics have unique titles") do |o|
    titles = o[:topics].map { |t| t[:title].downcase }
    titles.uniq.length == titles.length
  end

  validate("angles are substantive") do |o|
    o[:topics].all? { |t| t[:angle].to_s.split.length >= 5 }
  end
end

class ArticlePipeline < RubyLLM::Contract::Pipeline::Base
  step ExtractKeywords,      as: :keywords
  step SuggestRelatedTopics, as: :topics
end

topics_response = {
  topics: [
    { title: "Building LLM-Powered Ruby Gems",
      angle: "How to structure a Ruby gem that wraps LLM APIs with type safety" },
    { title: "Contract-First AI Development",
      angle: "Why treating LLM outputs like API responses improves reliability" },
    { title: "Testing AI Features Without API Calls",
      angle: "Deterministic testing patterns for LLM integrations using canned adapters" }
  ]
}.to_json

adapter_kw = RubyLLM::Contract::Adapters::Test.new(response: good_response)
adapter_tp = RubyLLM::Contract::Adapters::Test.new(response: topics_response)

# Run steps individually (different adapters per step)
r_kw = ExtractKeywords.run(article, context: { adapter: adapter_kw })
r_tp = SuggestRelatedTopics.run(r_kw.parsed_output, context: { adapter: adapter_tp })

puts "\nKeywords → Topics pipeline:"
puts "  Keywords: #{r_kw.parsed_output[:keywords].length} extracted"
puts "  Topics:"
r_tp.parsed_output[:topics].each do |t|
  puts "    #{t[:title]}"
  puts "      → #{t[:angle]}"
end

# =============================================================================
# SUMMARY
#
# Schema handles:
#   - Array with 1-15 items (min_items, max_items)
#   - Each item has keyword (string) + probability (number 0.0-1.0)
#
# Invariants handle:
#   - Sorted by probability (schema can't express ordering)
#   - No duplicates (schema can't express uniqueness)
#   - Keywords from source text (schema can't see input)
#
# Pipeline:
#   - Extract keywords → suggest related topics
#   - Each step has its own schema + invariants
#
# Model escalation:
#   - retry_policy { escalate "nano", "mini" }
#   - If nano returns unsorted or hallucinated keywords, mini retries
# =============================================================================
