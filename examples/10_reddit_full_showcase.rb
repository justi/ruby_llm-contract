# frozen_string_literal: true

# =============================================================================
# Reddit Promo Pipeline — 5-step campaign from URL to comment
#
# A real-world pipeline that takes a product URL and produces a natural
# Reddit comment ready to post. Each step has a contract that catches
# the kind of failures LLMs actually produce in production.
#
#   ruby examples/10_reddit_full_showcase.rb
# =============================================================================

require_relative "../lib/prompt_contract"

# ===========================================================================
# Step 1 — Analyze the product
#
# Takes a plain String URL. Returns audience profile.
# Contract catches: invalid locale ("USA" instead of "en"), vague audiences.
# ===========================================================================

class AnalyzeProduct < RubyLLM::Contract::Step::Base
  output_schema do
    string :product_description, description: "What the product does (1-2 sentences)"
    string :locale, description: "ISO 639-1 language code"
    string :audience_group_1
    string :audience_group_2
    string :audience_group_3
  end

  prompt <<~PROMPT
    You are a marketing analyst. Analyze the product and identify target audiences.
    locale must be a 2-letter ISO 639-1 code (en, pl, de), NOT a country name.
    Audience groups must be specific, not generic.

    {input}
  PROMPT

  max_input 3_000  # refuse before LLM call if prompt too large
  max_cost 0.01    # refuse before LLM call if estimated cost > $0.01

  validate("locale is valid ISO 639-1") { |o| o[:locale].to_s.match?(/\A[a-z]{2}\z/) }
  validate("description is substantive") { |o| o[:product_description].to_s.split.size >= 5 }
  validate("audience groups are specific") do |o|
    [o[:audience_group_1], o[:audience_group_2], o[:audience_group_3]].all? { |g| g.to_s.size > 5 }
  end
end

# ===========================================================================
# Step 2 — Find subreddits and a sample thread
#
# Receives the audience profile, returns subreddits + a thread to work with.
# Contract catches: empty subreddit names, missing thread language.
# ===========================================================================

class IdentifySubreddits < RubyLLM::Contract::Step::Base
  input_type Hash

  output_schema do
    string :product_description
    string :locale
    string :subreddit_1
    string :subreddit_2
    string :subreddit_3
    string :thread_title, description: "A representative thread title"
    string :thread_selftext, description: "Thread body text"
    string :thread_subreddit
    string :thread_language, description: "ISO 639-1 code of the thread's language"
  end

  prompt <<~PROMPT
    You are a Reddit marketing researcher.
    Find subreddits where the target audience hangs out.
    Pick one representative thread that would be perfect for a product mention.
    Pass through product_description and locale from input.

    SUBREDDIT CRITERIA:
    - Active community (>10k members)
    - Allows product discussions
    - Not hostile to recommendations

    {input}
  PROMPT

  validate("has subreddits") do |o|
    [o[:subreddit_1], o[:subreddit_2], o[:subreddit_3]].all? { |s| s.to_s.size >= 2 }
  end
  validate("thread has content") { |o| o[:thread_title].to_s.size > 5 }
  validate("thread language is valid") { |o| o[:thread_language].to_s.match?(/\A[a-z]{2}\z/) }
end

# ===========================================================================
# Step 3 — Classify the thread
#
# PROMO / FILLER / SKIP with relevance score.
# Uses `validate` and a 2-arity invariant that cross-checks the output
# language against the input language.
# Contract catches: PROMO with score 2, SKIP with score 8, wrong language.
# ===========================================================================

class ClassifyThread < RubyLLM::Contract::Step::Base
  input_type Hash

  # Block DSL because we use `example` (few-shot learning)
  prompt do
    system "You are a thread classifier for Reddit marketing."
    rule "Classify the thread as PROMO, FILLER, or SKIP based on product relevance."
    rule "Return JSON with: classification, relevance_score (1-10), reasoning, thread_title, thread_language."
    rule "PROMO: score >= 6. FILLER: 3-5. SKIP: 1-2."

    example input: '{"thread_title":"Best invoicing tool?","product_description":"invoicing SaaS"}',
            output: '{"classification":"PROMO","relevance_score":9,"reasoning":"Direct fit","thread_title":"Best invoicing tool?","thread_language":"en"}'

    user "{input}"
  end

  validate("valid classification") { |o| %w[PROMO FILLER SKIP].include?(o[:classification]) }
  validate("relevance score in range") { |o| o[:relevance_score].is_a?(Integer) && o[:relevance_score].between?(1, 10) }
  validate("PROMO score >= 6") { |o| o[:classification] != "PROMO" || o[:relevance_score] >= 6 }
  validate("SKIP score <= 2") { |o| o[:classification] != "SKIP" || o[:relevance_score] <= 2 }

  validate("thread language preserved from input") do |output, input|
    next true unless input.is_a?(Hash) && input[:thread_language]

    output[:thread_language] == input[:thread_language]
  end
end

# ===========================================================================
# Step 4 — Plan the comment
#
# Decides approach, tone, and key points before writing.
# Contract catches: missing strategy, invalid tone.
# ===========================================================================

class PlanComment < RubyLLM::Contract::Step::Base
  input_type Hash

  prompt <<~PROMPT
    You are a Reddit comment strategist.
    Plan a helpful, non-spammy comment for the classified thread.
    Return JSON with: approach, tone, key_points, link_strategy, thread_title.

    GUIDELINES:
    - Never use aggressive marketing language.
    - Be genuinely helpful first.
    - Mention product naturally.

    TONE OPTIONS:
    - casual — peer sharing experience
    - professional — industry expert
    - empathetic — I had the same problem

    {input}
  PROMPT

  validate("has approach") { |o| o[:approach].to_s.size > 5 }
  validate("valid tone") { |o| %w[casual professional empathetic].include?(o[:tone]) }
  validate("has link strategy") { |o| o[:link_strategy].to_s.size > 3 }
end

# ===========================================================================
# Step 5 — Write the comment
#
# Retry policy: starts with gpt-4.1-nano (cheap), escalates to mini then
# full if the contract catches problems. In practice, nano often writes
# comments that are too short or forget the link.
# Contract catches: spam phrases, banned openings, missing links, too short.
# ===========================================================================

class GenerateComment < RubyLLM::Contract::Step::Base
  input_type Hash

  # Block DSL here because we use `example` (few-shot) — needs user/assistant pairs.
  # Steps without examples use plain heredoc (see AnalyzeProduct, PlanComment above).
  prompt do
    system "You are a helpful Reddit commenter promoting a SaaS product."
    rule "Write the comment based on the plan."
    rule "Return JSON with: comment, word_count (integer)."
    rule "No markdown headers. No emojis. No bullet lists."
    rule "Include https://acme-invoice.com naturally, maximum once."

    section "ANTI-SPAM",
            "Never use: buy now, limited offer, click here, act fast, discount.\n" \
            "Never start with: Great question!, As a, I'm an AI, Hey there!"

    example input: '{"approach":"share experience","tone":"casual"}',
            output: '{"comment":"I switched to Acme Invoice last year and it cut my invoicing time ' \
                    'in half. The automatic reminders are a lifesaver. https://acme-invoice.com if ' \
                    'you want to check it out.","word_count":30}'

    user "{input}"
  end

  validate("comment long enough") { |o| o[:comment].to_s.strip.size > 30 }
  validate("no markdown headers") { |o| !o[:comment].to_s.match?(/^\#{2,}/) }
  validate("has word count") { |o| o[:word_count].is_a?(Integer) && o[:word_count] > 0 }
  validate("contains product link") { |o| o[:comment].to_s.include?("acme-invoice.com") }
  validate("no spam phrases") do |o|
    spam = ["buy now", "limited offer", "click here", "act fast", "discount"]
    spam.none? { |s| o[:comment].to_s.downcase.include?(s) }
  end
  validate("no banned openings") do |o|
    banned = ["Great question", "As a", "I'm an AI", "Hey there!", "Check this out"]
    banned.none? { |b| o[:comment].to_s.start_with?(b) }
  end

  max_output 300  # tokens — don't let the model ramble

  retry_policy models: %w[gpt-4.1-nano gpt-4.1-mini gpt-4.1]
end

# ===========================================================================
# Pipeline — wires the 5 steps together, with per-step model hints
# ===========================================================================

class RedditPromoPipeline < RubyLLM::Contract::Pipeline::Base
  step AnalyzeProduct,     as: :analyze,    model: "gpt-4.1-mini"
  step IdentifySubreddits, as: :subreddits, model: "gpt-4.1-mini"
  step ClassifyThread,     as: :classify,   model: "gpt-4.1-nano"
  step PlanComment,        as: :plan,       model: "gpt-4.1-nano"
  step GenerateComment,    as: :comment  # uses retry_policy escalation

  token_budget 15_000  # max tokens across all steps — halt if exceeded
end

# ===========================================================================
# Eval — defined OUTSIDE the step class (like specs live outside models)
# In production: eval/generate_comment_eval.rb
# ===========================================================================

GenerateComment.define_eval("smoke") do
  default_input({
    approach: "Share personal experience with invoicing frustration, then mention Acme Invoice",
    tone: "casual",
    key_points: '["empathize","mention recurring invoices","highlight reminders"]',
    link_strategy: "Drop link naturally after mentioning the tool",
    thread_title: "What invoicing tool do you use?"
  })

  sample_response({
    comment: "I was in the exact same boat — spreadsheets worked until I had more than " \
             "10 clients, then tracking who paid became a nightmare. I switched to Acme " \
             "Invoice about a year ago and it's been great. Recurring invoices are " \
             "set-and-forget, and the automatic payment reminders saved me so many awkward " \
             "follow-up emails. It's affordable too. https://acme-invoice.com if you want " \
             "to check it out.",
    word_count: 62
  })

  # Zero verify needed — step's validate blocks already check:
  # comment long enough, no markdown headers, has word count,
  # contains product link, no spam phrases, no banned openings.
end

# ===========================================================================
# Simulated LLM responses (what a real model would return)
# ===========================================================================

RESPONSES = {
  analyze: {
    product_description: "Simple invoicing and billing platform for freelancers and small businesses",
    locale: "en",
    audience_group_1: "freelance designers and developers",
    audience_group_2: "small business owners under 10 employees",
    audience_group_3: "accountants serving freelance clients" },

  subreddits: {
    product_description: "Simple invoicing and billing platform for freelancers",
    locale: "en",
    subreddit_1: "freelance", subreddit_2: "smallbusiness", subreddit_3: "Entrepreneur",
    thread_title: "What invoicing tool do you use for your freelance business?",
    thread_selftext: "I've been using spreadsheets but it's getting out of hand. " \
                     "Need something for recurring invoices and payment reminders.",
    thread_subreddit: "freelance",
    thread_language: "en" },

  classify: {
    classification: "PROMO", relevance_score: 9,
    reasoning: "Thread directly asks for invoicing tool — perfect fit",
    thread_title: "What invoicing tool do you use for your freelance business?",
    thread_language: "en" },

  plan: {
    approach: "Share personal experience with invoicing frustration, then mention Acme Invoice",
    tone: "casual",
    key_points: '["empathize with spreadsheet pain","mention recurring invoices",' \
                '"highlight payment reminders","note affordability"]',
    link_strategy: "Drop link naturally after mentioning the tool by name",
    thread_title: "What invoicing tool do you use for your freelance business?" },

  comment: {
    comment: "I was in the exact same boat — spreadsheets worked until I had more than " \
             "10 clients, then tracking who paid became a nightmare. I switched to Acme " \
             "Invoice about a year ago and it's been great. Recurring invoices are " \
             "set-and-forget, and the automatic payment reminders saved me so many awkward " \
             "follow-up emails. It's affordable too. https://acme-invoice.com if you want " \
             "to check it out.",
    word_count: 62 }
}.freeze

# ===========================================================================
# Run — Pipeline.test with named responses (no adapter setup needed)
# ===========================================================================

result = RedditPromoPipeline.test(
  "https://acme-invoice.com — Simple invoicing for freelancers",
  responses: RESPONSES
)

# ===========================================================================
# Results
# ===========================================================================

puts result
# Pipeline: ok  5 steps  0ms  0+0 tokens  $0.000000  trace=...
#   analyze        ok         gpt-4.1-mini 0ms 0+0 tokens $0.000000
#   subreddits     ok         gpt-4.1-mini 0ms 0+0 tokens $0.000000
#   classify       ok         gpt-4.1-nano 0ms 0+0 tokens $0.000000
#   plan           ok         gpt-4.1-nano 0ms 0+0 tokens $0.000000
#   comment        ok         gpt-4.1-nano 0ms 0+0 tokens $0.000000
# (costs are $0 here because Test adapter reports 0 tokens —
#  with a real LLM you'd see actual costs from model registry)

puts

result.pretty_print
# +----------------------------------------------------------------------------------+
# | Pipeline: ok  5 steps  0ms  ...                                                  |
# +----------------+------------+----------------------------------------------------+
# | Step           | Status     | Output                                             |
# +----------------+------------+----------------------------------------------------+
# | analyze        | ok         | product_description: Simple invoicing and billi... |
# |                |            | locale: en                                         |
# |                |            | audience_group_1: freelance designers and devel... |
# +----------------+------------+----------------------------------------------------+
# | subreddits     | ok         | subreddit_1: freelance                             |
# |                |            | thread_title: What invoicing tool do you use fo... |
# +----------------+------------+----------------------------------------------------+
# | classify       | ok         | classification: PROMO                              |
# |                |            | relevance_score: 9                                 |
# |                |            | reasoning: Thread directly asks for invoicing t... |
# +----------------+------------+----------------------------------------------------+
# | plan           | ok         | approach: Share personal experience with invoic... |
# |                |            | tone: casual                                       |
# +----------------+------------+----------------------------------------------------+
# | comment        | ok         | comment: I was in the exact same boat — spreads... |
# |                |            | word_count: 62                                     |
# +----------------------------------------------------------------------------------+

puts

# ===========================================================================
# Quality check — zero setup, eval has its own sample_response
# ===========================================================================

puts GenerateComment.run_eval("smoke")
# smoke: 1/1 checks passed
