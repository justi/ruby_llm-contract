# Changelog

## 0.3.3 (2026-03-23)

- **Skipped cases visible in regression diff** — baseline PASS → current SKIP now detected as regression by `without_regressions` and `fail_on_regression`.
- **Skip only on missing adapter** — eval runner no longer masks evaluator errors as SKIP. Only "No adapter configured" triggers skip.
- **Array/Hash sample pre-validation** — `sample_response([{...}])` correctly validated against schema instead of silently skipping.
- **`assume_model_exists: false` forwarded** — boolean `false` no longer dropped by truthiness check in adapter options.
- **Duplicate case names caught at definition** — `add_case`/`verify` with same name raises immediately, not at run time.

## 0.3.2 (2026-03-23)

- **Array response preserved** — `Adapters::RubyLLM` no longer stringifies Array content. Steps with `output_type Array` work correctly.
- **Falsy prompt input** — `run(false)` and `build_messages(false)` pass `false` to dynamic prompt blocks instead of falling back to `instance_eval`.
- **`retry_on` flatten** — `retry_on([:a, :b])` no longer wraps in nested array.
- **Builder reset** — `Prompt::Builder` resets nodes on each build (no accumulation on reuse).
- **Pipeline false output** — `output: false` no longer shows "(no output)" in pretty_print.

## 0.3.1 (2026-03-23)

Fixes from persona_tool production deployment (4 services migrated).

- **Proc/Lambda in `expected_traits`** — `expected_traits: { score: ->(v) { v > 3 } }` now works.
- **Zeitwerk eager-load** — `load_evals!` eager-loads `app/contracts/` and `app/steps/` before loading eval files. Fixes uninitialized constant errors in Rake tasks.
- **Falsy values** — `expected: false`, `input: false`, `sample_response(nil)` all handled correctly.
- **Context key forwarding** — `provider:` and `assume_model_exists:` forwarded to adapter. `schema:` and `max_tokens:` are step-level only (no split-brain).
- **Deep-freeze immutability** — constructors never mutate caller's data.

## 0.3.0 (2026-03-23)

Baseline regression detection — know when quality drops before users do.

### Features

- **`report.save_baseline!`** — serialize eval results to `.eval_baselines/` (JSON, git-tracked)
- **`report.compare_with_baseline`** — returns `BaselineDiff` with regressions, improvements, score_delta, new/removed cases
- **`diff.regressed?`** — true when any previously-passing case now fails
- **`without_regressions` RSpec chain** — `expect(Step).to pass_eval("x").without_regressions`
- **RakeTask `fail_on_regression`** — blocks CI when regressions detected
- **RakeTask `save_baseline`** — auto-save after successful run
- **Migration guide** — `docs/guide/migration.md` with 7 patterns for adopting the gem in existing Rails apps

### Stats

- 1086 tests, 0 failures

## 0.2.3 (2026-03-23)

Production hardening from senior Rails review panel.

- **`around_call` propagates exceptions** — no longer silently swallows DB errors, timeouts, etc. User who wants swallowing can rescue in their block.
- **Nil section content skipped** — `section "X", nil` no longer renders `"null"` to the LLM. Section is omitted entirely.
- **Range support in `expected:`** — `expected: { score: 1..5 }` works in `add_case`. Previously only Regexp was supported.
- **`Trace#dig`** — `trace.dig(:usage, :input_tokens)` works on both Step and Pipeline traces.

## 0.2.2 (2026-03-23)

Fixes from first real-world integration (persona_tool).

- **`around_call` fires per-run** — not per-attempt. With retry_policy, callback fires once with final result. Signature: `around_call { |step, input, result| ... }`
- **`Result#trace` always `Trace` object** — never bare Hash. `result.trace.model` works on success AND failure.
- **`around_call` exception safe** — warns and returns result instead of crashing.
- **`model` DSL** — `model "gpt-4o-mini"` per-step. Priority: context > step DSL > global config.
- **Test adapter `raw_output` always String** — Hash/Array normalized to `.to_json`.
- **`Trace#dig`** — `trace.dig(:usage, :input_tokens)` works.

## 0.2.1 (2026-03-23)

Production DX improvements from first real-world integration (persona_tool).

### Features

- **`temperature` DSL** — `temperature 0.3` in step definition, overridable via `context: { temperature: 0.7 }`. RubyLLM handles per-model normalization natively.
- **`around_call` hook** — callback for logging, metrics, observability. Replaces need for custom middleware.
- **`build_messages` public** — inspect rendered prompt without running the step.
- **`stub_step` RSpec helper** — `stub_step(MyStep, response: { ... })` reduces test boilerplate. Auto-included via `require "ruby_llm/contract/rspec"`.
- **`estimate_cost` / `estimate_eval_cost`** — predict spend before API calls.

### Fixes

- **Reload lifecycle** — `load_evals!` clears definitions before re-loading. Railtie hooks `config.to_prepare` for development reload. `define_eval` warns on duplicate name (suppressed during reload).
- **Pipeline eval cost** — uses `Pipeline::Trace#total_cost` (all steps), not just last step.
- **Adapter isolation** — `compare_models` and `run_all_own_evals` deep-dup context per run.
- **Offline mode** — cases without adapter return `:skipped` instead of crashing. Skipped cases excluded from score.
- **`expected_traits`** reachable from `define_eval` DSL via `add_case`.
- **`verify`** raises when both positional and `expect:` keyword provided.
- **`best_for`** excludes zero-score models from recommendation.
- **`print_summary`** replaces `pretty_print` (avoids `Kernel#pretty_print` shadow).
- **`CaseResult#to_h`** round-trips correctly (`name:` key).

### Docs

- All 5 guides updated for v0.2 API
- Symbol keys documented
- Retry model priority documented
- Test adapter format documented

### Stats

- 1077 tests, 0 failures
- 3 architecture review rounds, 32 findings fixed

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
