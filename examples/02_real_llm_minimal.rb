# frozen_string_literal: true

# =============================================================================
# EXAMPLE 2: Swap the Test adapter for a real LLM — the one-liner
#
# Take any contract step from the other examples, point ruby_llm at your
# provider, and pass Adapters::RubyLLM.new in context. The step itself does
# not change — same prompt, schema, validates, retry_policy.
#
# Requires: gem install ruby_llm; export OPENAI_API_KEY=sk-...
# (Or an Anthropic / Gemini / Mistral key, or a local Ollama server.)
#
# Run: OPENAI_API_KEY=sk-... ruby examples/02_real_llm_minimal.rb
# =============================================================================

require_relative "../lib/ruby_llm/contract"

RubyLLM.configure { |c| c.openai_api_key = ENV.fetch("OPENAI_API_KEY") }

class SummarizeArticle < RubyLLM::Contract::Step::Base
  prompt "Summarize for a UI card (short TL;DR, 3-5 takeaways, tone). {input}"

  output_schema do
    string :tldr, max_length: 200
    array  :takeaways, of: :string, min_items: 3, max_items: 5
    string :tone, enum: %w[neutral positive negative analytical]
  end

  retry_policy models: %w[gpt-5-nano gpt-5-mini gpt-5]
end

article = "Ruby 3.4 ships frozen string literals by default, YJIT speedups, parser fixes."
adapter = RubyLLM::Contract::Adapters::RubyLLM.new
result  = SummarizeArticle.run(article, context: { adapter: adapter })

puts "Status:      #{result.status}"                 # => ok
puts "Final model: #{result.trace[:model]}"          # => "gpt-5-nano" (or mini/gpt-5 after fallback)
puts "Latency:     #{result.trace[:latency_ms]}ms"   # real network time
puts "Tokens:      #{result.trace[:usage]}"          # real usage
puts "Cost:        $#{result.trace[:cost]}"          # sum across retries
puts "TL;DR:       #{result.parsed_output[:tldr]}"

# Switch provider per call — ruby_llm resolves the provider from the model name:
#   SummarizeArticle.run(article, context: { adapter: adapter, model: "claude-sonnet-4-6" })
#   SummarizeArticle.run(article, context: { adapter: adapter, model: "gemma3:4b" })  # local Ollama
