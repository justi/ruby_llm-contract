# frozen_string_literal: true

# =============================================================================
# EXAMPLE 0: SummarizeArticle — from plain prompt to full contract
#
# One step, seven incremental layers. Each layer adds exactly one capability
# and shows the line of code that unlocks it. Start at Step 1, read top to
# bottom, stop at the layer that matches your project.
# =============================================================================

require_relative "../lib/ruby_llm/contract"

ARTICLE = <<~ARTICLE
  Ruby 3.4 ships with frozen string literals on by default, measurable YJIT
  speedups on Rails workloads, and tightened Warning.warn category filtering.
  Parser fixes and faster keyword argument handling land alongside.
ARTICLE

CANNED = {
  tldr: "Ruby 3.4 brings frozen string literals by default, YJIT speedups, parser fixes.",
  takeaways: [
    "Frozen string literals are the default in Ruby 3.4",
    "YJIT delivers measurable Rails speedups",
    "Parser fixes and keyword argument handling improve"
  ],
  tone: "analytical"
}.freeze

RubyLLM::Contract.configure do |c|
  c.default_adapter = RubyLLM::Contract::Adapters::Test.new(response: CANNED)
end

# =============================================================================
# STEP 1 — Minimal: prompt + output_schema
# The step enforces JSON shape. No business rules yet, no retry.
# =============================================================================

class SummarizeArticleMinimal < RubyLLM::Contract::Step::Base
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
end

r = SummarizeArticleMinimal.run(ARTICLE)
r.status        # => :ok
r.parsed_output # => {tldr: "...", takeaways: [...], tone: "analytical"}

# =============================================================================
# STEP 2 — Add a business rule (validate) that schema cannot express
# Schema says "takeaways is an array of 3–5 strings". Nothing there says
# "uniqueness" or "TL;DR fits the card". That is what validate blocks are for.
# =============================================================================

class SummarizeArticleValidated < SummarizeArticleMinimal
  validate("TL;DR fits the card")  { |o, _| o[:tldr].length <= 200 }
  validate("takeaways are unique") { |o, _| o[:takeaways].uniq.size == o[:takeaways].size }
end

r = SummarizeArticleValidated.run(ARTICLE)
r.status             # => :ok
r.validation_errors  # => []

# =============================================================================
# STEP 3 — Structured prompt (prompt AST: system, rule, section, user)
# Replaces a heredoc. Individual nodes are reorderable, diffable, and
# inspectable — useful when the prompt grows beyond a few lines.
# =============================================================================

class SummarizeArticleStructured < RubyLLM::Contract::Step::Base
  prompt do
    system "You summarize articles for a UI card."
    rule   "Return valid JSON only."
    rule   "Keep the TL;DR under 200 characters."
    user   "{input}"
  end

  output_schema do
    string :tldr
    array  :takeaways, of: :string, min_items: 3, max_items: 5
    string :tone, enum: %w[neutral positive negative analytical]
  end
end

# =============================================================================
# STEP 4 — Hash input with variable interpolation
# When you need more than raw text (audience, language, tenant), take a Hash
# and reference its keys directly in the prompt.
# =============================================================================

class SummarizeArticleMultiField < RubyLLM::Contract::Step::Base
  input_type RubyLLM::Contract::Types::Hash.schema(
    article:  RubyLLM::Contract::Types::String,
    audience: RubyLLM::Contract::Types::String,
    language: RubyLLM::Contract::Types::String
  )

  prompt do
    system  "You summarize articles for a UI card."
    rule    "Write the TL;DR and takeaways in {language}."
    section "AUDIENCE", "{audience}"
    user    "{article}"
  end

  output_schema do
    string :tldr
    array  :takeaways, of: :string, min_items: 3, max_items: 5
    string :tone, enum: %w[neutral positive negative analytical]
  end
end

# =============================================================================
# STEP 5 — 2-arity validate: check the output against the input
# Catches "lazy" models that echo the article verbatim into the TL;DR.
# The block receives |output, input| — pass the input-side check too.
# =============================================================================

class SummarizeArticleFaithful < SummarizeArticleValidated
  validate("TL;DR is shorter than the article") do |output, input|
    output[:tldr].length < input.length / 2
  end
end

# =============================================================================
# STEP 6 — Retry with model fallback
# Start on the cheapest model. If validate or schema rejects the output,
# the gem automatically retries on the next model in the list.
# =============================================================================

class SummarizeArticleWithRetry < SummarizeArticleValidated
  retry_policy models: %w[gpt-5-nano gpt-5-mini gpt-5]
end

# =============================================================================
# STEP 7 — Inspect the Result: status, parsed_output, trace, per-attempt
# Every run returns a value object with everything you need to log, debug,
# or surface in an admin UI.
# =============================================================================

r = SummarizeArticleWithRetry.run(ARTICLE)
r.status             # => :ok
r.ok?                # => true
r.parsed_output      # => {tldr: "...", takeaways: [...], tone: "analytical"}
r.validation_errors  # => []
r.trace[:model]      # => "gpt-5-nano"   (first model that passed)
r.trace[:attempts]   # => [{attempt: 1, model: "gpt-5-nano", status: :ok, ...}]
r.trace[:cost]       # => sum of per-attempt costs

# =============================================================================
# STEP 8 — Swap the Test adapter for a real LLM
# The step itself does not change. Point ruby_llm at your provider and
# override the adapter via context (or set it globally).
# =============================================================================

# Provider setup (do once at boot):
#
#   RubyLLM.configure do |c|
#     c.openai_api_key = ENV.fetch("OPENAI_API_KEY")
#     # c.anthropic_api_key = ENV["ANTHROPIC_API_KEY"]
#   end
#
# Run against the real provider — same step, same contract:
#
#   result = SummarizeArticleWithRetry.run(article_text,
#     context: { adapter: RubyLLM::Contract::Adapters::RubyLLM.new })
#
# Switch provider per call — ruby_llm resolves the provider from the model name:
#
#   # Anthropic Claude:
#   SummarizeArticleWithRetry.run(article_text, context: { model: "claude-sonnet-4-6" })
#   # Local Ollama (no API key, requires `ollama serve`):
#   SummarizeArticleWithRetry.run(article_text, context: { model: "gemma3:4b" })

# =============================================================================
# Where to go next
#
# 01_summarize_with_keywords.rb — growing prompt: add a keywords field
# 02_eval_dataset.rb            — define_eval, add_case, regression detection
# 03_fallback_showcase.rb       — see the retry loop run with the Test adapter
# 04_retry_variants.rb          — attempts: 3, reasoning_effort, cross-provider
# =============================================================================
