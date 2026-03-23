# Changelog

## 0.2.0 (2026-03-23)

Contracts for LLM quality. Know which model to use, what it costs, and when accuracy drops.

### Breaking changes

- **`report.results` returns `CaseResult` objects** instead of hashes. Use `result.name`, `result.passed?`, `result.score` instead of `result[:case_name]`, `result[:passed]`. `CaseResult#to_h` for backward compat.
- **`report.print_summary`** replaces `report.pretty_print` (avoids shadowing `Kernel#pretty_print`).

### Features

- **`add_case` in `define_eval`** — `add_case "billing", input: "...", expected: { priority: "high" }` with partial matching. Supports `expected_traits:` for regex/range matching.
- **`CaseResult` value objects** — `result.name`, `result.passed?`, `result.output`, `result.expected`, `result.mismatches` (structured diff), `result.cost`, `result.duration_ms`.
- **`report.failures`** — returns only failed cases. `report.skipped` counts skipped (offline) cases.
- **Model comparison** — `Step.compare_models("eval", models: %w[nano mini full])` runs same eval across models. Returns table with score/cost/latency per model. `comparison.best_for(min_score: 0.95)` returns cheapest model meeting threshold.
- **Cost tracking** — `report.total_cost`, `report.avg_latency_ms`, per-case `result.cost`. Pipeline eval uses total pipeline cost, not just last step.
- **Cost prediction** — `Step.estimate_cost(input:, model:)` and `Step.estimate_eval_cost("eval", models: [...])` predict spend before API calls.
- **CI gating** — `pass_eval("regression").with_minimum_score(0.8).with_maximum_cost(0.01)`. RakeTask with suite-level `minimum_score` and `maximum_cost`.
- **`RubyLLM::Contract.run_all_evals`** — discovers all Steps/Pipelines with evals, runs them all. Includes inherited evals.
- **`RubyLLM::Contract::RakeTask`** — `rake ruby_llm_contract:eval` with `minimum_score`, `maximum_cost`, `fail_on_empty`, `eval_dirs`.
- **Rails Railtie** — auto-loads eval files via `config.after_initialize` + `config.to_prepare` (supports development reload).
- **Offline mode** — cases without adapter return `:skipped` instead of crashing. Skipped cases excluded from score/passed.
- **Safe `define_eval`** — warns on duplicate name; suppressed during reload.

### Fixes

- **P1: Eval files not autoloaded by Rails** — Railtie uses `load` (not Zeitwerk). Hooks into reloader for dev.
- **P2: report.results returns raw Hashes** — now returns `CaseResult` objects.
- **P3: No way to run all evals at once** — `Contract.run_all_evals` + Rake task.
- **P4: String vs symbol key mismatch** — warns when `validate` or `verify` proc returns nil.
- **Pipeline eval cost** — uses `Pipeline::Trace#total_cost` (all steps), not just last step.
- **Reload lifecycle** — `load_evals!` clears definitions before re-loading. Registry filters stale hosts.
- **Adapter isolation** — `compare_models` and `run_all_own_evals` deep-dup context per run.

### Verified with real API

```
Model                      Score       Cost  Avg Latency
---------------------------------------------------------
gpt-4.1-nano                0.67    $0.000032      687ms
gpt-4.1-mini                1.00    $0.000102     1070ms
```

### Stats

- 1077 tests, 0 failures
- 3 architecture review rounds, 32 findings fixed
- Verified with real OpenAI API (gpt-4.1-nano, gpt-4.1-mini)

## 0.1.0 (2026-03-20)

Initial release.

### Features

- **Step abstraction** — `RubyLLM::Contract::Step::Base` with prompt DSL, typed input/output
- **Output schema** — declarative structure via ruby_llm-schema, sent to provider for enforcement
- **Validate** — business logic checks (1-arity and 2-arity with input cross-validation)
- **Retry with model escalation** — start cheap, auto-escalate on contract failure or network error
- **Preflight limits** — `max_input`, `max_cost`, `max_output` refuse before calling the LLM
- **Pipeline** — multi-step composition with fail-fast, timeout, token budget
- **Eval** — offline contract verification with `define_eval`, `run_eval`, zero-verify auto-case
- **Adapters** — RubyLLM (production), Test (deterministic specs)
- **RSpec matchers** — `satisfy_contract`, `pass_eval`
- **Structured trace** — model, latency, tokens, cost, attempt log per step

### Robustness

- 1005 tests, 0 failures
- 42 bugs found and fixed via 10 rounds of adversarial testing
- 0 RuboCop offenses
- Parser handles: markdown code fences, UTF-8 BOM, JSON extraction from prose
- SchemaValidator: full nested validation, additionalProperties, minItems/maxItems, minLength/maxLength
- Deep-frozen parsed_output prevents mutation via shared references
