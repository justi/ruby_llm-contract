# frozen_string_literal: true

# =============================================================================
# EXAMPLE 4: SummarizeArticle pipeline — summarize, translate, review
#
# Real scenario: the UI card ships summaries in EN, but the product just
# launched a French region. Rather than re-prompting the LLM to summarise
# in French (quality drops), split the work:
#
#   1. Summarize — SummarizeArticle in English (the case already tuned for).
#   2. Translate — convert the English TL;DR + takeaways to French.
#   3. Review    — quality check: no untranslated terms, length fits UI.
#
# Pipeline::Base threads the output of step N into step N+1 automatically,
# fails fast on any step, and aggregates the trace. Each step uses a
# different LLM skill (analysis / creative / evaluation) — a single prompt
# asking the model to do all three at once loses to this chain.
#
# Run: ruby examples/04_summarize_and_translate.rb
# =============================================================================

require_relative "../lib/ruby_llm/contract"

# =============================================================================
# Step 1 — SummarizeArticle (English, unchanged from README)
# =============================================================================

class SummarizeArticle < RubyLLM::Contract::Step::Base
  prompt <<~PROMPT
    Summarize this article for a UI card. Return a short TL;DR,
    3 to 5 key takeaways, and a tone label.

    {input}
  PROMPT

  output_schema do
    string :tldr, max_length: 200
    array  :takeaways, of: :string, min_items: 3, max_items: 5
    string :tone, enum: %w[neutral positive negative analytical]
  end

  validate("TL;DR fits the card") { |o, _| o[:tldr].length <= 200 }
end

# =============================================================================
# Step 2 — Translate the English summary into the target language
# =============================================================================

class TranslateSummary < RubyLLM::Contract::Step::Base
  input_type Hash

  prompt do
    system "Translate a UI summary to the target language. Preserve tone label exactly."
    rule   "Return JSON with translated tldr, translated takeaways, unchanged tone."
    rule   "Keep brand names, product names, and URLs untranslated."
    rule   "TL;DR must stay under 200 characters in the target language."
    user   "Target language: fr\n\nSummary JSON:\n{tldr}\n{takeaways}\n{tone}"
  end

  output_schema do
    string :tldr, max_length: 200
    array  :takeaways, of: :string, min_items: 3, max_items: 5
    string :tone, enum: %w[neutral positive negative analytical]
  end

  validate("tone preserved") { |o, input| o[:tone] == input[:tone] }

  validate("takeaway count preserved") do |output, input|
    output[:takeaways].size == input[:takeaways].size
  end
end

# =============================================================================
# Step 3 — Review the translation: no untranslated terms, verdicts per takeaway
# =============================================================================

class ReviewTranslation < RubyLLM::Contract::Step::Base
  input_type Hash

  prompt do
    system "Review a French translation of a UI summary for quality."
    rule   "Flag any English words that should have been translated (exclude proper nouns and URLs)."
    rule   "Return JSON with overall_verdict (pass/warning/fail) and per-takeaway review."
    user   "Translation:\n{tldr}\n{takeaways}"
  end

  output_schema do
    string :overall_verdict, enum: %w[pass warning fail]
    array  :reviews, min_items: 1 do
      object do
        integer :takeaway_index, minimum: 0
        string  :verdict, enum: %w[pass warning fail]
        string  :issue, description: "Empty if pass"
      end
    end
  end

  validate("fail verdicts include an issue description") do |o, _|
    o[:reviews].reject { |r| r[:verdict] == "pass" }.all? { |r| !r[:issue].to_s.strip.empty? }
  end
end

# =============================================================================
# Pipeline: summarise → translate → review
# =============================================================================

class TranslatedSummaryPipeline < RubyLLM::Contract::Pipeline::Base
  step SummarizeArticle,   as: :summarise
  step TranslateSummary,   as: :translate
  step ReviewTranslation,  as: :review
end

# =============================================================================
# Demo with the Test adapter — each step gets its own canned response
# =============================================================================

adapter = RubyLLM::Contract::Adapters::Test.new(responses: [
  { tldr: "Ruby 3.4 ships frozen string literals, YJIT speedups, parser fixes.",
    takeaways: ["Frozen string literals default", "YJIT Rails speedups", "Parser fixes"],
    tone: "analytical" },
  { tldr: "Ruby 3.4 arrive avec les littéraux de chaînes figés, des gains YJIT, des corrections d'analyseur.",
    takeaways: ["Littéraux de chaînes figés par défaut", "YJIT accélère Rails", "Corrections de l'analyseur"],
    tone: "analytical" },
  { overall_verdict: "pass",
    reviews: [
      { takeaway_index: 0, verdict: "pass", issue: "" },
      { takeaway_index: 1, verdict: "pass", issue: "" },
      { takeaway_index: 2, verdict: "pass", issue: "" }
    ] }
])

ARTICLE = "Ruby 3.4 ships with frozen string literals on by default, measurable YJIT speedups on Rails workloads, parser fixes, and faster keyword argument handling."

result = TranslatedSummaryPipeline.run(ARTICLE, context: { adapter: adapter })

puts "Pipeline: #{result.ok? ? "ok" : "failed"}"                      # => Pipeline: ok
puts "Final TL;DR (FR):  #{result.outputs_by_step[:translate][:tldr]}" # => "Ruby 3.4 arrive avec ..."
puts "Review verdict:    #{result.outputs_by_step[:review][:overall_verdict]}" # => pass
puts "Total cost:        $#{result.trace.total_cost || '0.0 (Test adapter)'}"  # => real cost under Adapters::RubyLLM

# Example console output (with Test adapter):
#
#   Pipeline: ok
#   Final TL;DR (FR):  Ruby 3.4 arrive avec les littéraux de chaînes figés, des gains YJIT, ...
#   Review verdict:    pass
#   Total cost:        $0.0 (Test adapter)

# =============================================================================
# Evaluating the whole pipeline
#
# A pipeline can run against a dataset the same way a single step does.
# The `expected:` hash matches the FINAL step's output — here the review
# verdict — so a regression anywhere along the chain shows up in one place.
# =============================================================================

TranslatedSummaryPipeline.define_eval("smoke") do
  add_case "release post",
           input: "Ruby 3.4 ships with frozen string literals, YJIT speedups, parser fixes.",
           expected: { overall_verdict: "pass" }
end

# One Test adapter response per step in order (summarise → translate → review):
eval_adapter = RubyLLM::Contract::Adapters::Test.new(responses: [
  { tldr: "Ruby 3.4 ships frozen string literals, YJIT speedups, parser fixes.",
    takeaways: %w[frozen-strings yjit parser-fixes], tone: "analytical" },
  { tldr: "Ruby 3.4 arrive avec les littéraux de chaînes figés, des gains YJIT, ...",
    takeaways: %w[lit-figes yjit-fr parser-fr], tone: "analytical" },
  { overall_verdict: "pass",
    reviews: [{ takeaway_index: 0, verdict: "pass", issue: "" }] }
])

report = TranslatedSummaryPipeline.run_eval("smoke", context: { adapter: eval_adapter })
puts "\nEval score:      #{report.score}"           # => 1.0
puts "Eval pass rate:  #{report.pass_rate}"         # => 1/1
puts "Eval passed?:    #{report.passed?}"           # => true

# Example console output (with Test adapter):
#
#   Eval score:      1.0
#   Eval pass rate:  1/1
#   Eval passed?:    true

# =============================================================================
# What this showcases
#
# - Pipeline::Base composes steps; data threads automatically from
#   outputs_by_step[:summarise] into the translate step's inputs.
# - Different LLM skills per step (analysis / creative / evaluation) —
#   one prompt asking for all three at once loses accuracy.
# - Fail-fast: if SummarizeArticle's "TL;DR fits the card" validate
#   rejects, the translate and review steps never run — no downstream
#   tokens wasted.
# - A pipeline has its own `define_eval` + `run_eval` pair; expectations
#   match the final step's output, catching end-to-end regressions in one
#   dataset instead of per-step duplicates.
# =============================================================================
