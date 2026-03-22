---
id: ADR-0008
decision_type: adr
status: Accepted
created: 2026-03-22
summary: "Cost of Quality — the metric that makes this gem a decision tool, not just a testing tool"
owners:
  - justi
---

# ADR-0008: Cost of Quality

## Why this matters

ADR-0007 delivered regression testing. But regression testing answers "did it break?" — a binary.

The question production teams actually ask is:

**"nano scores 85%, mini scores 98%. mini costs 4x more. Is 13% worth it?"**

No Ruby gem answers this. No Python framework answers this well either. The infrastructure to answer it requires integration between 5 layers: adapter (usage), cost calculator (pricing), eval runner (accuracy), trace (per-call cost), and report (aggregation). Building this from scratch = reimplementing ruby_llm-contract.

This is the moat. Not eval. Not retry. Not contracts. **Cost of Quality as a first-class metric.**

## What this is NOT

This is not "add a cost field." This is a specific product decision:

**ruby_llm-contract is a tool for choosing the right model for each prompt, using data instead of intuition.**

Every feature below serves that thesis.

## The 10-line test

Can you do this in 10 lines of ruby_llm + dry-types?

```ruby
# You need:
# 1. Define 10 test cases with expected outputs
# 2. Run them against 3 models
# 3. Track cost per call (need model pricing table)
# 4. Track accuracy per model (need partial matching)
# 5. Present a comparison table
# 6. Answer "cheapest model at >= 95% accuracy"
#
# That's ~150 lines minimum, spread across 4 concerns.
# And you'll rebuild it for every new Step.
```

## Spec

### Cost in CaseResult

```ruby
result = report.results.first
result.cost        # => 0.00085 (dollars)
result.duration_ms # => 342 (already exists)
```

Source: `step_result.trace[:cost]` — already computed by CostCalculator.
The only change: pass it through Runner to CaseResult.

### Cost in Report

```ruby
report.total_cost  # => 0.0034 (sum of all case costs)
report.score       # => 0.75 (already exists)
report.pretty_print
# ClassifyTicket regression: 3/4 passed, $0.0034
#   PASS  billing ticket        $0.0008  342ms
#   PASS  feature request       $0.0009  289ms
#   FAIL  urgent outage         $0.0009  312ms
#         priority: expected "urgent", got "high"
#   PASS  positive feedback     $0.0008  267ms
```

### Model Comparison

```ruby
comparison = ClassifyTicket.compare_models("regression",
  models: %w[gpt-4.1-nano gpt-4.1-mini gpt-4.1])

comparison.table
# Model           Score  Cost     Avg Latency
# gpt-4.1-nano    0.75   $0.003   287ms
# gpt-4.1-mini    0.98   $0.012   412ms
# gpt-4.1         1.00   $0.048   823ms

comparison.best_for(min_score: 0.95)
# => "gpt-4.1-mini" (cheapest model at >= 95% accuracy)

comparison.cost_per_point
# => { "gpt-4.1-nano" => 0.004, "gpt-4.1-mini" => 0.012, "gpt-4.1" => 0.048 }
# (cost per 1% of accuracy)
```

### RSpec integration

```ruby
expect(ClassifyTicket).to pass_eval("regression")
  .with_context(model: "gpt-4.1-nano")
  .with_minimum_score(0.8)
  .with_maximum_cost(0.01)
```

### Rake integration

```ruby
RubyLLM::Contract::RakeTask.new do |t|
  t.minimum_score = 0.8
  t.maximum_cost = 0.05  # fail if total eval cost exceeds budget
end
```

## What this enables that nothing else does

1. **Data-driven model selection** — not "I think mini is better" but "mini scores 98% at $0.012, nano scores 85% at $0.003"
2. **Cost budgeting** — "this eval suite costs $0.03 per run, we run it 10x/day in CI = $9/month"
3. **Cost regression** — provider raises prices or changes token counts → cost jumps → CI flags it
4. **ROI per accuracy point** — "upgrading from nano to mini costs $0.009 per eval run for +13% accuracy"

## Implementation

### Phase 1: Cost in CaseResult + Report (~30 lines)

Runner already has `step_result.trace[:cost]`. Pass it to CaseResult.
Report aggregates with `total_cost`.

### Phase 2: Model Comparison (~80 lines)

New class `Eval::ModelComparison`:
- Takes eval name + model list
- Runs eval N times (once per model)
- Returns `ComparisonReport` with `table`, `best_for(min_score:)`, `cost_per_point`

### Phase 3: CI integration (~20 lines)

- `with_maximum_cost` chain on `pass_eval`
- `maximum_cost` on RakeTask
- `pretty_print` shows cost per case

## NOT in scope

- Cost prediction (estimating cost before running) — v0.3
- Historical cost tracking (how much did we spend this month) — needs persistence, v0.3
- Auto-routing based on cost/quality (use nano for easy, mini for hard) — v0.4

## Success criteria

A developer can run:

```ruby
ClassifyTicket.compare_models("regression",
  models: %w[gpt-4.1-nano gpt-4.1-mini gpt-4.1])
```

And get a table that answers: "which model should I use?"

No other Ruby gem enables this workflow. This is the game changer.
