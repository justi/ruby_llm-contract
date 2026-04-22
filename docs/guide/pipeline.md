# Pipeline

Chain multiple steps with automatic data threading, fail-fast, per-step models, trace, and timeout.

## Full example: Meeting transcript to follow-up email

Three steps, three different LLM skills, three contracts:

```ruby
# Step 1: Extract — the LLM is a "listener" parsing a messy transcript
class ExtractDecisions < RubyLLM::Contract::Step::Base
  output_schema do
    array :decisions do
      string :id
      string :description
      string :made_by
    end
    array :action_items do
      string :id
      string :task
      string :owner
      string :deadline
    end
  end

  prompt <<~PROMPT
    Extract decisions and action items from a meeting transcript.
    Only include decisions explicitly stated, never infer.
    Assign sequential IDs: D1, D2, ... for decisions, A1, A2, ... for action items.

    {input}
  PROMPT
end

# Step 2: Analyze — the LLM is a "critic" finding vague assignments
class ResolveAmbiguities < RubyLLM::Contract::Step::Base
  input_type Hash

  output_schema do
    array :analyses do
      string :action_item_id
      string :status, enum: %w[clear ambiguous]
      array :issues do
        string :field, enum: %w[owner deadline scope]
        string :problem
        string :clarification_question
      end
    end
  end

  prompt <<~PROMPT
    Review action items for completeness.
    Flag vague owners, missing deadlines, unclear scope.

    Action items: {action_items}
  PROMPT

  validate("all action items analyzed") do |output, input|
    output[:analyses].map { |a| a[:action_item_id] }.sort ==
      input[:action_items].map { |a| a[:id] }.sort
  end
end

# Step 3: Synthesize — the LLM is a "writer" producing a send-ready email
class GenerateFollowUp < RubyLLM::Contract::Step::Base
  input_type Hash

  output_schema do
    string :subject
    string :body
    integer :decisions_count
    integer :action_items_count
  end

  prompt <<~PROMPT
    Write a follow-up email. List decisions, clear action items with owners
    and deadlines, and embed clarification questions for ambiguous items.

    Decisions: {decisions}
    Analyses: {analyses}
  PROMPT

  validate("subject must be concise") { |o| o[:subject].length <= 80 }
end

# Pipeline: extract → analyze → email
class MeetingFollowUp < RubyLLM::Contract::Pipeline::Base
  step ExtractDecisions,    as: :extract
  step ResolveAmbiguities,  as: :analyze
  step GenerateFollowUp,    as: :email
end
```

## Running and inspecting

```ruby
result = MeetingFollowUp.run(transcript, context: { adapter: adapter })
result.ok?                          # => true
result.outputs_by_step[:extract]    # => {decisions: [...], action_items: [...]}
result.outputs_by_step[:email]      # => {subject: "Follow-up: Q2 planning", body: "Hi team, ..."}
result.trace.total_cost             # => 0.000128 (all steps combined)
result.trace.total_latency_ms       # => 2340
```

## Fail-fast behavior

Each step catches hallucinations before they spread:

```ruby
result = MeetingFollowUp.run("just some random text")
result.failed?                      # => true
result.failed_step                  # => :extract (no real decisions found → stops here)
# analyze and email never run — no hallucinated email goes out
```

## Per-step model override

```ruby
class EntityPipeline < RubyLLM::Contract::Pipeline::Base
  step ExtractEntities,   as: :extract,   model: "gpt-4.1-nano"
  step NormalizeEntities,  as: :normalize, model: "gpt-4.1-nano"
  step ClassifyEntities,   as: :classify,  model: "gpt-4.1-mini"
end
```

## Timeout

```ruby
result = EntityPipeline.run("Apple released the iPhone.", timeout_ms: 30_000)
```

## Pipeline eval

```ruby
MeetingFollowUp.define_eval("e2e") do
  add_case "quarterly planning transcript",
    input: "Q2 planning meeting transcript: we decided...",
    expected: { subject: /follow-up/i }
end

report = MeetingFollowUp.run_eval("e2e", context: { model: "gpt-4.1-mini" })
report.print_summary
```

## Pretty print

```ruby
puts result
# Pipeline: ok  3 steps  1234ms  450+120 tokens  trace=abc12345

result.pretty_print
# Full ASCII table with per-step outputs (Pipeline::Result)

# For eval reports, use print_summary instead:
report.print_summary
# Tabular pass/fail breakdown (Eval::Report)
```

## See also

- [Testing](testing.md) — `MeetingFollowUp.test(..., responses: { extract: ..., analyze: ..., email: ... })` for pipeline-level spec adapters.
- [Optimizing retry_policy](optimizing_retry_policy.md) — `optimize_retry_policy` runs per-step; pipelines benchmark one step at a time.
