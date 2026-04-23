# frozen_string_literal: true

# =============================================================================
# EXAMPLE 12: retry_policy variants on SummarizeArticle
#
# Example 11 covered the most common pattern: fall back from a cheap model
# to a stronger one (gpt-5-nano → mini → gpt-5). This file runs the three
# other retry_policy shapes, each on the same SummarizeArticle step with
# the Test adapter so no API keys are required.
#
# Run: ruby examples/07_retry_variants.rb
#
# Expected output (abridged):
#
#   A — attempts: 3 (same model, sampling-variance absorption)
#       attempt 1  model=gpt-5-nano  status=validation_failed
#       attempt 3  model=gpt-5-nano  status=ok
#
#   B — reasoning_effort low → medium → high (same model)
#       attempt 1  effort=low     status=validation_failed
#       attempt 3  effort=high    status=ok
#
#   C — cross-provider Ollama → Anthropic → OpenAI
#       attempt 1  model=gemma3:4b          status=validation_failed
#       attempt 3  model=gpt-5-nano         status=ok
# =============================================================================

require_relative "../lib/ruby_llm/contract"

# =============================================================================
# Base step — same SummarizeArticle from the README, used by every variant
# =============================================================================

class SummarizeArticle < RubyLLM::Contract::Step::Base
  model "gpt-5-nano"
  prompt "Summarize: {input}"

  output_schema do
    string :tldr, max_length: 200
    array  :takeaways, of: :string, min_items: 3, max_items: 5
    string :tone, enum: %w[neutral positive negative analytical]
  end

  validate("TL;DR fits the card") { |o, _| o[:tldr].length <= 200 }
end

# Canned responses — first two fail the "TL;DR fits the card" validate
# (oversized TL;DR), the third succeeds. Every variant lands on attempt 3,
# so the trace shows the retry policy's shape clearly.
RESPONSES = [
  { tldr: "x" * 500, takeaways: %w[a b c], tone: "neutral" },
  { tldr: "x" * 500, takeaways: %w[a b c], tone: "neutral" },
  { tldr: "Ruby 3.4 ships with frozen string literals and YJIT speedups.",
    takeaways: %w[frozen-strings yjit parser-fixes], tone: "analytical" }
].freeze

def print_trace(label, result)
  puts "#{label} — status=#{result.status}, final model=#{result.trace[:model].inspect}"
  result.trace[:attempts].each do |a|
    cfg = a[:config] && a[:config][:reasoning_effort] ? "  effort=#{a[:config][:reasoning_effort].ljust(6)}" : ""
    puts "    attempt #{a[:attempt]}  model=#{a[:model].ljust(20)}#{cfg}  status=#{a[:status]}"
  end
  puts
end

# =============================================================================
# VARIANT A — attempts: 3 on the same model
#
# When to use: the model is correct on most samples, but sampling variance
# (gpt-5 / o-series enforce temperature=1.0 server-side) flips it occasionally.
# Re-sampling the same model absorbs the variance without paying for a
# stronger tier.
#
# Replaces: the hand-rolled begin/rescue/retry loop with an attempts counter.
# =============================================================================

class SummarizeArticleSameModelRetry < SummarizeArticle
  retry_policy attempts: 3
end

puts "=" * 70
puts "A — attempts: 3 (same model, sampling-variance absorption)"
puts "=" * 70
adapter = RubyLLM::Contract::Adapters::Test.new(responses: RESPONSES)
print_trace("same-model retry", SummarizeArticleSameModelRetry.run("article", context: { adapter: adapter }))

# =============================================================================
# VARIANT B — reasoning_effort escalation on one model
#
# When to use: the model can get the right answer with more thinking budget,
# but you do not want to pay the high-reasoning price on every call. Start
# at low, let validate filter out the cheap misses, pay for medium or high
# only on the cases that actually need it.
# =============================================================================

class SummarizeArticleReasoningEscalation < SummarizeArticle
  retry_policy models: [
    { model: "gpt-5-nano", reasoning_effort: "low" },
    { model: "gpt-5-nano", reasoning_effort: "medium" },
    { model: "gpt-5-nano", reasoning_effort: "high" }
  ]
end

puts "=" * 70
puts "B — reasoning_effort escalation (low → medium → high)"
puts "=" * 70
adapter = RubyLLM::Contract::Adapters::Test.new(responses: RESPONSES)
print_trace("reasoning escalation", SummarizeArticleReasoningEscalation.run("article", context: { adapter: adapter }))

# =============================================================================
# VARIANT C — cross-provider fallback (Ollama → Anthropic → OpenAI)
#
# When to use: you want to start on a local model (cheap, private, no quota)
# and fall back to hosted providers only when the local one cannot satisfy
# the contract. Each tier is a different provider — ruby_llm detects the
# provider from the model name.
#
# To run against real backends: configure ruby_llm for all three providers
# (ollama_api_base + anthropic_api_key + openai_api_key) and swap the Test
# adapter for Adapters::RubyLLM. The retry_policy itself is unchanged.
#
# Order matters: local first (costs nothing); hosted last (most accurate).
# =============================================================================

class SummarizeArticleCrossProvider < SummarizeArticle
  retry_policy models: %w[gemma3:4b claude-haiku-4-5 gpt-5-nano]
end

puts "=" * 70
puts "C — cross-provider fallback (Ollama → Anthropic → OpenAI)"
puts "=" * 70
adapter = RubyLLM::Contract::Adapters::Test.new(responses: RESPONSES)
print_trace("cross-provider", SummarizeArticleCrossProvider.run("article", context: { adapter: adapter }))

# =============================================================================
# TAKEAWAYS
#
# 1. `attempts: 3` is the shortest path from a hand-rolled begin/rescue/retry
#    loop to a contract-backed retry with a trace you can log.
# 2. `reasoning_effort` escalation is cheaper than model escalation when the
#    model is right but needs more thinking, not a stronger backbone.
# 3. Cross-provider retry uses the same DSL — ruby_llm resolves the provider
#    from the model name. Start cheapest (often a local Ollama model), end
#    on the most accurate hosted provider.
# 4. The per-attempt trace (model, config, status, cost) is identical across
#    variants — your logging does not care which retry shape you picked.
# =============================================================================
