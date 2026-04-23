# frozen_string_literal: true

# =============================================================================
# EXAMPLE 9: Dataset-driven evals on SummarizeArticle
#
# The pattern that stops silent prompt regressions:
#   1. Define an eval with a handful of real articles and expected outcomes.
#   2. Run it on your current configuration — that is the baseline.
#   3. Change a prompt, swap a model, upgrade a gem — re-run.
#   4. A drop in score blocks the merge before it ships.
#
# Every piece of the workflow is shown in one file: define_eval, add_case
# with expected traits, running the eval, comparing a "good" to a "bad"
# model, and the inline eval_case helper for quick checks.
#
# Run: ruby examples/05_eval_dataset.rb
# =============================================================================

require_relative "../lib/ruby_llm/contract"

class SummarizeArticle < RubyLLM::Contract::Step::Base
  prompt "Summarize: {input}"

  output_schema do
    string :tldr, max_length: 200
    array  :takeaways, of: :string, min_items: 3, max_items: 5
    string :tone, enum: %w[neutral positive negative analytical]
  end

  validate("TL;DR fits the card") { |o, _| o[:tldr].length <= 200 }

  define_eval "regression" do
    add_case "ruby release",
             input: "Ruby 3.4 ships with frozen string literals, YJIT speedups, parser fixes.",
             expected: { tone: "analytical" }

    add_case "outage complaint",
             input: "The mesh hardware failed under load. Three customers threatened churn.",
             expected: { tone: "negative" }

    add_case "product launch",
             input: "We are thrilled to announce our new billing feature ships this week.",
             expected: { tone: "positive" }
  end
end

# =============================================================================
# Good run — every case lands on the expected tone
# =============================================================================

puts "=" * 60
puts "Run 1 — good configuration (baseline)"
puts "=" * 60

good_adapter = RubyLLM::Contract::Adapters::Test.new(responses: [
  { tldr: "Ruby 3.4 summary",   takeaways: %w[a b c], tone: "analytical" },
  { tldr: "Outage complaint",    takeaways: %w[a b c], tone: "negative" },
  { tldr: "Product launch news", takeaways: %w[a b c], tone: "positive" }
])

baseline = SummarizeArticle.run_eval("regression", context: { adapter: good_adapter })
puts "Score:      #{baseline.score.round(2)}"     # => 1.0
puts "Pass rate:  #{baseline.pass_rate}"          # => 3/3
puts "Passed?:    #{baseline.passed?}"            # => true

# =============================================================================
# Bad run — simulates a prompt tweak that broke "outage" classification
# =============================================================================

puts
puts "=" * 60
puts "Run 2 — a prompt tweak broke tone classification on complaints"
puts "=" * 60

bad_adapter = RubyLLM::Contract::Adapters::Test.new(responses: [
  { tldr: "Ruby 3.4 summary",   takeaways: %w[a b c], tone: "analytical" },
  { tldr: "Outage complaint",    takeaways: %w[a b c], tone: "analytical" }, # expected negative!
  { tldr: "Product launch news", takeaways: %w[a b c], tone: "positive" }
])

regression = SummarizeArticle.run_eval("regression", context: { adapter: bad_adapter })
puts "Score:      #{regression.score.round(2)}"   # => 0.67
puts "Pass rate:  #{regression.pass_rate}"        # => 2/3

regression.each do |r|
  icon = r.passed? ? "✓" : "✗"
  puts "  #{icon} #{r.name.ljust(20)} #{r.details}"
end

puts
puts "Regression detected: #{baseline.score.round(2)} → #{regression.score.round(2)} " \
     "(#{((baseline.score - regression.score) * 100).round}% drop)"

# =============================================================================
# eval_case — inline single-case check without defining a full dataset
# =============================================================================

puts
puts "=" * 60
puts "Inline eval_case (quick one-off check)"
puts "=" * 60

one = SummarizeArticle.eval_case(
  input: "Ruby 3.4 ships with frozen string literals.",
  expected: { tone: "analytical" },
  context: { adapter: RubyLLM::Contract::Adapters::Test.new(
    response: { tldr: "Ruby 3.4 summary", takeaways: %w[a b c], tone: "analytical" }
  ) }
)

puts "Passed:   #{one.passed?}"   # => true
puts "Score:    #{one.score}"     # => 1.0
puts "Details:  #{one.details}"

# =============================================================================
# What this showcases
#
# - define_eval keeps dataset + expectations next to the step definition.
#   One class, one truth.
# - run_eval returns a Report with score, pass_rate, per-case CaseResult.
# - The same dataset detects a regression when a "good" adapter is swapped
#   for a "bad" one — same signal you get from a prompt change in prod.
# - eval_case is the lightweight alternative for one-off inline checks.
# =============================================================================
