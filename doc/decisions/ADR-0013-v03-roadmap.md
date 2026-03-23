---
id: ADR-0013
decision_type: adr
status: Proposed
created: 2026-03-23
summary: "v0.3 roadmap — baselines, migration guide, batch decision"
owners:
  - justi
---

# ADR-0013: v0.3 Roadmap

## Where v0.2 ended

v0.2.0: add_case, compare_models, cost tracking, CI gating, Rails Railtie.
v0.2.1: temperature DSL, around_call, build_messages, stub_step, estimate_cost.
v0.2.2: around_call per-run, Result#trace always Trace, model DSL, Trace#dig.

Game changer confirmed with real OpenAI API. First production adoption validated gem on 1 of 5 services. 22 DX issues found and fixed.

## v0.3 scope

### Feature 1: Baseline Regression Detection (ADR-0009)

**The question:** "Did something change since last run?"

```ruby
report = Step.run_eval("regression", context: { model: "gpt-4.1-nano" })
report.save_baseline!

# Later...
report = Step.run_eval("regression", context: { model: "gpt-4.1-nano" })
diff = report.compare_with_baseline

diff.regressions     # => cases that passed before but fail now
diff.improvements    # => cases that failed before but pass now
diff.score_delta     # => -0.15
diff.regressed?      # => true
```

**CI gate:**
```ruby
expect(Step).to pass_eval("regression").without_regressions

RubyLLM::Contract::RakeTask.new do |t|
  t.fail_on_regression = true
  t.save_baseline = true
end
```

**Storage:** `.eval_baselines/` directory, JSON files, git-tracked.

**Effort:** ~150 lines. Depends on CaseResult serialization (already has `to_h`).

### Feature 2: Migration Guide (ADR-0012)

**The question:** "How do I adopt this gem in my existing Rails app?"

`docs/guide/migration.md` covering 7 patterns:
1. Raw HTTP → Step
2. Manual retry → retry_policy
3. Manual logging → around_call
4. response_format → output_schema
5. Parallel batches → Step + app orchestrator
6. Model fallback → retry_policy / model DSL
7. Test stubbing → stub_step

Plus anti-patterns: don't migrate text output, don't parallelize in gem, don't migrate all at once.

**Effort:** ~2h documentation.

### Decision: Batch/Parallel Execution

**Question:** Should the gem support `Step.run_batch(inputs, concurrency: 4)`?

**Decision: No.** Parallelism is application concern. Reasons:
- Thread management depends on app (Rails executor, connection pool, Sidekiq)
- Error handling for partial failures is domain-specific
- `Concurrent::Future` and `Parallel` gem already exist
- Adding threading to gem increases surface area without clear moat

The gem provides the contract. The app decides how to run it.

### Feature 3: Upstream PR — ruby_llm-schema Array Fix (ADR-0011)

PR to `ruby_llm-schema`: raise `ArgumentError` when array block produces >1 schema instead of silent `.first`.

**Effort:** ~1h PR.

## NOT in v0.3

- Auto-routing (v0.4) — needs baseline history data
- Dashboard (v0.4) — needs persistence layer beyond JSON files
- Database persistence for eval history (v0.4) — JSON files first
- Batch execution in gem — user's responsibility
- Multi-provider eval comparison — works today via context, no gem change needed

## Release plan

| Phase | Deliverable | Effort |
|-------|-------------|--------|
| 1 | Baseline save/load/diff | ~3h |
| 2 | `without_regressions` CI gate | ~1h |
| 3 | Migration guide (docs/guide/migration.md) | ~2h |
| 4 | ruby_llm-schema PR (ADR-0011) | ~1h |
| 5 | Release v0.3.0 | — |

## Success criteria

1. `report.save_baseline!` + `compare_with_baseline` + `diff.regressions` works
2. `without_regressions` blocks CI when quality drops
3. Migration guide covers all 7 patterns with working code
4. ruby_llm-schema PR submitted (accepted or not)
