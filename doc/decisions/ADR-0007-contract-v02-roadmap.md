---
id: ADR-0007
decision_type: adr
status: Accepted
created: 2026-03-22
summary: "ruby_llm-contract v0.2 — from convenience wrapper to unique product"
owners:
  - justi
---

# ADR-0007: ruby_llm-contract v0.2

## Context

v0.1 is a convenience wrapper. Everything it does can be replicated in ~10 lines of ruby_llm + dry-types. The eval system is a tautology (you hardcode the answer, gem confirms it passes). There is no feature that justifies a gem over a helper module.

v0.2 must add something you **cannot** write in 10 lines.

## What v0.1 is (honest assessment)

- Standaryzacja retry + validate + schema w DSL — convenience, not necessity
- 961 tests, solid code — quality of implementation, not product value
- Defensive JSON parsing (code fences, BOM, prose) — nice, not essential
- Eval with sample_response — useless (tautology)

## What v0.2 must be

The only thing no Ruby gem does and you can't write in 10 lines:

**Regression testing for LLM prompts with real API calls and CI gating.**

## v0.2 Spec

### Eval with real dataset

```ruby
ClassifyTicket.define_eval("regression") do
  add_case "billing ticket",
    input: "I was charged twice on my invoice",
    expected: { priority: "high", category: "billing" }

  add_case "urgent outage",
    input: "Database is down, we're losing data",
    expected: { priority: "urgent" }

  add_case "feature request",
    input: "Can you add dark mode?",
    expected: { priority: "low", category: "feature" }

  add_case "positive feedback",
    input: "Your product is amazing, thanks!",
    expected: { priority: "low", category: "other" }
end
```

### Two modes

**Offline (zero API calls, tests contract only):**
```ruby
report = ClassifyTicket.run_eval("regression")
# Uses sample_response if defined, otherwise skips online cases
# Tests: does my contract accept/reject the expected values?
```

**Online (real LLM, ~$0.01 per run):**
```ruby
report = ClassifyTicket.run_eval("regression", context: { model: "gpt-4.1-nano" })
# Calls LLM for each case
# Checks: does LLM output match expected values?
# Checks: does LLM output pass contract (schema + validate)?
```

### Partial matching

`expected` is a subset. LLM returns 5 fields, you check 2:

```ruby
add_case "billing",
  input: "Invoice problem",
  expected: { priority: "high", category: "billing" }
  # LLM returns {priority: "high", category: "billing", confidence: 0.9}
  # Match: priority OK, category OK → PASS (confidence ignored)
```

### Report

```ruby
report.score      # => 0.75 (3/4 cases passed)
report.passed?    # => false (not 100%)
report.failures   # => [
  #   { case: "urgent outage",
  #     expected: { priority: "urgent" },
  #     got: { priority: "high" },
  #     mismatches: { priority: { expected: "urgent", got: "high" } } }
  # ]
```

### CI integration

```ruby
# RSpec
expect(ClassifyTicket).to pass_eval("regression")
  .with_context(model: "gpt-4.1-nano")
  .with_minimum_score(0.8)

# Rake
# rake eval:run[ClassifyTicket,regression,gpt-4.1-nano]
```

### What this enables that nothing else does

1. **Prompt regression testing** — change prompt, run eval, see if accuracy dropped
2. **Model comparison** — run same eval on nano vs mini vs full, compare scores
3. **CI gate** — block merge if eval score < threshold
4. **Cost of quality** — "nano scores 85%, mini scores 98%. mini costs 4x more. Is 13% worth it?"

## v0.2 NOT in scope

- Baseline snapshots (comparing with previous run) — v0.3
- Auto-routing (ML-based model selection) — v0.4
- Persistence (storing eval history) — v0.3
- Dashboard — v0.4
- `ruby_llm-suite` meta-gem — dropped from roadmap

## Production issues to fix in v0.2

From real production use (reddit_promo_planner, 8 Steps, Rails 8.1):

### P1: Eval files not autoloaded by Rails

Files in `app/steps/eval/` are not picked up by Zeitwerk. `ClassifyThreads.run_eval("smoke")` raises `ArgumentError: No eval 'smoke' defined` because the eval file was never loaded.

Current workaround: `load Rails.root.join("app/steps/eval/classify_threads_eval.rb")` in each test.

**Fix:** Convention-based autoloading. Step eagerly loads `eval/#{step_file_name}_eval.rb` if it exists. Or provide `RubyLLM::Contract.load_evals!(dir)` helper. Or a Rails engine that adds `app/steps/eval` to autoload paths.

### P2: report.results returns raw Hashes, not objects

`report.results` returns `[{case_name: "...", passed: true}]`. Writing assertions requires `r[:case_name]`, `r[:passed]` instead of `r.name`, `r.passed?`.

**Fix:** Return Struct or value object with `name`, `passed?`, `input`, `output`, `expected`, `mismatches` methods. Redesigned as part of eval v0.2 Report.

### P3: No way to run all evals at once

Each eval is per-Step. No `RubyLLM::Contract.run_all_evals` or CLI. Running 5+ evals requires knowing each Step name.

**Fix:** `RubyLLM::Contract.run_all_evals` that discovers all Steps with defined evals. Rake task: `rake ruby_llm_contract:eval`. Returns combined report.

### P4: verify blocks get symbol keys but string keys are common in Rails

`verify ->(o) { o["threads"]... }` with string keys silently returns nil (passes vacuously). No warning.

**Fix:** Document that output always has symbol keys. Add warning when verify block returns nil (likely key mismatch).

## Implementation plan

### Phase 1: Dataset with expected (not sample_response)

Extend `define_eval` to accept `add_case` with `input:` + `expected:` (partial hash).

Keep backward compat with existing `sample_response` + `verify` API.

### Phase 2: Online eval runner

When `context` has a real adapter (not Test), call LLM for each case. Compare output against `expected` using partial matching.

### Phase 3: Report redesign

- `report.results` returns value objects with `name`, `passed?`, `input`, `output`, `expected`, `mismatches`
- `report.failures` returns only failed cases
- `report.score` returns float 0.0-1.0

### Phase 4: CI integration

- `pass_eval` matcher accepts `.with_minimum_score(0.8)` chain
- Rake task: `rake ruby_llm_contract:eval`
- `RubyLLM::Contract.run_all_evals` for programmatic use

### Phase 5: Rails integration

- Engine or initializer that autoloads `app/steps/eval/*.rb`
- Convention: `app/steps/eval/classify_threads_eval.rb` auto-loaded with `ClassifyThreads`
- Warning when verify block returns nil (likely string key instead of symbol)

## Success criteria

A developer can:
1. Define 10 test cases with `add_case input:, expected:` per Step
2. Run `bundle exec rake ruby_llm_contract:eval` in CI
3. See "8/10 passed on nano, 10/10 on mini" with per-case failure details
4. Eval files autoload in Rails without manual `load`
5. Report API is `result.name`, `result.passed?`, not `result[:case_name]`

No other Ruby gem enables this workflow.
