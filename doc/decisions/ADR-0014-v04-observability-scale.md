---
id: ADR-0014
decision_type: adr
status: Proposed
created: 2026-03-24
summary: "v0.4 Observability & Scale — see what changed, run it fast, debug it easily"
owners:
  - justi
---

# ADR-0014: v0.4 Observability & Scale

## Game changer continuity

v0.2 delivered the game changer: **"which model should I use?" answered with data.**

```
Model                      Score       Cost  Avg Latency
---------------------------------------------------------
gpt-4.1-nano                0.67    $0.000032      687ms
gpt-4.1-mini                1.00    $0.000102     1070ms
```

v0.3 added: **"did something change?" answered with baseline regression.**

v0.4 must deepen both, not replace them:
- "Which model?" becomes "which model THIS WEEK vs LAST WEEK?" (trending)
- "Did something change?" becomes "WHICH STEP changed in my pipeline?" (per-step)
- Both must work at scale: 200 eval cases can't take 3 minutes in CI (concurrency)

**v0.4 does NOT add ML, routing, or auto-decisions.** Those are v0.5. v0.4 makes the existing tools faster, deeper, and more observable.

## Panel input

Five senior Ruby/Rails engineers (18-22 years experience) + ruby_llm creator reviewed the roadmap. Consensus:

| Proposed | Panel verdict | Reason |
|----------|--------------|--------|
| Auto-routing | **v0.5** | "Explicit > implicit. Premature optimization." |
| Eval history/trending | **v0.4** | "I need to see accuracy THIS week vs LAST week." |
| Batch eval (concurrency) | **v0.4** | "200 cases × 1.5s = 5 min in CI. Unacceptable." |
| Pipeline per-step eval | **v0.4** | "Pipeline eval says FAIL but doesn't say WHICH step." |
| Minitest support | **v0.4** | "Not everyone uses RSpec." |
| Structured logging | **v0.4** | "around_call is manual. Give me Contract.logger." |

## Feature 1: Eval History & Trending

### Problem

`compare_models` gives a snapshot. But: "nano was 92% last week, now 78%" requires history. Baselines are binary (regressed or not). Trending shows drift over time.

### Spec

```ruby
# Save every eval run (not just baseline)
report = Step.run_eval("regression", context: { model: "gpt-4.1-nano" })
report.save_history!(model: "gpt-4.1-nano")
# Appends to .eval_history/Step/regression_gpt-4_1-nano.jsonl

# View trend
history = Step.eval_history("regression", model: "gpt-4.1-nano")
history.runs          # => [{date: "2026-03-20", score: 0.92}, {date: "2026-03-24", score: 0.78}]
history.score_trend   # => :declining
history.drift?        # => true (score dropped > 10% over last 5 runs)
```

### Storage

JSONL (one JSON object per line) in `.eval_history/`. Git-tracked or .gitignored (user choice).

### How this strengthens the game changer

v0.2 answers "which model NOW?" — v0.4 answers "which model OVER TIME?" Provider weight changes, prompt drift, seasonal input variation — all visible.

## Feature 2: Batch Eval (Concurrency)

### Problem

200 eval cases × 1.5s per call = 5 minutes in CI. Unacceptable for `fail_on_regression` gate.

### Spec

```ruby
report = Step.run_eval("regression",
  context: { model: "gpt-4.1-nano" },
  concurrency: 4)
# Runs 4 cases in parallel, 4x faster
```

### Implementation

`Eval::Runner` uses `Concurrent::Future` (from concurrent-ruby, already a transitive dependency via ruby_llm) for parallel case execution. Results collected and ordered by case name.

Thread safety: each case gets its own adapter call. No shared mutable state (context deep-duped per case).

### How this strengthens the game changer

`compare_models` with 3 models × 50 cases = 150 calls. At 4x concurrency: 37 calls worth of time instead of 150. Makes model comparison practical for real datasets.

## Feature 3: Pipeline Per-Step Eval

### Problem

Pipeline eval reports final output only. If step 2 hallucinates but step 3 compensates, you don't know step 2 is broken until step 3 stops compensating.

### Spec

```ruby
TicketPipeline.define_eval("e2e") do
  add_case "billing",
    input: "I was charged twice",
    expected: { priority: "high" },             # final output
    step_expectations: {
      classify: { priority: "high" },           # per-step
      route:    { team: /billing|finance/ }
    }
end

report = TicketPipeline.run_eval("e2e")
report.results.first.step_results
# => { classify: {passed: true}, route: {passed: true}, draft: {passed: true} }
```

### How this strengthens the game changer

"Did something change?" now answers at step granularity. Regression in step 2 caught even when step 3 masks it.

## Feature 4: Minitest Support

### Problem

`stub_step`, `pass_eval`, `satisfy_contract` are RSpec-only. Rails default is Minitest.

### Spec

```ruby
require "ruby_llm/contract/minitest"

class ClassifyTicketTest < ActiveSupport::TestCase
  include RubyLLM::Contract::MinitestHelpers

  test "satisfies contract" do
    stub_step(ClassifyTicket, response: { priority: "high" })
    result = ClassifyTicket.run("test")
    assert_satisfies_contract result
  end

  test "passes eval" do
    assert_eval_passes ClassifyTicket, "regression",
      minimum_score: 0.8,
      maximum_cost: 0.01
  end
end
```

### How this strengthens the game changer

More users = more adoption. Rails default is Minitest. No RSpec dependency for CI gating.

## Feature 5: Structured Logging

### Problem

`around_call` requires manual logging code. Every user writes the same boilerplate.

### Spec

```ruby
RubyLLM::Contract.configure do |c|
  c.logger = Rails.logger
  c.log_level = :info  # logs model, latency, cost, status per call
end

# Automatic structured log on every step.run:
# [ruby_llm-contract] ClassifyTicket model=gpt-4.1-nano status=ok
#   latency=342ms tokens=45+12 cost=$0.000032
```

### How this strengthens the game changer

Observability without code. Cost tracking visible in existing log infrastructure (Datadog, CloudWatch, Lograge).

## NOT in v0.4

| Feature | Why not | When |
|---------|---------|------|
| Auto-routing | Panel: "explicit > implicit, premature" | v0.5 |
| Model recommendation | Needs history data from v0.4 | v0.5 |
| Streaming eval | Nice but not blocking adoption | v0.5 |
| Tool calling support | Needs ruby_llm tool API integration | v0.5 |
| Cost alerts (Slack/email) | Needs external integration layer | v0.5 |
| Database persistence | JSONL files first, DB adapter in v0.5 | v0.5 |
| Web dashboard | Needs persistence layer | v0.5+ |

## v0.5 preview: Data-Driven Prompt Engineering (ADR-0015)

v0.5 reuses v0.3 BaselineDiff machinery for prompt comparison:

- **`compare_with(OtherStep)`** — A/B test prompts with regression check. "Candidate improves 3 cases, regresses 0. Safe to switch."
- **Cross-provider examples** — `compare_models` already works multi-provider. v0.5 adds docs and convenience.

Key insight (from ruby_llm creator review): this is ~30 lines of new code reusing existing BaselineDiff. Not a new architecture.

See ADR-0015 for full spec.

## Implementation plan

| Phase | Feature | Effort | Depends on |
|-------|---------|--------|------------|
| 1 | Structured logging | ~2h | — |
| 2 | Batch eval concurrency | ~3h | — |
| 3 | Eval history & trending | ~4h | — |
| 4 | Pipeline per-step eval | ~4h | — |
| 5 | Minitest support | ~2h | — |
| 6 | Release v0.4.0 | — | all above |

## Success criteria

1. `run_eval(concurrency: 4)` runs 4x faster than sequential
2. `eval_history` shows score trend over 5+ runs
3. Pipeline eval reports per-step pass/fail
4. Minitest assertions work without RSpec
5. `Contract.configure { |c| c.logger = Rails.logger }` produces structured logs
6. All of the above work with existing `compare_models`, `save_baseline!`, `without_regressions` — game changer features preserved and enhanced
