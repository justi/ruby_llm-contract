---
id: ADR-0010
decision_type: adr
status: Accepted
created: 2026-03-22
summary: "v0.2 architecture review — 13 findings from designer/architect/QA panel"
owners:
  - justi
---

# ADR-0010: v0.2 Architecture Review

## Context

Three-reviewer panel (architect, QA, API designer) audited v0.2 implementation against ADR-0007/0008 specs. Found 4 high, 5 medium, 4 low severity issues. All fixed in this commit.

## Findings

### HIGH

**H1: Pipeline eval counts cost/latency from last step only**

`Runner#normalize_pipeline_result` extracts trace from `step_results.last`. For a 3-step pipeline, `report.total_cost` reports 1/3 of actual cost. CI gate `with_maximum_cost` on pipeline eval undercounts by factor N.

Fix: Use `Pipeline::Trace` total_cost and total_latency_ms when available.

**H2: `compare_models` shares mutable Test adapter across model runs**

Same `Adapters::Test` (with mutable `@index`) is shared between model runs. Model B gets responses meant for model C. Silent data corruption.

Fix: `compare_models` clones context per model run. Document that Test adapter with `responses:` requires separate instances per model.

**H3: Railtie comment says `load`, code does `require`**

`require f` is a no-op after first load. In Rails development, editing an eval file does NOT refresh definitions without server restart.

Fix: Change `require f` to `load f` in `load_evals!`.

**H4: Offline mode crashes or makes real API calls**

ADR-0007 promises "zero API calls, tests contract only." Without `sample_response` and without adapter: crash. With ruby_llm gem installed + API key: silent real API calls.

Fix: When no adapter and no sample_response, skip case with status `:skipped` instead of crashing.

### MEDIUM

**M1: `expected_traits` unreachable from `define_eval` DSL**

`add_case` and `verify` in `EvalDefinition` don't accept `expected_traits`. The entire `TraitEvaluator` path is dead code from `define_eval`.

Fix: Add `expected_traits:` parameter to `add_case`.

**M2: `with_maximum_cost` failure path has zero test coverage**

Test adapter returns 0 tokens → CostCalculator returns nil → cost always 0. No test proves `with_maximum_cost` fails when cost exceeds budget.

Fix: Add test with constructed CaseResult objects that have real cost values.

**M3: `discover_eval_hosts` is dead code**

Defined in `contract.rb:45-54`, never called.

Fix: Remove.

**M4: No `eval_dir` for non-Rails contexts**

`load_evals!` without arguments does nothing outside Rails. Sinatra/plain Ruby can't auto-discover eval files.

Fix: Add `eval_dirs` accessor to RakeTask and pass to `load_evals!`.

**M5: `verify` silently overwrites positional arg with `expect:` keyword**

`verify("x", {foo: 1}, expect: {bar: 2})` loses `{foo: 1}` without warning.

Fix: Raise ArgumentError when both positional and keyword are provided.

### LOW

**L1: `pretty_print` shadows `Kernel#pretty_print`**

`pp report` calls custom method instead of standard Ruby inspection.

Fix: Rename to `print_report`.

**L2: `CaseResult#to_h` round-trip broken**

Serializes `case_name:`, constructor expects `name:`. `CaseResult.new(**result.to_h)` fails.

Fix: Use `name:` in `to_h`.

**L3: `best_for(min_score: 0.0)` recommends model with 0% accuracy**

Fix: Exclude models with score 0.0 from recommendation.

**L4: `report.score` is average of case scores, not pass ratio**

With partial scores (0.5 from JsonIncludes), score diverges from pass_rate. This is by design (richer metric), but undocumented.

Fix: Document behavior. No code change.

## Implementation

All fixes applied in single commit. 13 findings → 12 code changes + 1 documentation.
