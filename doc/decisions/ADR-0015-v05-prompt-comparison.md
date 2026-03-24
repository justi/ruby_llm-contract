---
id: ADR-0015
decision_type: adr
status: Proposed
created: 2026-03-24
summary: "v0.5 Data-Driven Prompt Engineering — compare_with for prompt A/B testing"
owners:
  - justi
---

# ADR-0015: v0.5 Data-Driven Prompt Engineering

## Game changer continuity

| Version | Question answered | Mechanism |
|---------|------------------|-----------|
| v0.2 | "Which model?" | `compare_models` — snapshot |
| v0.3 | "Did it change?" | `compare_with_baseline` — regression |
| v0.4 | "Show me the trend" | eval history — time series |
| **v0.5** | **"Which prompt is better?"** | **`compare_with` — prompt A/B** |
| v0.6 | "What should I do?" | model recommendation based on data |

## Why this is a game changer

Today, prompt engineering is:
1. Change prompt
2. Run eval
3. Look at score
4. Hope nothing regressed

With `compare_with`:
1. Change prompt in new Step class
2. `NewStep.compare_with(OldStep, eval: "regression", model: "nano")`
3. See: which cases improved, which regressed, is it safe to switch
4. **Data instead of hope**

No Ruby gem does prompt A/B testing with regression checks. Python frameworks (promptfoo, deepeval) do eval but not side-by-side comparison with regression safety.

## Key insight from ruby_llm creator review

> "compare_with is BaselineDiff on two Steps instead of two runs. You already have the machinery. This is 30 lines of new code, not a new architecture."

Existing pieces:
- `run_eval` runs any Step against a dataset ✓
- `BaselineDiff` compares two sets of case results ✓
- `CaseResult` has name, passed, score, mismatches ✓

Missing: one method that runs eval on BOTH steps and feeds results to BaselineDiff.

## Spec

### Prompt A/B testing

```ruby
# Current prompt
class ClassifyTicketV1 < RubyLLM::Contract::Step::Base
  prompt "Classify this ticket by priority: {input}"
  validate("valid") { |o| %w[low medium high urgent].include?(o[:priority]) }
end

# Candidate prompt (changed)
class ClassifyTicketV2 < RubyLLM::Contract::Step::Base
  prompt do
    system "You are a support ticket classifier."
    rule "If system is down or data is at risk, classify as urgent."
    user "{input}"
  end
  validate("valid") { |o| %w[low medium high urgent].include?(o[:priority]) }
end

# A/B comparison
diff = ClassifyTicketV2.compare_with(ClassifyTicketV1,
  eval: "regression",
  model: "gpt-4.1-nano")

diff.improvements    # => [{case: "outage", v1: {score: 0.0}, v2: {score: 1.0}}]
diff.regressions     # => []  (nothing got worse)
diff.score_delta     # => +0.33
diff.safe_to_switch? # => true (zero regressions)
```

### Cross-provider comparison

Already works today — just needs documentation:

```ruby
Step.compare_models("regression",
  models: %w[gpt-4.1-nano claude-haiku-4-5-20251001 gemini-2.0-flash])

#   Model                           Score    Cost       Latency
#   ---------------------------------------------------------------
#   gpt-4.1-nano                     0.75    $0.00003    287ms
#   claude-haiku-4-5-20251001        0.92    $0.00005    312ms
#   gemini-2.0-flash                 0.83    $0.00002    198ms
```

No new code needed. New README example + guide section.

### CI gate for prompt changes

```ruby
# Block merge if new prompt regresses any case
expect(ClassifyTicketV2).to pass_eval("regression")
  .compared_with(ClassifyTicketV1)
  .without_regressions
```

## Implementation

### Phase 1: `compare_with` (~30 lines)

```ruby
# In EvalHost concern
def compare_with(other_step, eval:, model: nil, context: {})
  ctx = model ? context.merge(model: model) : context
  my_report = run_eval(eval, context: ctx)
  other_report = other_step.run_eval(eval, context: ctx)

  PromptDiff.new(
    candidate: my_report,
    baseline: other_report
  )
end
```

`PromptDiff` reuses `BaselineDiff` internally but adds:
- `safe_to_switch?` — true when zero regressions
- `improvements` / `regressions` with v1/v2 labels
- `print_summary` with side-by-side table

### Phase 2: `compared_with` RSpec chain (~10 lines)

```ruby
chain :compared_with do |other_step|
  @comparison_step = other_step
end
```

In match block: run both, compare, check regressions.

### Phase 3: Cross-provider docs (~0 lines of code)

README and getting_started.md examples showing multi-provider `compare_models`.

## What this does NOT do

- **Auto-routing** — compare_with tells you WHICH prompt is better. YOU decide to switch. No implicit routing.
- **Prompt generation** — gem doesn't suggest prompt changes. It measures them.
- **ML/training** — no models trained, no embeddings, no classifiers. Pure comparison.

## Why NOT auto-routing in v0.5

Panel consensus: "explicit > implicit."

Auto-routing requires:
1. Input difficulty classifier (ML model or heuristic)
2. Training data (which inputs fail on cheap models)
3. Runtime routing decisions (implicit, hard to debug)

`compare_with` is explicit: dev runs comparison, reads results, makes decision. The gem provides DATA, not DECISIONS. This is the right boundary for a quality tool.

Model recommendation ("your data suggests switching to nano") is v0.6 — after enough history data from v0.4 trending.

## Success criteria

1. `StepV2.compare_with(StepV1, eval: "x", model: "nano")` returns PromptDiff
2. `diff.safe_to_switch?` is true when zero regressions
3. `compared_with(OtherStep).without_regressions` works in RSpec
4. Cross-provider `compare_models` example in README
5. Total new code: < 60 lines (reuses BaselineDiff, Report, Runner)
