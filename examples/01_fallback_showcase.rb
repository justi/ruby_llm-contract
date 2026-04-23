# frozen_string_literal: true

# =============================================================================
# EXAMPLE 1: Fallback showcase — see contracts work in 30 seconds
#
# This is the "why does this gem exist" demo, runnable with zero API keys.
# Uses the Test adapter to simulate a real production failure mode:
#
#   1. gpt-5-nano/mini and o-series run with temperature=1.0 server-side.
#      The SAME prompt on the SAME model returns different outputs across
#      calls. That is sampling variance, not a bug — it is the published
#      behaviour of these models.
#   2. One unlucky sample can flip a correct tone to an incorrect one
#      ("negative" → "positive" for an outage article). Schema passes
#      both; the wrong answer silently ships.
#   3. A validate block that cross-checks fields against each other turns
#      a flaky output into a deterministic rejection, and retry_policy
#      escalates to a stronger model for the retry.
#   4. The caller gets valid output plus a trace showing exactly what
#      happened across attempts.
#
# Run:
#   ruby examples/01_fallback_showcase.rb
#
# Expected output:
#
#   ======================================================================
#   A — Schema-only (no cross-check, no retry):
#   ======================================================================
#   status:        :ok            # schema passes — no guard
#   tone shipped:  "positive"
#   takeaway 1:    "Mesh networking hardware failed under load"
#                  ^^ takeaways describe a failure; tone says positive
#                  ^^ customer-success "critical feedback" filter misses this case
#
#   ======================================================================
#   B — Full contract (cross-check validate + retry_policy fallback):
#   ======================================================================
#   status:             :ok
#   final model:        "gpt-5-mini"
#   total attempts:     2
#
#   Per-attempt trace:
#     attempt 1  model=gpt-5-nano   status=validation_failed
#     attempt 2  model=gpt-5-mini   status=ok
#
#   Final parsed_output:
#     tldr:       "Mesh networking hardware failed under load; ..."
#     takeaways:  3 items
#     tone:       "negative"
#
# See also: examples/06_retry_variants.rb — same-model retry, reasoning_effort
# escalation, and cross-provider fallback (Ollama → Anthropic → OpenAI).
# =============================================================================

require_relative "../lib/ruby_llm/contract"

# The article being summarized — an outage complaint. The correct tone is
# "negative" (customer success routes these to a human).
ARTICLE = <<~ARTICLE
  The mesh networking hardware failed under load during the product launch.
  Two features crashed, the recovery took eight hours, and three enterprise
  customers threatened to churn. The post-incident review identified a
  single regression in the firmware update as the root cause.
ARTICLE

# What gpt-5-nano returns on an unlucky sample (temperature=1.0 cannot be
# lowered). Every field is schema-valid. Tone disagrees with the takeaways.
VARIANCE_RESPONSE = {
  tldr: "Product launch covered mesh networking hardware with three enterprise customers.",
  takeaways: [
    "Mesh networking hardware failed under load",
    "Two features crashed and recovery took eight hours",
    "Firmware regression identified as root cause"
  ],
  tone: "positive"
}.freeze

# What gpt-5-mini returns on retry — a consistent sample where tone matches
# the severity keywords in the takeaways.
GOOD_RESPONSE = {
  tldr: "Mesh networking hardware failed under load; firmware regression was the root cause.",
  takeaways: [
    "Mesh networking hardware failed under load during launch",
    "Two features crashed and recovery took eight hours",
    "Firmware regression identified as root cause; three customers threatened churn"
  ],
  tone: "negative"
}.freeze

# =============================================================================
# STEP 1 — Define the contract exactly as a production Rails app would
# =============================================================================

class SummarizeArticle < RubyLLM::Contract::Step::Base
  prompt <<~PROMPT
    Summarize this article for a UI card. Return a short TL;DR,
    3 to 5 key takeaways, and a tone label.

    {input}
  PROMPT

  output_schema do
    string :tldr
    array  :takeaways, of: :string, min_items: 3, max_items: 5
    string :tone, enum: %w[neutral positive negative analytical]
  end

  validate("TL;DR fits the card") { |o, _| o[:tldr].length <= 200 }

  # The key cross-check: if takeaways mention severity / failure keywords,
  # tone must reflect that. This catches tone/takeaways mismatch when the
  # model's sample drifts between calls. Expand the keyword list from your
  # own production failures; this is a demo.
  SEVERITY_PATTERN = /fail|crash|outage|broken|bug|error|regression/i.freeze
  validate("tone matches severity keywords") do |o, _|
    flagged = o[:takeaways].any? { |t| t.match?(SEVERITY_PATTERN) }
    next true unless flagged
    %w[negative analytical].include?(o[:tone])
  end

  retry_policy models: %w[gpt-5-nano gpt-5-mini gpt-5]
end

# =============================================================================
# PART A — SCHEMA-ONLY (no cross-check, no retry)
#
# Demonstrates what a "schema is enough" mindset gets you: the tone/takeaways
# mismatch passes every shape check and would be persisted by the caller,
# breaking the customer-success routing filter downstream.
# =============================================================================

class SummarizeArticleSchemaOnly < RubyLLM::Contract::Step::Base
  prompt "Summarize: {input}"

  output_schema do
    string :tldr
    array  :takeaways, of: :string, min_items: 3, max_items: 5
    string :tone, enum: %w[neutral positive negative analytical]
  end
end

puts "=" * 70
puts "A — Schema-only (no cross-check, no retry):"
puts "=" * 70

naive_adapter = RubyLLM::Contract::Adapters::Test.new(response: VARIANCE_RESPONSE)
naive_result = SummarizeArticleSchemaOnly.run(ARTICLE, context: { adapter: naive_adapter })

puts "status:        #{naive_result.status.inspect}            # schema passes — no guard"
puts "tone shipped:  #{naive_result.parsed_output[:tone].inspect}"
puts "takeaway 1:    #{naive_result.parsed_output[:takeaways].first.inspect}"
puts "               ^^ takeaways describe a failure; tone says positive"
puts "               ^^ customer-success \"critical feedback\" filter misses this case"
puts

# =============================================================================
# PART B — FULL CONTRACT: cross-check validate + retry_policy fallback
#
# The Test adapter returns:
#   attempt 1 (gpt-5-nano) — tone/takeaways mismatch from variance → rejected
#   attempt 2 (gpt-5-mini) — consistent sample             → passes
#
# retry_policy handles the escalation automatically.
# =============================================================================

puts "=" * 70
puts "B — Full contract (cross-check validate + retry_policy fallback):"
puts "=" * 70

adapter = RubyLLM::Contract::Adapters::Test.new(responses: [VARIANCE_RESPONSE, GOOD_RESPONSE])
result = SummarizeArticle.run(ARTICLE, context: { adapter: adapter })

puts "status:             #{result.status.inspect}"
puts "final model:        #{result.trace[:model].inspect}"
puts "total attempts:     #{result.trace[:attempts].size}"
puts

puts "Per-attempt trace:"
result.trace[:attempts].each do |a|
  puts "  attempt #{a[:attempt]}  model=#{a[:model].ljust(12)} status=#{a[:status]}"
end
puts

puts "Final parsed_output:"
puts "  tldr:       #{result.parsed_output[:tldr].inspect}"
puts "  takeaways:  #{result.parsed_output[:takeaways].size} items"
puts "  tone:       #{result.parsed_output[:tone].inspect}"
puts

# =============================================================================
# TAKEAWAYS
#
# 1. gpt-5 / o-series force temperature=1.0. Output variance is the published
#    behavior of these models — not a bug to fix.
# 2. Schema cannot catch a tone/takeaways mismatch — every field is the
#    right type. Only a cross-field validate can express "these fields
#    must agree".
# 3. retry_policy turns that rejection into an automatic escalation. Variance
#    is absorbed before the caller (or a customer-success routing filter)
#    ever sees the flaky sample.
# 4. result.trace[:attempts] gives you the per-attempt record for free, so
#    you can log retry rate and the cost delta from escalation.
#
# Replace the Test adapter with Adapters::RubyLLM (see Step 8 in
# examples/00_basics.rb for the one-liner) and this exact same code runs
# against a real provider or a local Ollama server.
# =============================================================================
