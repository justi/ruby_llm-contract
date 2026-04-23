# frozen_string_literal: true

# =============================================================================
# EXAMPLE 9: Dataset-based prompt evaluation
#
# Define test cases with expected outputs, run a step against all of them,
# and get an aggregate quality score. Like unit tests for your prompts.
#
# Shows:
#   - Dataset DSL with cases (input + expected)
#   - 4 evaluator types: exact, json_includes, regex, custom proc
#   - expected_traits for multi-property checks
#   - Aggregate scoring (0.0–1.0)
#   - eval_case convenience for inline testing
#   - Eval detecting quality regression
# =============================================================================

require_relative "../lib/ruby_llm/contract"

# =============================================================================
# STEP TO EVALUATE
# =============================================================================

class ClassifyIntent < RubyLLM::Contract::Step::Base
  input_type String

  output_schema do
    string :intent, enum: %w[sales support billing other]
    number :confidence, minimum: 0.0, maximum: 1.0
  end

  prompt do
    system "Classify the user's intent."
    user "{input}"
  end
end

# =============================================================================
# STEP 1: Define a dataset — your "golden set" of test cases
# =============================================================================

puts "=" * 60
puts "STEP 1: Define a dataset"
puts "=" * 60

dataset = RubyLLM::Contract::Eval::Dataset.define("intent_classification") do
  # Case with exact expected output
  add_case "billing inquiry",
           input: "I need help with my invoice",
           expected: { intent: "billing" }

  # Case with multiple expected fields
  add_case "sales inquiry",
           input: "I want to upgrade my plan",
           expected: { intent: "sales" }

  # Case with expected_traits (regex, ranges)
  add_case "support with confidence",
           input: "My app is crashing",
           expected_traits: { intent: "support" }

  # Case with custom evaluator (proc)
  add_case "high confidence expected",
           input: "URGENT: billing error!!!",
           evaluator: ->(output) { output[:confidence] >= 0.8 }

  # Case with no expected — just checks contract passes
  add_case "contract smoke test",
           input: "random text here"
end

puts "Dataset: #{dataset.name}"
puts "Cases: #{dataset.cases.length}"
dataset.cases.each { |c| puts "  - #{c.name}" }

# =============================================================================
# STEP 2: Run the eval — good model (all pass)
# =============================================================================

puts "\n\n#{"=" * 60}"
puts "STEP 2: Run eval — good model (all cases pass)"
puts "=" * 60

# Simulate a good model that returns correct intents
good_responses = {
  "I need help with my invoice" => '{"intent": "billing", "confidence": 0.92}',
  "I want to upgrade my plan" => '{"intent": "sales", "confidence": 0.88}',
  "My app is crashing" => '{"intent": "support", "confidence": 0.95}',
  "URGENT: billing error!!!" => '{"intent": "billing", "confidence": 0.97}',
  "random text here" => '{"intent": "other", "confidence": 0.6}'
}

# Custom adapter that returns different responses per input
good_adapter = Object.new
good_adapter.define_singleton_method(:call) do |messages:, **_opts|
  user_msg = messages.find { |m| m[:role] == :user }
  response = good_responses[user_msg[:content]] || '{"intent": "other", "confidence": 0.5}'
  RubyLLM::Contract::Adapters::Response.new(content: response, usage: { input_tokens: 0, output_tokens: 0 })
end

report = RubyLLM::Contract::Eval::Runner.run(
  step: ClassifyIntent,
  dataset: dataset,
  context: { adapter: good_adapter }
)

puts "\nScore: #{report.score.round(2)}"
puts "Pass rate: #{report.pass_rate}"
puts "All passed: #{report.passed?}"
puts
report.each do |r|
  icon = r.passed? ? "✓" : "✗"
  puts "  #{icon} #{r.name.ljust(30)} score=#{r.score}  #{r.details}"
end

# =============================================================================
# STEP 3: Run eval — bad model (some fail)
# =============================================================================

puts "\n\n#{"=" * 60}"
puts "STEP 3: Run eval — bad model (quality regression)"
puts "=" * 60

# Simulate a worse model that misclassifies some intents
bad_responses = {
  "I need help with my invoice" => '{"intent": "support", "confidence": 0.7}', # WRONG: billing → support
  "I want to upgrade my plan" => '{"intent": "sales", "confidence": 0.88}', # correct
  "My app is crashing" => '{"intent": "other", "confidence": 0.4}', # WRONG: support → other
  "URGENT: billing error!!!" => '{"intent": "billing", "confidence": 0.55}', # low confidence
  "random text here" => '{"intent": "other", "confidence": 0.6}' # correct
}

bad_adapter = Object.new
bad_adapter.define_singleton_method(:call) do |messages:, **_opts|
  user_msg = messages.find { |m| m[:role] == :user }
  response = bad_responses[user_msg[:content]] || '{"intent": "other", "confidence": 0.5}'
  RubyLLM::Contract::Adapters::Response.new(content: response, usage: { input_tokens: 0, output_tokens: 0 })
end

bad_report = RubyLLM::Contract::Eval::Runner.run(
  step: ClassifyIntent,
  dataset: dataset,
  context: { adapter: bad_adapter }
)

puts "\nScore: #{bad_report.score.round(2)}"
puts "Pass rate: #{bad_report.pass_rate}"
puts "All passed: #{bad_report.passed?}"
puts
bad_report.each do |r|
  icon = r.passed? ? "✓" : "✗"
  puts "  #{icon} #{r.name.ljust(30)} score=#{r.score}  #{r.details}"
end

puts "\nRegression detected:"
puts "  Score dropped: #{report.score.round(2)} → #{bad_report.score.round(2)} " \
     "(#{((report.score - bad_report.score) * 100).round(1)}% drop)"

# =============================================================================
# STEP 4: eval_case — quick inline check
# =============================================================================

puts "\n\n#{"=" * 60}"
puts "STEP 4: eval_case — inline single-case eval"
puts "=" * 60

# No dataset needed — just check one case
result = ClassifyIntent.eval_case(
  input: "I want to cancel my subscription",
  expected: { intent: "billing" },
  context: { adapter: good_adapter }
)

puts "Passed: #{result.passed?}"
puts "Score: #{result.score}"
puts "Output: #{result.output}"
puts "Details: #{result.details}"

# With expected_traits
result2 = ClassifyIntent.eval_case(
  input: "URGENT: server down!!!",
  expected_traits: { intent: "support" },
  context: {
    adapter: RubyLLM::Contract::Adapters::Test.new(
      response: '{"intent": "support", "confidence": 0.99}'
    )
  }
)

puts "\nTraits check:"
puts "Passed: #{result2.passed?}"
puts "Details: #{result2.details}"

# With custom proc evaluator
result3 = ClassifyIntent.eval_case(
  input: "test",
  evaluator: ->(output) { output[:confidence] > 0.9 },
  context: {
    adapter: RubyLLM::Contract::Adapters::Test.new(
      response: '{"intent": "other", "confidence": 0.95}'
    )
  }
)

puts "\nCustom proc:"
puts "Passed: #{result3.passed?} (confidence > 0.9)"

# =============================================================================
# STEP 5: Evaluating a pipeline
# =============================================================================

puts "\n\n#{"=" * 60}"
puts "STEP 5: Evaluate a pipeline end-to-end"
puts "=" * 60

class SuggestAction < RubyLLM::Contract::Step::Base
  input_type Hash

  output_schema do
    string :action
    string :priority, enum: %w[low medium high urgent]
  end

  prompt do
    system "Suggest an action based on the classified intent."
    user "Intent: {intent}, Confidence: {confidence}"
  end
end

class SupportPipeline < RubyLLM::Contract::Pipeline::Base
  step ClassifyIntent, as: :classify
  step SuggestAction,  as: :action
end

pipeline_dataset = RubyLLM::Contract::Eval::Dataset.define("support_pipeline") do
  add_case "billing → action",
           input: "I need help with my invoice",
           expected: { priority: "medium" }

  add_case "urgent → action",
           input: "URGENT: server is down!",
           expected: { priority: "urgent" }
end

pipeline_adapter = RubyLLM::Contract::Adapters::Test.new(
  response: '{"intent": "billing", "confidence": 0.9, "action": "Review invoice", "priority": "medium"}'
)

pipeline_report = RubyLLM::Contract::Eval::Runner.run(
  step: SupportPipeline,
  dataset: pipeline_dataset,
  context: { adapter: pipeline_adapter }
)

puts "\nPipeline eval:"
puts "Score: #{pipeline_report.score.round(2)}"
puts "Pass rate: #{pipeline_report.pass_rate}"
pipeline_report.each do |r|
  icon = r.passed? ? "✓" : "✗"
  puts "  #{icon} #{r.name.ljust(25)} #{r.details}"
end

# =============================================================================
# SUMMARY
#
# Dataset eval answers: "Is my prompt good?"
#
# Define cases:
#   - expected: exact output match (or json_includes for partial)
#   - expected_traits: multi-property checks (regex, values)
#   - evaluator: custom proc for complex logic
#   - no expected: just check contract passes
#
# Run eval:
#   - report.score → 0.0-1.0 aggregate
#   - report.pass_rate → "4/5"
#   - report.each → per-case details
#
# Quick check:
#   - MyStep.eval_case(input: ..., expected: ...) → single result
#
# Regression detection:
#   - Compare report.score before/after prompt change
#   - Drop from 1.0 to 0.6 → something broke
#
# Next: GH-8 adds Regression::Baseline to automate this comparison
# =============================================================================
