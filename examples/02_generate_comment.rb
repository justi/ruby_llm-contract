# frozen_string_literal: true

# =============================================================================
# EXAMPLE 2: Promo Comment Generation
#
# Real-world case: Generate a Reddit comment that subtly promotes a product.
# The comment must match the thread's language, sound like a real user,
# include a product link naturally, and follow strict persona rules.
# =============================================================================

require_relative "../lib/ruby_llm/contract"

# =============================================================================
# BEFORE: Legacy approach (200+ lines across multiple concerns)
# =============================================================================
#
# In the legacy codebase, the prompt is assembled from 6+ helper methods
# across comment_prompts.rb (240 lines):
#
# ```ruby
# # System message built from 8 sections:
# def system_message_for_promo
#   base_system_message(
#     intro: "You write Reddit comments that subtly promote a product...",
#     voice_lines: [
#       "Sound like a genuine user who found something useful, not an ad.",
#       'Never say "I built" or "I made this".',
#       "Sound like a real Reddit user: casual, no marketing speak...",
#       # ... 10 more rules
#     ],
#     self_contained_lines: [...],
#     extra_sections: [section("PROMO LINKING BASICS", [...])]
#   )
# end
#
# # User prompt built by string concatenation:
# def build_promo_prompt(items, strict_language: false, comment_plan: nil)
#   [
#     <<~PRODUCT.strip,
#     [PRODUCT]
#     Domain: #{@url}
#     PRODUCT
#     pages_section,
#     section("URL SELECTION", promo_url_selection_rules),
#     section("PRODUCT MENTION", promo_product_mention_rules + [...]),
#     comment_plan_section,
#     comment_plan_rules,
#     strict_lang_section,
#     <<~ITEMS.strip
#       [ITEMS]
#       #{items.to_json}
#     ITEMS
#   ].compact.join("\n\n")
# end
# ```
#
# PROBLEMS:
# - 200+ lines of string building spread across 8+ methods
# - No validation on output — wrong language silently passes, caught later
# - Persona + voice + rules mixed with data (URL, pages, items)
# - Change one voice rule → no way to measure impact on output quality
# - The `.compact.join("\n\n")` pattern is fragile — easy to break structure

# =============================================================================
# AFTER: ruby_llm-contract approach
# =============================================================================

PERSONA = <<~PERSONA.strip
  You are a woman, 40+, a maker. You solve your own problems by building \
  software. Outside of code you crochet, sew, 3D-print, and do \
  astrophotography with your son. You hunt deals both offline and online. \
  Your writing style: reflective, inventive, casual. You make typos, skip \
  Polish diacritics sometimes, write like a real person on a forum.
PERSONA

class GeneratePromoComment < RubyLLM::Contract::Step::Base
  input_type RubyLLM::Contract::Types::Hash.schema(
    thread_title: RubyLLM::Contract::Types::String,
    thread_selftext: RubyLLM::Contract::Types::String,
    subreddit: RubyLLM::Contract::Types::String,
    target_length: RubyLLM::Contract::Types::Integer,
    thread_language: RubyLLM::Contract::Types::String,
    product_url: RubyLLM::Contract::Types::String,
    matched_page_url: RubyLLM::Contract::Types::String
  )
  output_type Hash

  prompt do
    system "You write Reddit comments that subtly promote a product. Return valid JSON only."

    section "PERSONA", PERSONA

    rule "Sound like a genuine user who found something useful, not an ad."
    rule 'Never say "I built" or "I made this".'
    rule "Casual tone, no marketing speak, no emojis, no bullet points."
    rule "Pick one specific angle and share it concretely."
    rule "Be opinionated; say what worked for you, not generic balanced advice."
    rule 'NEVER start with "Nice X", "Cool X", "Love this". Jump straight into your point.'
    rule "Give 2-3 options; the product link should be ONE of them, not the whole point."
    rule "The comment must stand without the link."
    rule 'Do not introduce the link with "PS:", "btw:", or parenthetical asides.'
    rule "No markdown headers or formatting. Plain text only."
    rule "Write in {thread_language}."
    rule "Approximately {target_length} characters (±20%)."

    section "PRODUCT", "Domain: {product_url}\nPage: {matched_page_url}"

    user "r/{subreddit}: {thread_title}\n\n{thread_selftext}\n\nWrite a helpful comment."
  end

  validate("comment must not be empty") do |o|
    o[:comment].is_a?(String) && o[:comment].strip.length > 10
  end

  validate("no markdown headers") do |o|
    !o[:comment].to_s.match?(/^\#{2,}\s/)
  end

  validate("no emojis") do |o|
    !o[:comment].to_s.match?(/[\u{1F600}-\u{1F64F}\u{1F300}-\u{1F5FF}\u{1F680}-\u{1F6FF}]/)
  end

  validate("includes product link") do |o, input|
    o[:comment].to_s.include?(input[:matched_page_url])
  end

  validate("length within ±30% of target") do |o, input|
    len = o[:comment].to_s.length
    target = input[:target_length]
    len.between?((target * 0.7).to_i, (target * 1.3).to_i)
  end

  validate("does not start with banned openings") do |o|
    banned = ["Nice ", "Cool ", "Love this", "Great ", "Totally agree"]
    banned.none? { |b| o[:comment].to_s.start_with?(b) }
  end
end

# =============================================================================
# DEMO: Run with test adapter
# =============================================================================

input = {
  thread_title: "spent way too much on yarn this month lol",
  thread_selftext: "Between Drops and the new Scheepjes line I'm broke. Anyone else track their spending?",
  subreddit: "crochet",
  target_length: 200,
  thread_language: "en",
  product_url: "https://deals.example.com",
  matched_page_url: "https://deals.example.com/yarn-deals"
}

# Happy path — good comment
good_comment = {
  comment: "Ugh same. I started tracking last year and the numbers were brutal. " \
           "What helped — monthly yarn budget plus checking https://deals.example.com/yarn-deals " \
           "before impulse buying. Ravelry destash groups too."
}.to_json

adapter = RubyLLM::Contract::Adapters::Test.new(response: good_comment)
result = GeneratePromoComment.run(input, context: { adapter: adapter })

puts "=== HAPPY PATH ==="
puts "Status: #{result.status}"
puts "Comment: #{result.parsed_output[:comment]}"
puts "Validation errors: #{result.validation_errors}"
puts

# Bad path — starts with banned opening
bad_comment = {
  comment: "Nice question! I track my yarn spending with a spreadsheet and also check " \
           "https://deals.example.com/yarn-deals for sales."
}.to_json

bad_adapter = RubyLLM::Contract::Adapters::Test.new(response: bad_comment)
result = GeneratePromoComment.run(input, context: { adapter: bad_adapter })

puts "=== BANNED OPENING ==="
puts "Status: #{result.status}"
puts "Validation errors: #{result.validation_errors}"
puts

# Bad path — missing product link
no_link_comment = {
  comment: "Same here. I started a spreadsheet and realized I spent way more than I thought. " \
           "Ravelry destash groups are great for cheap yarn though."
}.to_json

no_link_adapter = RubyLLM::Contract::Adapters::Test.new(response: no_link_comment)
result = GeneratePromoComment.run(input, context: { adapter: no_link_adapter })

puts "=== MISSING LINK ==="
puts "Status: #{result.status}"
puts "Validation errors: #{result.validation_errors}"
puts

# Inspect the rendered prompt AST
puts "=== RENDERED PROMPT (first 3 messages) ==="
adapter = RubyLLM::Contract::Adapters::Test.new(response: good_comment)
result = GeneratePromoComment.run(input, context: { adapter: adapter })
result.trace[:messages].first(3).each do |msg|
  puts "  [#{msg[:role]}] #{msg[:content][0..80]}..."
end
