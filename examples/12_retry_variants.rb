# frozen_string_literal: true

# =============================================================================
# EXAMPLE 12: retry_policy variants — three shapes beyond cross-model
#
# Example 11 covered the most common pattern: fall back from a cheap model to a
# stronger one (gpt-5-nano → mini → gpt-5). This file runs the three other
# retry_policy shapes teams reach for, in sequence, with the Test adapter so
# no API keys are required.
#
# Run:
#   ruby examples/12_retry_variants.rb
#
# Expected output (abridged):
#
#   A — attempts: 3 (same model, sampling-variance absorption)
#       attempt 1  model=gpt-5-nano  status=validation_failed
#       attempt 2  model=gpt-5-nano  status=validation_failed
#       attempt 3  model=gpt-5-nano  status=ok
#
#   B — reasoning_effort escalation on one model
#       attempt 1  model=gpt-5-nano  effort=low     status=validation_failed
#       attempt 2  model=gpt-5-nano  effort=medium  status=validation_failed
#       attempt 3  model=gpt-5-nano  effort=high    status=ok
#
#   C — cross-provider fallback (Ollama → Anthropic → OpenAI)
#       attempt 1  model=gemma3:4b           status=validation_failed
#       attempt 2  model=claude-haiku-4-5    status=validation_failed
#       attempt 3  model=gpt-5-nano          status=ok
# =============================================================================

require_relative "../lib/ruby_llm/contract"

# Shared scenario: a trivial yes/no classifier. The Test adapter returns a
# deterministic sequence where the first two attempts fail a business rule
# and the third succeeds — so every retry variant lands on attempt 3 for
# the same reason (the validate check), not for different reasons.
class YesOrNo < RubyLLM::Contract::Step::Base
  model "gpt-5-nano"
  prompt "Answer {input} with yes or no only. Return JSON."

  output_schema do
    string :answer, enum: %w[yes no invalid]
  end

  validate("answer is not 'invalid'") { |o, _| o[:answer] != "invalid" }
end

RESPONSES = [
  { answer: "invalid" },
  { answer: "invalid" },
  { answer: "yes" }
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
# (e.g. temperature=1.0 enforced on gpt-5 / o-series) flips it occasionally.
# Re-sampling the same model absorbs that variance without paying for a
# stronger tier.
#
# Replaces:
#   attempts = 0
#   begin
#     response = LlmClient.call(prompt)
#     raise "bad answer" if response["answer"] == "invalid"
#     response
#   rescue => e
#     attempts += 1
#     retry if attempts < 3
#     raise
#   end
# =============================================================================

class YesOrNoSameModelRetry < YesOrNo
  retry_policy attempts: 3
end

puts "=" * 70
puts "A — attempts: 3 (same model, sampling-variance absorption)"
puts "=" * 70

adapter = RubyLLM::Contract::Adapters::Test.new(responses: RESPONSES)
result = YesOrNoSameModelRetry.run("is ruby great", context: { adapter: adapter })
print_trace("same-model retry", result)

# =============================================================================
# VARIANT B — reasoning_effort escalation on one model
#
# When to use: the model can get the answer right given more thinking budget,
# but you don't want to pay the high-reasoning price on every call. Start at
# `low`, let the validate filter out the cheap misses, and only pay for
# `medium` or `high` on the cases that actually need it.
#
# Replaces: reasoning_effort picked by guess once, then never revisited.
# =============================================================================

class YesOrNoReasoningEscalation < YesOrNo
  retry_policy models: [
    { model: "gpt-5-nano", reasoning_effort: "low" },
    { model: "gpt-5-nano", reasoning_effort: "medium" },
    { model: "gpt-5-nano", reasoning_effort: "high" }
  ]
end

puts "=" * 70
puts "B — reasoning_effort escalation (low → medium → high) on one model"
puts "=" * 70

adapter = RubyLLM::Contract::Adapters::Test.new(responses: RESPONSES)
result = YesOrNoReasoningEscalation.run("is ruby great", context: { adapter: adapter })
print_trace("reasoning escalation", result)

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
# Order matters: local first because it costs nothing; hosted last because
# they are the most accurate and the most expensive.
# =============================================================================

class YesOrNoCrossProvider < YesOrNo
  retry_policy models: %w[gemma3:4b claude-haiku-4-5 gpt-5-nano]
end

puts "=" * 70
puts "C — cross-provider fallback (Ollama → Anthropic → OpenAI)"
puts "=" * 70

adapter = RubyLLM::Contract::Adapters::Test.new(responses: RESPONSES)
result = YesOrNoCrossProvider.run("is ruby great", context: { adapter: adapter })
print_trace("cross-provider", result)

# =============================================================================
# TAKEAWAYS
#
# 1. `attempts: 3` is the shortest path from a hand-rolled begin/rescue/retry
#    loop to a contract-backed retry with a trace you can log.
# 2. `reasoning_effort` escalation is cheaper than model escalation when the
#    model is right but needs more thinking, not a stronger backbone.
# 3. Cross-provider retry uses the same DSL — ruby_llm resolves the provider
#    from the model name. Start with the cheapest (often a local Ollama
#    model) and end with the most accurate hosted provider.
# 4. The per-attempt trace (model, config, status, cost) is the same in every
#    variant. Your logging and metrics do not care which retry shape you
#    picked.
# =============================================================================
