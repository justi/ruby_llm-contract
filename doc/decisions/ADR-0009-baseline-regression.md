---
id: ADR-0009
decision_type: adr
status: Proposed
created: 2026-03-22
summary: "Baseline regression detection — know when quality drops before users do"
owners:
  - justi
---

# ADR-0009: Baseline Regression Detection

## Why this matters

You run eval today: 9/10 pass. You deploy. Two weeks later, provider silently updates model weights. You run eval: 7/10 pass. Without a baseline, you don't know quality dropped. With a baseline, CI blocks the deploy.

This is the difference between "testing" and "monitoring."

ADR-0008 answers "which model should I use?" (point-in-time decision).
ADR-0009 answers "did something change?" (time-series detection).

Together they make ruby_llm-contract the only Ruby tool that treats LLM quality as a measurable, trackable, alertable metric — like uptime or latency.

## The 10-line test

```ruby
# To detect regressions you need:
# 1. Run eval, get results
# 2. Save results somewhere (file? DB? git?)
# 3. Next run: load previous results
# 4. Diff: which cases passed before but fail now?
# 5. Which cases fail now but passed before? (improvements)
# 6. Present the diff
# 7. Gate CI on "no regressions" vs "score >= X"
#
# That's ~200 lines + persistence layer.
# And you need to handle: first run (no baseline), schema changes,
# renamed cases, added/removed cases.
```

## Spec

### Saving a baseline

```ruby
report = ClassifyTicket.run_eval("regression", context: { model: "gpt-4.1-nano" })
report.save_baseline!
# Writes to .eval_baselines/ClassifyTicket/regression.json
```

Or automatically in CI:

```ruby
RubyLLM::Contract::RakeTask.new do |t|
  t.save_baseline = true  # save after successful run
end
```

### Comparing with baseline

```ruby
report = ClassifyTicket.run_eval("regression", context: { model: "gpt-4.1-nano" })
diff = report.compare_with_baseline

diff.regressions
# => [
#   { case: "urgent outage",
#     baseline: { passed: true, score: 1.0 },
#     current:  { passed: false, score: 0.0 },
#     detail: "priority: expected 'urgent', got 'high'" }
# ]

diff.improvements
# => [
#   { case: "edge case",
#     baseline: { passed: false, score: 0.0 },
#     current:  { passed: true, score: 1.0 } }
# ]

diff.score_delta    # => -0.15 (dropped from 0.90 to 0.75)
diff.regressed?     # => true
diff.new_cases      # => ["added in this run but not in baseline"]
diff.removed_cases  # => ["in baseline but not in this run"]
```

### CI gate on regressions

```ruby
# RSpec
expect(ClassifyTicket).to pass_eval("regression")
  .with_context(model: "gpt-4.1-nano")
  .without_regressions  # fail if ANY previously-passing case now fails

# Rake
RubyLLM::Contract::RakeTask.new do |t|
  t.fail_on_regression = true  # stricter than minimum_score
end
```

### Drift alerting

```ruby
# In a scheduled job (daily, weekly):
RubyLLM::Contract.run_all_evals(context: { model: "gpt-4.1-nano" })
  .each do |step, reports|
    reports.each do |name, report|
      diff = report.compare_with_baseline
      if diff.regressed?
        Slack.notify("#llm-ops",
          "#{step.name}/#{name}: score dropped #{diff.score_delta} " \
          "(#{diff.regressions.count} regressions)")
      end
    end
  end
```

## What this enables that nothing else does

1. **Silent model degradation detection** — provider updates weights, you find out from data not user complaints
2. **Prompt change safety** — refactor a prompt, see exactly which cases regressed before merging
3. **CI gate by regression, not just threshold** — "block if any passing case now fails" is stricter and more useful than "block if score < 0.8"
4. **Quality over time** — plot score across runs, see trends, correlate with model/prompt changes

## Persistence format

```json
{
  "step": "ClassifyTicket",
  "eval": "regression",
  "model": "gpt-4.1-nano",
  "timestamp": "2026-03-22T14:30:00Z",
  "score": 0.90,
  "total_cost": 0.0034,
  "cases": [
    {
      "name": "billing ticket",
      "passed": true,
      "score": 1.0,
      "cost": 0.00085,
      "expected": { "priority": "high", "category": "billing" },
      "output": { "priority": "high", "category": "billing", "confidence": 0.9 }
    }
  ]
}
```

Default storage: `.eval_baselines/` directory (git-tracked). Optional: custom adapter for DB/S3.

## Implementation plan

### Phase 1: Baseline save/load (~60 lines)

- `Report#save_baseline!(path:)` — serialize to JSON
- `Report#compare_with_baseline(path:)` — load + diff
- Default path: `.eval_baselines/{step}/{eval}.json`

### Phase 2: Diff engine (~80 lines)

- `BaselineDiff` value object with `regressions`, `improvements`, `score_delta`, `new_cases`, `removed_cases`
- Case matching by name (handles added/removed cases)
- `regressed?` — true if any regression exists

### Phase 3: CI integration (~30 lines)

- `without_regressions` chain on `pass_eval`
- `fail_on_regression` on RakeTask
- `save_baseline` on RakeTask (auto-save after pass)

## Dependencies

- ADR-0008 (cost in report) — baselines should include cost data
- File I/O only, no external dependencies

## NOT in scope

- Database persistence — keep it simple with JSON files
- Multi-run history — only baseline vs current (history tracking = v0.4)
- Statistical significance — binary regression (passed→failed), not "score dropped by 2% which might be noise"
- Auto-routing based on regression data — v0.4

## Success criteria

A developer can:
1. Run eval, save baseline
2. Change prompt or model
3. Run eval again
4. See "2 regressions, 1 improvement, score -0.15"
5. CI blocks merge on regression

No other Ruby gem enables this workflow.
