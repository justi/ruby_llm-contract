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

## How each audience reads this

**Rails dev team (consumer):** "We adopted the gem, replaced ~960 LOC, and it works. These are the friction points we hit daily. F1 (test leaks) costs us time on every PR. F6 (hard-fail on soft checks) wastes API budget. F2 (fan-out) forced us to keep 120 LOC of manual orchestration. The rest are nice-to-haves."

**Gem owner:** "5 of 7 are incremental — yield+ensure, an attr_accessor on RakeTask, a rake wrapper. Safe to ship in patch releases. F2 (fan-out) is a scope question: the gem does contracts, not orchestration. Adding fan-out pulls in concurrency concerns, error aggregation, partial retry — that's a different gem. F6 (severity) sounds simple but redefines what 'contract' means. A contract is binary. If it can warn-but-pass, it's monitoring, not a contract. Better to add a separate `observe` concept."

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

**Team discussion:**

RSpec `stub_step` already scopes per-step via `allow().and_wrap_original` — the mock lifecycle cleans up automatically. The real leak is in **Minitest** where `stub_step` ignores `step_class` and sets `configuration.default_adapter` globally. This is a parity bug, not just a missing feature.

**Implementation:** Block form (save/yield/ensure) on `stub_all_steps` in both frameworks + fix Minitest `stub_step` to actually route per-step. Also ship RSpec `around(:each)` auto-reset as opt-in safety net (`RubyLLM::Contract::RSpec.auto_reset!`). For Minitest, document `teardown { reset_configuration! }`.

**Business value:** Eliminates flaky CI from leaked adapter state. Highest ROI feature in the list.

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

**Decision: Won't implement.** This contradicts the gem's core philosophy stated in migration.md:

> Don't put parallelism in the gem. Thread management is your app's concern. The gem provides the contract; you call it however you want.

Fan-out is orchestration, not contract enforcement. The gem's job is: validate schema, enforce constraints, escalate models, track quality. Parallelism, batching, retry-of-partial-failures — that's application-level orchestration that depends on your infra (Sidekiq, GoodJob, threads, Ractors).

**How to do this in the application instead:**

```ruby
# PersonaGenerator — app-level orchestration, ~30 LOC
class PersonaGenerator
  def call
    # fan-out: parallel across fields
    seed_results = Concurrent::Promises.zip(
      *seed_fields.map { |f| Concurrent::Promises.future { ExpandSeedList.run(f) } }
    ).value!

    # fan-out: parallel across batches
    batch_results = batch_prompts.map { |prompt|
      Concurrent::Promises.future { GeneratePersonaBatch.run(prompt) }
    }.map(&:value!)

    # retry: fill gaps sequentially
    remaining = find_gaps(batch_results)
    remaining.each { |r| GeneratePersonaBatch.run(r) }
  end
end
```

Each step is still a Contract::Step with schema validation, retry_policy, and cost tracking. The gem does its job (enforce contracts). The app does its job (orchestrate calls). 120 LOC of orchestration is the right answer — it's explicit, debuggable, and doesn't couple your concurrency model to the gem.

### F3: EvalHistory auto-append in RakeTask (MEDIUM)

**Problem:** `EvalHistory` class exists. `RakeTask` doesn't use it.

```ruby
# Needed
RubyLLM::Contract::RakeTask.new do |t|
  t.track_history = true  # auto-append each run to .eval_history/
end
```

**Why medium:** Makes drift tracking zero-config for CI. Currently requires manual `report.save_history!` call.

**Team discussion:**

- **Save always, not just passes.** Score drop from 0.9 to 0.7 is the most valuable data point. `drift?` interprets the trend; history should be a faithful record.
- **Opt-in** (`track_history = false` default). Existing users should not find `.eval_history/` directories appearing after a patch upgrade.
- **Include model in history path.** RakeTask must pass `model:` to `save_history!` — without it, runs against different models overwrite each other.
- **Include git SHA + timestamp in filenames.** Prevents concurrent CI runs from racing on the same file.

**Implementation:** One `attr_accessor`, save all reports (pass and fail) in `define_task` when enabled.

**Business value:** Drift detection without human discipline — CI auto-tracks quality trends.

### F4: `compare_models` in RakeTask (LOW)

**Problem:** `compare_models` is only available programmatically. No rake wrapper.

```ruby
RubyLLM::Contract::RakeTask.new(:"contracts:compare") do |t|
  t.models = %w[gpt-4o-mini gpt-4o gpt-5-mini]
  t.minimum_score = 0.8
end
```

**Decision: Won't implement.** Team consensus after discussion:

- Model comparison is exploratory (monthly, interactive) — not a CI-per-commit pattern. Rake task is the wrong interface.
- A generic wrapper either does too little (one step) or too much (all steps × all models with unclear failure semantics).
- Every user's needs differ — which steps, which models, what threshold. A 2-line custom rake task is clearer:

```ruby
task "contracts:compare" => :environment do
  comparison = ClassifyTicket.compare_models("regression", models: %w[gpt-4o-mini gpt-4o])
  comparison.print_summary
  abort "No model meets threshold" unless comparison.best_for(min_score: 0.8)
end
```

The gem provides primitives. Users compose them.

### F5: Scoped `stub_step` per contract (LOW)

**Problem:** `stub_step` sets a global adapter — all contracts see the same response. Pipeline tests need different responses per step.

```ruby
stub_step(ExpandSeedList, response: vs_data) do
  stub_step(GeneratePersonaBatch, response: persona_data) do
    PersonaGenerator.new(@persona_set).call
  end
end
```

**Team discussion:**

In RSpec this **already works** — `stub_step(A, ...)` + `stub_step(B, ...)` routes per-step via `allow().and_wrap_original`. No nesting needed. The problem is Minitest only.

**Implementation for Minitest:** Thread-local adapter map with `nil?` guard on hot path:

```ruby
def resolve_adapter(context)
  adapter = context[:adapter]
  adapter ||= Contract.step_adapter_overrides[self] unless Contract.step_adapter_overrides.empty?
  adapter ||= Contract.configuration.default_adapter
end
```

Also add `stub_steps` (plural) for ergonomics — hash API, single block, no nesting:

```ruby
stub_steps(
  ExpandSeedList => { response: seed_data },
  GeneratePersonaBatch => { response: persona_data }
) do
  PersonaGenerator.new(@persona_set).call
end
```

Depends on F1 (block form + Minitest parity).

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

**Decision: Not in this form.** A contract is binary by definition — met or not met. Adding `:warn` to `validate` blurs the boundary between contract enforcement and observability. If a check doesn't fail the contract, it's not a contract constraint — it's an observation.

**Proposed alternative — `observe` DSL (v0.5+):**

```ruby
class EvaluateStandard < RubyLLM::Contract::Step::Base
  # Hard contract — fails the call
  validate("valid priority") { |o| %w[low medium high].include?(o[:priority]) }

  # Soft observation — logs but never fails
  observe("scores should differ") { |o| o[:score_a] != o[:score_b] }
end

result = EvaluateStandard.run(input)
result.ok?            # => true (observe doesn't affect this)
result.observations   # => ["scores should differ: false"]
```

`observe` hooks into `Contract.logger` (structured logging from v0.4.0). Observations are tracked in eval reports as metadata — visible in history, but not affecting score. This preserves the contract-is-binary invariant while giving production the "suspicious but not invalid" signal.

**Timeline:** v0.5+ — needs design work on how observations interact with eval scoring and history trending.

### F7: `max_cost` token proxy when pricing unknown (LOW)

**Problem:** `max_cost` checks `CostCalculator` before the API call. If the model has no pricing data in the gem's cost table, the check is silently skipped.

**Team discussion:**

Silent skip (warn to stderr, proceed) is the worst outcome. No backward compatibility constraint — fail closed by default.

**Implementation:**
- `max_cost` with unknown pricing → **refuse the call** by default. Clear error: "max_cost set but model 'X' has no pricing data. Register pricing via `CostCalculator.register_model` or set `max_tokens` as fallback."
- Add `CostCalculator.register_model("ft:gpt-4o-custom", input_per_1m: 3.0, output_per_1m: 6.0)` for custom/fine-tuned models.
- `max_cost 0.05, on_unknown_pricing: :warn` for explicit opt-in to old behavior if needed.
- `max_tokens` as a standalone DSL option — useful independent of pricing (rate limits, context window concerns). Checks estimated input + output tokens regardless of model pricing availability.

## Implementation order

| Phase | Feature | Effort | Decision |
|-------|---------|--------|----------|
| 1 | F1: stub_step block + Minitest parity fix | ~2h | **Do — v0.4.3** |
| 2 | F3: track_history in RakeTask | ~1h | **Do — v0.4.3** |
| 3 | F7: max_cost fail closed + register_model | ~2h | **Do — v0.4.3** |
| 4 | F5: scoped stub_step (Minitest) + stub_steps plural | ~3h | **Do — v0.4.4** (depends on F1) |
| 5 | F6: observe DSL | ~3h | **v0.5+** — needs design |
| — | F2: pipeline fan-out | — | **Won't do** — app-level |
| — | F4: compare_models in RakeTask | — | **Won't do** — programmatic API sufficient |

## Release plan

- **v0.4.3:** F1 (stub_step block + Minitest parity) + F3 (track_history, save always, opt-in) + F7 (fail closed, register_model)
- **v0.4.4:** F5 (thread-local adapter map, stub_steps plural)
- **v0.5.0:** F6 as `observe` DSL + ADR-0015 (prompt A/B)
- **Won't do:** F2 (fan-out — app-level orchestration), F4 (compare rake — users write 2-line custom task)

## Success criteria

1. PersonaTool drops all custom `with_test_adapter` helpers — replaced by F1 block form
2. Minitest `stub_step` actually routes per-step (parity with RSpec)
3. `t.track_history = true` makes drift tracking zero-config in CI
4. `max_cost` refuses calls when pricing unknown — no silent skips
5. Three of 7 implemented in v0.4.3, one in v0.4.4, one redesigned for v0.5. Two correctly rejected
