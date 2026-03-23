---
id: ADR-0013
decision_type: adr
status: Proposed
created: 2026-03-23
summary: "v0.3 roadmap — baselines, drift detection, migration guide"
owners:
  - justi
---

# ADR-0013: v0.3 Roadmap

## Where v0.2 ended

v0.2 delivered: add_case, compare_models, cost tracking, CI gating, Rails Railtie.
v0.2.1-0.2.2 fixed 22 production DX issues from first real-world integration.

Game changer confirmed: `compare_models` with real API produces actionable data.

v0.3 focuses on two things:
1. **Baseline regression** (ADR-0009) — "did something change?"
2. **Migration guide** — how to adopt the gem in existing Rails apps

## Feature 1: Baseline Regression (ADR-0009)

### Why

You run eval today: 9/10 pass. Provider updates model weights. You run eval next week: 7/10 pass. Without a baseline, you don't know quality dropped.

### Spec

```ruby
# Save baseline after successful run
report = ClassifyTicket.run_eval("regression", context: { model: "gpt-4.1-nano" })
report.save_baseline!
# Writes to .eval_baselines/ClassifyTicket/regression.json

# Next run: compare
report = ClassifyTicket.run_eval("regression", context: { model: "gpt-4.1-nano" })
diff = report.compare_with_baseline

diff.regressions     # => [{name: "outage", was: :passed, now: :failed}]
diff.improvements    # => [{name: "edge_case", was: :failed, now: :passed}]
diff.score_delta     # => -0.15
diff.regressed?      # => true
```

### CI integration

```ruby
expect(ClassifyTicket).to pass_eval("regression")
  .with_context(model: "gpt-4.1-nano")
  .without_regressions

RubyLLM::Contract::RakeTask.new do |t|
  t.fail_on_regression = true
  t.save_baseline = true  # auto-save after pass
end
```

### Implementation

- `Report#save_baseline!(path:)` — JSON serialization
- `Report#compare_with_baseline(path:)` — load + diff
- `BaselineDiff` value object
- Default storage: `.eval_baselines/` (git-tracked)
- ~150 lines of code

## Feature 2: Migration Guide

### Why

Adopting ruby_llm-contract in an existing Rails app is non-obvious. The persona_tool migration revealed patterns that should be documented.

### Content

**`docs/guide/migration.md`:**

1. **Identify LLM call sites** — grep for HTTP calls, `RubyLLM.chat`, OpenAI client usage
2. **Start with the simplest service** — single input → JSON output → DB save
3. **Define the contract** — prompt DSL, output_schema, validates
4. **Replace the service** — swap LlmClient call for Step.run
5. **Add around_call** — replace manual logging with callback
6. **Add eval cases** — 3-5 cases from production data
7. **Run compare_models** — find cheapest viable model
8. **Repeat for next service**

**Patterns from persona_tool migration:**

| Old pattern | New pattern |
|-------------|-------------|
| `LlmClient.new(model:).call(prompt)` | `MyStep.run(input)` |
| `JSON.parse(response[:content])` | `result.parsed_output` |
| `retries = 0; begin; rescue; retry; end` | `retry_policy models: [...]` |
| `body[:temperature] = 0.7` | `temperature 0.7` |
| `AiCallLog.create(...)` | `around_call { \|s, i, r\| AiCallLog.create(...) }` |
| `response_format: JsonSchema.build(...)` | `output_schema do...end` |

## Feature 3: Batch/Parallel Support (exploration)

### Why

PersonaGenerator runs 10 LLM calls in parallel threads. The gem has no built-in parallel execution. The orchestrator stays in the Rails service.

### Question

Should the gem support batch execution natively?

```ruby
# Option A: gem handles parallelism
results = GeneratePersonaBatch.run_batch(
  inputs: 10.times.map { |i| { batch_size: 10, batch_num: i } },
  concurrency: 4
)

# Option B: user handles parallelism (current)
results = Concurrent::Future.execute { GeneratePersonaBatch.run(input) }
```

**Decision: Option B (user handles).** Parallelism is application concern. The gem provides the contract; the app decides how to run it. Adding threading to the gem adds complexity without clear benefit over `Concurrent::Future` or `Parallel`.

## NOT in v0.3

- Auto-routing (v0.4) — needs eval history data from baselines
- Dashboard (v0.4) — needs persistence layer
- Database persistence for eval history (v0.4) — JSON files first
- Batch/parallel execution in gem — user's responsibility

## Timeline

| Phase | What | Effort |
|-------|------|--------|
| 1 | Baseline save/load/diff | ~3h |
| 2 | CI integration (without_regressions) | ~1h |
| 3 | Migration guide | ~2h |
| 4 | persona_tool full migration (ADR-0012) | ~4h |
| 5 | Release v0.3.0 | — |

## Success criteria

1. Developer can save baseline, change prompt, see regressions
2. CI blocks merge when previously-passing case now fails
3. Migration guide covers 5 common patterns with code examples
4. persona_tool runs 4/5 services on ruby_llm-contract
