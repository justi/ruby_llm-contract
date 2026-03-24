---
id: ADR-0016
decision_type: adr
status: Proposed
created: 2026-03-24
summary: "v0.4.3+ Production feedback — 7 feature requests from real Rails 8.1 deployment"
owners:
  - justi
---

# ADR-0016: Production Feedback — PersonaTool Integration

## Source

Real-world Rails 8.1 app: 8 contracts, 499 tests, full eval suite with baselines.
Gem versions tested: 0.2.2 → 0.4.2. All 6 bugs found were fixed in gem releases.
Zero remaining workarounds as of 0.4.2.

These 7 feature requests come from production usage, not speculation.

## Feature requests — prioritized

### F1: `stub_step` block form with cleanup (HIGH)

**Problem:** `stub_step` sets a global adapter and never resets it. Tests leak state.

```ruby
# Current — leaks
stub_step(EvaluateStandard, response: data)

# Needed — auto-cleanup
stub_step(EvaluateStandard, response: data) do
  # test code
end
# adapter automatically reset
```

**Why high:** Every test file needs a manual `ensure reset_configuration!` wrapper. Block form eliminates the entire class of leak bugs.

**Scope:** RSpec helpers + Minitest helpers. Add `yield` + `ensure` reset.

### F2: Pipeline fan-out / reduce (MEDIUM)

**Problem:** Pipeline::Base is strictly linear. Real pattern in PersonaGenerator:

```
ExpandSeedList (parallel across 3 fields)
       ↓
GeneratePersonaBatch (parallel across N batches)
       ↓
fill_remaining (sequential retry loop)
```

**Needed:**
```ruby
class PersonaGenerationPipeline < RubyLLM::Contract::Pipeline::Base
  fan_out ExpandSeedList, inputs: :seed_fields
  fan_out GeneratePersonaBatch, inputs: :batch_prompts
  retry_step GeneratePersonaBatch, for: :remaining

  token_budget 500_000
end
```

**Why medium:** Without this, PersonaGenerator stays as manual orchestration (~120 LOC) that could be ~20 LOC pipeline. But the manual version works — this is ergonomics, not a blocker.

**Risk:** Large API surface. Needs careful design — probably a separate ADR.

### F3: EvalHistory auto-append in RakeTask (MEDIUM)

**Problem:** `EvalHistory` class exists. `RakeTask` doesn't use it.

```ruby
# Needed
RubyLLM::Contract::RakeTask.new do |t|
  t.track_history = true  # auto-append each run to .eval_history/
end
```

**Why medium:** Makes drift tracking zero-config for CI. Currently requires manual `report.save_history!` call.

**Scope:** Small — add `track_history` attr, call `save_history!` on passed reports in `define_task`.

### F4: `compare_models` in RakeTask (LOW)

**Problem:** `compare_models` is only available programmatically. No rake wrapper.

```ruby
RubyLLM::Contract::RakeTask.new(:"contracts:compare") do |t|
  t.models = %w[gpt-4o-mini gpt-4o gpt-5-mini]
  t.minimum_score = 0.8
end
```

**Why low:** `compare_models` on Step/Pipeline works fine. Rake wrapper is convenience for CI, not a missing capability.

### F5: Scoped `stub_step` per contract (LOW)

**Problem:** `stub_step` sets a global adapter — all contracts see the same response. Pipeline tests need different responses per step.

```ruby
stub_step(ExpandSeedList, response: vs_data) do
  stub_step(GeneratePersonaBatch, response: persona_data) do
    PersonaGenerator.new(@persona_set).call
  end
end
```

**Why low:** Needs per-step adapter routing instead of global `default_adapter`. Architectural change. Depends on F1 (block form) first.

### F6: `validate` severity levels — warn vs fail (MEDIUM)

**Problem:** `validate` is binary. No way to express "suspicious but not invalid."

```ruby
# Too aggressive — tied scores ARE valid, just low-signal
validate "scores should differ for meaningful signal" do |output|
  output[:score_a] != output[:score_b]
end
```

Tied scores happen ~10% of the time. Hard-failing wastes the API call and retries won't help.

**Needed:**
```ruby
validate "scores should differ", severity: :warn do |output|
  output[:score_a] != output[:score_b]
end
```

Where `:warn` logs but returns `ok?: true`, and `:fail` (default) returns `ok?: false`.

**Why medium:** Real cost impact — unnecessary retries on $0.01+ API calls for soft constraints.

### F7: `max_cost` token proxy when pricing unknown (LOW)

**Problem:** `max_cost` checks `CostCalculator` before the API call. If the model has no pricing data in the gem's cost table, the check is silently skipped.

**Needed:** `max_tokens` as a proxy — refuse the call based on estimated token count even when pricing is unknown.

**Why low:** Affects edge cases with uncommon models. Most production models have pricing data.

## Implementation order

| Phase | Feature | Effort | Dependencies |
|-------|---------|--------|-------------|
| 1 | F1: stub_step block form | ~1h | — |
| 2 | F6: validate severity | ~2h | — |
| 3 | F3: track_history in RakeTask | ~1h | — |
| 4 | F4: compare_models in RakeTask | ~2h | — |
| 5 | F5: scoped stub_step | ~3h | F1 |
| 6 | F7: max_cost token proxy | ~2h | — |
| 7 | F2: pipeline fan-out | ~8h | separate ADR |

Phases 1-4 are safe incremental additions. Phase 5-6 are small. Phase 7 is a design challenge that warrants its own ADR.

## Release plan

- **v0.4.3:** F1 (stub_step block) + F6 (validate severity) + F3 (track_history) — highest impact, low risk
- **v0.4.4:** F4 (compare rake) + F5 (scoped stub) + F7 (token proxy) — convenience + edge cases
- **v0.5.0:** F2 (fan-out) + ADR-0015 (prompt A/B) — architectural additions

## Success criteria

1. PersonaTool drops all custom `with_test_adapter` helpers — replaced by F1 block form
2. `validate severity: :warn` eliminates unnecessary retries on soft constraints
3. `t.track_history = true` makes drift tracking zero-config
4. All 7 requests resolved without breaking existing API
