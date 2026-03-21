# frozen_string_literal: true

# =============================================================================
# EXAMPLE 1: Thread Classification (PROMO / FILLER / SKIP)
#
# Real-world case: A Reddit promotion planner needs to classify threads
# into PROMO (worth commenting with a product link), FILLER (worth a
# genuine comment without product mention), or SKIP (irrelevant).
# =============================================================================

require_relative "../lib/ruby_llm/contract"

# =============================================================================
# BEFORE: Legacy approach (inline heredoc + ad-hoc validation)
# =============================================================================
#
# In the legacy codebase, this lives across multiple concern files:
# - classification_prompts.rb (prompt building)
# - thread_classification.rb (LLM calling + parsing)
# - llm_result_mapper.rb (ID matching with positional fallback)
#
# ```ruby
# # classification_prompts.rb
# def build_classify_prompt(items)
#   <<~PROMPT
#     #{classify_product_header}
#     #{classify_sitemap_section}
#     Classify each Reddit thread below for this product's promotion campaign.
#
#     For each thread, decide:
#     #{classify_decision_rules}
#
#     IMPORTANT: Be careful with PROMO. Follow these rules:
#     #{classify_promo_caution_rules}
#
#     Also provide:
#     #{classify_output_fields}
#
#     Threads:
#     #{items.to_json}
#   PROMPT
# end
#
# # thread_classification.rb
# def classify_batch_via_llm(batch)
#   items = build_classify_items(batch)
#   prompt = build_classify_prompt(items)
#   response = ai_call(prompt, schema: classify_response_schema)
#   parsed = parse_llm_json(response)
#   # Manual ID matching with positional fallback (masks errors!)
#   map_llm_results_by_id(items, parsed["threads"])
# end
# ```
#
# PROBLEMS:
# - Prompt is a string concatenation of 6 helper methods
# - No contract on output — if model returns wrong enum, it silently propagates
# - ID matching has a positional fallback that masks when model rewrites IDs
# - No way to test prompt quality without hitting the API
# - Change one line in classify_promo_caution_rules → no idea what broke

# =============================================================================
# AFTER: ruby_llm-contract approach
# =============================================================================

class ClassifyThreads < RubyLLM::Contract::Step::Base
  input_type  RubyLLM::Contract::Types::Array.of(RubyLLM::Contract::Types::Hash)
  output_type RubyLLM::Contract::Types::Array.of(RubyLLM::Contract::Types::Hash)

  prompt do
    system "You classify Reddit threads for a product promotion campaign."

    rule "For each thread, classify as PROMO, FILLER, or SKIP."
    rule "PROMO: thread author has a problem where the product helps naturally."
    rule "FILLER: related to domain, good for a genuine comment without product mention."
    rule "SKIP: irrelevant, low engagement, hostile to recommendations, grief/politics."
    rule "Return a JSON array with id, classification, relevance_score (0-10), and thread_intent."
    rule "thread_intent must be one of: seeking_help, sharing, discussion, venting."

    section "SCORING GUIDE", <<~GUIDE
      8-10: Clear problem/situation the product solves
      5-7: Author is in target audience, link would fit naturally
      2-4: Same broad domain but weak connection
      0-1: Irrelevant
    GUIDE

    user "{input}"
  end

  # Structural: every input ID must appear in output
  validate("all thread IDs must match input") do |output, input|
    output.map { |r| r[:id] }.sort == input.map { |t| t[:id] }.sort
  end

  # Enum: classification must be valid
  validate("classification must be PROMO, FILLER, or SKIP") do |output|
    output.all? { |r| %w[PROMO FILLER SKIP].include?(r[:classification]) }
  end

  # Consistency: PROMO threads must have decent relevance
  validate("PROMO threads must have relevance_score >= 5") do |output|
    output.select { |r| r[:classification] == "PROMO" }
          .all? { |r| r[:relevance_score].is_a?(Integer) && r[:relevance_score] >= 5 }
  end

  # Enum: thread_intent must be valid
  validate("thread_intent must be valid") do |output|
    valid = %w[seeking_help sharing discussion venting]
    output.all? { |r| valid.include?(r[:thread_intent]) }
  end
end

# =============================================================================
# AFTER + SCHEMA: output_schema replaces structural invariants
#
# Compare with the version above:
# - classification enum → schema
# - thread_intent enum → schema
# - relevance_score type/range → schema
# - ID matching → still an invariant (cross-validation with input)
# - PROMO score check → still an invariant (conditional logic)
# =============================================================================

class ClassifyThreadsWithSchema < RubyLLM::Contract::Step::Base
  input_type  RubyLLM::Contract::Types::Array.of(RubyLLM::Contract::Types::Hash)

  output_schema do
    array :threads do
      string :id
      string :classification, enum: %w[PROMO FILLER SKIP]
      integer :relevance_score, minimum: 0, maximum: 10
      string :thread_intent, enum: %w[seeking_help sharing discussion venting]
    end
  end

  prompt do
    system "You classify Reddit threads for a product promotion campaign."

    rule "For each thread, classify as PROMO, FILLER, or SKIP."
    rule "PROMO: thread author has a problem where the product helps naturally."
    rule "FILLER: related to domain, good for a genuine comment without product mention."
    rule "SKIP: irrelevant, low engagement, hostile to recommendations, grief/politics."
    rule "Return JSON with a threads array. Each entry: id, classification, relevance_score (0-10), thread_intent."
    rule "thread_intent must be one of: seeking_help, sharing, discussion, venting."

    section "SCORING GUIDE", <<~GUIDE
      8-10: Clear problem/situation the product solves
      5-7: Author is in target audience, link would fit naturally
      2-4: Same broad domain but weak connection
      0-1: Irrelevant
    GUIDE

    user "{input}"
  end

  # Only custom business logic — structural constraints are in the schema
  validate("all thread IDs must match input") do |output, input|
    output[:threads].map { |r| r[:id] }.sort == input.map { |t| t[:id] }.sort
  end

  validate("PROMO threads must have relevance_score >= 5") do |output|
    output[:threads].select { |r| r[:classification] == "PROMO" }
          .all? { |r| r[:relevance_score] >= 5 }
  end
end

# =============================================================================
# DEMO: Run with test adapter
# =============================================================================

sample_threads = [
  { id: "t1", subreddit: "crochet", title: "spent way too much on yarn this month lol", selftext: "anyone else?" },
  { id: "t2", subreddit: "gaming", title: "my cat destroyed my controller", selftext: "RIP" },
  { id: "t3", subreddit: "deals", title: "best craft supply deals?", selftext: "looking for yarn and fabric sales" }
]

# Happy path — valid response
valid_response = [
  { id: "t1", classification: "PROMO", relevance_score: 7, thread_intent: "venting", matched_page: "/yarn-deals" },
  { id: "t2", classification: "SKIP", relevance_score: 1, thread_intent: "venting", matched_page: "" },
  { id: "t3", classification: "PROMO", relevance_score: 9, thread_intent: "seeking_help", matched_page: "/craft-deals" }
].to_json

adapter = RubyLLM::Contract::Adapters::Test.new(response: valid_response)
result = ClassifyThreads.run(sample_threads, context: { adapter: adapter, model: "gpt-5-mini" })

puts "=== HAPPY PATH ==="
puts "Status: #{result.status}"
puts "Parsed output: #{result.parsed_output.map { |r| "#{r[:id]}=#{r[:classification]}" }.join(", ")}"
puts "Validation errors: #{result.validation_errors}"
puts

# Bad path — model returns wrong enum
bad_response = [
  { id: "t1", classification: "MAYBE", relevance_score: 7, thread_intent: "venting" },
  { id: "t2", classification: "SKIP", relevance_score: 1, thread_intent: "venting" },
  { id: "t3", classification: "PROMO", relevance_score: 9, thread_intent: "seeking_help" }
].to_json

bad_adapter = RubyLLM::Contract::Adapters::Test.new(response: bad_response)
result = ClassifyThreads.run(sample_threads, context: { adapter: bad_adapter })

puts "=== BAD ENUM ==="
puts "Status: #{result.status}"
puts "Validation errors: #{result.validation_errors}"
puts

# Bad path — model rewrites IDs (the silent bug legacy code masked with positional fallback)
rewritten_ids_response = [
  { id: "thread_1", classification: "PROMO", relevance_score: 7, thread_intent: "venting" },
  { id: "thread_2", classification: "SKIP", relevance_score: 1, thread_intent: "venting" },
  { id: "thread_3", classification: "PROMO", relevance_score: 9, thread_intent: "seeking_help" }
].to_json

rewritten_adapter = RubyLLM::Contract::Adapters::Test.new(response: rewritten_ids_response)
result = ClassifyThreads.run(sample_threads, context: { adapter: rewritten_adapter })

puts "=== REWRITTEN IDs (legacy code would silently fallback to positional matching) ==="
puts "Status: #{result.status}"
puts "Validation errors: #{result.validation_errors}"
