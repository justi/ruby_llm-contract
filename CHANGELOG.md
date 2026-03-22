# Changelog

## 0.2.0 (2026-03-22)

Eval that matters — from convenience wrapper to regression testing for LLM prompts.

### Breaking changes

- **`report.results` returns `CaseResult` objects** instead of hashes. Use `result.name`, `result.passed?`, `result.score` instead of `result[:case_name]`, `result[:passed]`. `CaseResult#to_h` available for backward compat.

### Features

- **`add_case` in `define_eval`** — `add_case "billing", input: "...", expected: { priority: "high" }` with partial matching. Expected is a subset; extra keys in output are ignored.
- **`CaseResult` value objects** — `result.name`, `result.passed?`, `result.output`, `result.expected`, `result.mismatches` (structured diff).
- **`report.failures`** — returns only failed cases.
- **`pass_eval` with minimum score** — `expect(Step).to pass_eval("regression").with_minimum_score(0.8)` for threshold-based CI gating.
- **`RubyLLM::Contract.run_all_evals`** — discovers all Steps/Pipelines with evals, runs them all. Includes inherited evals.
- **`RubyLLM::Contract::RakeTask`** — `rake ruby_llm_contract:eval` with `minimum_score` and `fail_on_empty` options.
- **`eval_names`, `eval_defined?`** — introspection methods on Steps.
- **Rails Railtie** — auto-loads eval files from `app/steps/eval/` and `app/contracts/eval/` after initialization.

### Fixes

- **P1: Eval files not autoloaded by Rails** — Railtie uses `load` (not Zeitwerk autoload) since eval files don't define constants.
- **P2: report.results returns raw Hashes** — now returns `CaseResult` objects.
- **P3: No way to run all evals at once** — `Contract.run_all_evals` + Rake task.
- **P4: verify blocks get symbol keys but string keys are common** — warns when `validate` or `verify` proc returns nil (likely string key on symbolized hash).
- **Inherited evals** — subclasses are auto-registered via `inherited` hook + ObjectSpace scan at `define_eval` time.
- **Custom labels preserved** — `EvaluationResult(label: "PARTIAL")` now flows through to `CaseResult#label`.

### Stats

- 1028 tests, 0 failures

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
