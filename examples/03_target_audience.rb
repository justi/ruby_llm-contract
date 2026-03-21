# frozen_string_literal: true

# =============================================================================
# EXAMPLE 3: Target Audience Generation
#
# Real-world case: Analyze a product URL and generate audience profiles.
# This is stage 1 of the pipeline — if it fails, everything downstream
# breaks (subreddit discovery, thread classification, comment generation).
# =============================================================================

require_relative "../lib/ruby_llm/contract"

# =============================================================================
# BEFORE: Legacy approach (prompt + schema in concern, ad-hoc validation)
# =============================================================================
#
# In the legacy codebase, this is in target_audience_prompts.rb:
#
# ```ruby
# def build_audience_profile_prompt(plan, pages)
#   <<~PROMPT
#     Analyze this webpage. First, understand what the product/service does.
#     Then figure out who the TARGET AUDIENCE is.
#
#     #{product_input_context(plan, pages)}
#
#     ---
#
#     Generate:
#     1. LOCALE: Detect the page language. Return ISO 639-1 code.
#     2. DESCRIPTION: Write exactly 1 sentence (max 15 words): WHAT it is.
#     3. Identify 2-3 distinct target audience groups.
#
#     CRITICAL: Describe groups by their LIFE SITUATION and EVERYDAY PROBLEMS...
#     [... 40 more lines of instructions ...]
#   PROMPT
# end
#
# # Validation is ad-hoc, buried in the caller:
# def valid_product_context?(context)
#   context.is_a?(Hash) &&
#     context["locale"].present? &&
#     context["description"].present? &&
#     context["groups"].is_a?(Array) &&
#     context["groups"].size >= 1
# end
# ```
#
# PROBLEMS:
# - 50-line heredoc string — impossible to diff meaningfully
# - Validation is a separate method, easy to forget to call
# - If locale is wrong (e.g. "english" instead of "en"), it passes validation
# - If groups are present but empty/garbage, no way to catch it
# - Failure here silently poisons all 6 downstream stages

# =============================================================================
# AFTER: ruby_llm-contract approach
# =============================================================================

class GenerateTargetAudience < RubyLLM::Contract::Step::Base
  input_type RubyLLM::Contract::Types::Hash.schema(
    url: RubyLLM::Contract::Types::String,
    body_text: RubyLLM::Contract::Types::String,
    sitemap_pages: RubyLLM::Contract::Types::Array.of(RubyLLM::Contract::Types::Hash)
  )
  output_type Hash

  prompt do
    system "Analyze a product webpage and generate target audience profiles."

    rule "Detect page language, return ISO 639-1 code (e.g. 'en', 'pl', 'de')."
    rule "Write product description in exactly 1 sentence, max 15 words. Say WHAT, not HOW."
    rule "Identify 2-3 distinct audience groups based on LIFE SITUATION, not product jargon."
    rule "Write 'who' as if YOU are that person posting on Reddit, not a marketer."
    rule "Return JSON with locale, description, and groups array."

    section "GOOD vs BAD EXAMPLES", <<~EXAMPLES
      Good "who": "I'm 30, trying to lose weight but I hate counting calories"
      Bad "who": "Adults 25-55 who buy specialty outdoor gear occasionally"

      Good use_case: "I keep checking 5 different shops and it takes forever"
      Bad use_case: "Track shop promotions across retailers"

      Good thread: "spent way too much on yarn this month lol"
      Bad thread: "budgeting for craft supplies"
    EXAMPLES

    user "URL: {url}\n\nBODY TEXT:\n{body_text}\n\nSITEMAP PAGES:\n{sitemap_pages}"
  end

  validate("locale is valid ISO 639-1") do |o|
    o[:locale].is_a?(String) && o[:locale].match?(/\A[a-z]{2}\z/)
  end

  validate("description is present and concise") do |o|
    desc = o[:description].to_s.strip
    desc.length > 5 && desc.split.size <= 20
  end

  validate("has 1-4 audience groups") do |o|
    o[:groups].is_a?(Array) && o[:groups].size.between?(1, 4)
  end

  validate("each group has who field") do |o|
    o[:groups].is_a?(Array) && o[:groups].all? { |g| g[:who].to_s.strip.length > 10 }
  end

  validate("each group has use_cases") do |o|
    o[:groups].is_a?(Array) && o[:groups].all? { |g| g[:use_cases].is_a?(Array) && g[:use_cases].size >= 2 }
  end

  validate("each group has good_fit_threads") do |o|
    o[:groups].is_a?(Array) && o[:groups].all? do |g|
      g[:good_fit_threads].is_a?(Array) && g[:good_fit_threads].size >= 2
    end
  end
end

# =============================================================================
# DEMO: Run with test adapter — showing cascade failure prevention
# =============================================================================

input = {
  url: "https://deals.example.com",
  body_text: "Track deals from niche online shops. Get alerts for price drops on craft supplies, " \
             "hobby gear, and specialty items. We monitor 200+ small retailers daily.",
  sitemap_pages: [
    { url: "/yarn-deals", title: "Yarn & Crochet Deals", description: "Sales on yarn, hooks, patterns" },
    { url: "/gaming-deals", title: "Gaming Merch Deals", description: "Gaming accessories and merch sales" }
  ]
}

# Happy path — good audience profile
good_response = {
  locale: "en",
  description: "Deals aggregator for niche online shops.",
  groups: [
    {
      who: "I'm a crafter who spends too much on supplies every month and my partner is getting annoyed.",
      use_cases: ["I keep checking 5 different yarn shops", "I always find out about sales after they end"],
      not_covered: ["Groceries and food delivery", "Air travel"],
      good_fit_threads: ["spent way too much on yarn this month lol", "anyone else feel guilty about hobby spending?"],
      bad_fit_threads: ["best grocery cashback apps", "cheap flight deals"]
    },
    {
      who: "I'm a gamer building my setup on a budget and I hate paying full price for peripherals.",
      use_cases: ["I want to know when my wishlist items go on sale",
                  "Small shops have better deals but I can't check them all"],
      not_covered: ["Digital game keys", "Streaming subscriptions"],
      good_fit_threads: ["just got into minipainting and my wallet hurts", "budget gaming setup thread"],
      bad_fit_threads: ["best game pass deals", "Netflix vs Disney+"]
    }
  ]
}.to_json

adapter = RubyLLM::Contract::Adapters::Test.new(response: good_response)
result = GenerateTargetAudience.run(input, context: { adapter: adapter })

puts "=== HAPPY PATH ==="
puts "Status: #{result.status}"
puts "Locale: #{result.parsed_output[:locale]}"
puts "Description: #{result.parsed_output[:description]}"
puts "Groups: #{result.parsed_output[:groups].size}"
puts "Validation errors: #{result.validation_errors}"
puts

# Bad path — invalid locale (legacy code would let "english" pass)
bad_locale_response = {
  locale: "english", # Should be "en", not "english"
  description: "Deals aggregator for niche online shops.",
  groups: [{ who: "A crafter", use_cases: ["buying yarn"], not_covered: [], good_fit_threads: ["yarn deals"],
             bad_fit_threads: [] }]
}.to_json

bad_adapter = RubyLLM::Contract::Adapters::Test.new(response: bad_locale_response)
result = GenerateTargetAudience.run(input, context: { adapter: bad_adapter })

puts "=== BAD LOCALE (legacy code would let this pass) ==="
puts "Status: #{result.status}"
puts "Validation errors: #{result.validation_errors}"
puts

# Bad path — empty/garbage groups (cascade failure source)
empty_groups_response = {
  locale: "en",
  description: "A website.",
  groups: []
}.to_json

empty_adapter = RubyLLM::Contract::Adapters::Test.new(response: empty_groups_response)
result = GenerateTargetAudience.run(input, context: { adapter: empty_adapter })

puts "=== EMPTY GROUPS (would poison all downstream stages) ==="
puts "Status: #{result.status}"
puts "Validation errors: #{result.validation_errors}"
puts

# The key insight: in a pipeline, you check result.ok? before proceeding
puts "=== CASCADE PREVENTION ==="
puts "if result.failed? → don't run SearchExpansion, ThreadClassification, CommentGeneration"
puts "Legacy code would silently pass bad data to 6 more LLM calls, wasting tokens and producing garbage."
