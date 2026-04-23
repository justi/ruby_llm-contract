# frozen_string_literal: true

# =============================================================================
# EXAMPLE 4: Real LLM calls via ruby_llm
#
# Same SummarizeArticle step, one line changes to swap the Test adapter for
# Adapters::RubyLLM. The contract, prompt, schema, and validates are
# provider-agnostic — the step does not know or care which backend runs it.
#
# Requires: gem install ruby_llm; export OPENAI_API_KEY=sk-... (or configure
# another provider — Anthropic, Gemini, Ollama, etc. — ruby_llm resolves the
# provider from the model name).
#
# Run: ruby examples/01_real_llm.rb
# =============================================================================

require_relative "../lib/ruby_llm/contract"

RubyLLM::Contract.configure do |config|
  config.openai_api_key = ENV.fetch("OPENAI_API_KEY", nil)
  config.default_model = "gpt-5-mini"
end

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

  validate("TL;DR fits the card")  { |o, _| o[:tldr].length <= 200 }
  validate("takeaways are unique") { |o, _| o[:takeaways].uniq.size == o[:takeaways].size }

  retry_policy models: %w[gpt-5-nano gpt-5-mini gpt-5]
end

ARTICLE = <<~ARTICLE
  Ruby 3.4 ships with frozen string literals on by default, measurable YJIT
  speedups on Rails workloads, and tightened Warning.warn category filtering.
  Parser fixes and faster keyword argument handling land alongside.
ARTICLE

# =============================================================================
# Run against the real provider
# =============================================================================

puts "Calling LLM..."
result = SummarizeArticle.run(ARTICLE)

puts "Status:      #{result.status}"
puts "Final model: #{result.trace[:model]}"
puts "Latency:     #{result.trace[:latency_ms]}ms"
puts "Tokens:      #{result.trace[:usage]}"
puts "Cost:        $#{result.trace[:cost]}"
puts
puts "TL;DR:       #{result.parsed_output[:tldr]}"
puts "Takeaways:"
result.parsed_output[:takeaways].each { |t| puts "  - #{t}" }

# =============================================================================
# Switch provider with a context override — no code change to the step
# =============================================================================
#
# # Anthropic Claude:
# result = SummarizeArticle.run(ARTICLE, context: { model: "claude-sonnet-4-6" })
#
# # Local Ollama (no API key, requires ollama serve running):
# result = SummarizeArticle.run(ARTICLE, context: { model: "gemma3:4b" })
#
# Same step, same contract, different backend. The retry_policy list above
# can also mix providers — see examples/07_retry_variants.rb.
# =============================================================================
