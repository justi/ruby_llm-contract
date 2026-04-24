# Changelog

## 0.7.3 (2026-04-24)

Adoption-friction release. No runtime behavior changes — every delta is in `docs/`, `examples/`, or `spec/integration/` (plus the `version.rb` / Gemfile.lock bumps). Upgrading from 0.7.2 picks up the expanded guide set, the new runnable showcases, and one extra integration spec.

### Documentation

- **New guide: `docs/guide/why.md`** — four production failure modes the gem exists for (schema-valid logically wrong, silent prompt regression, sampling variance on fixed-temperature models, runaway cost). Opens from a concrete incident each time; designed for readers who have not yet felt the pain the gem relieves.
- **New guide: `docs/guide/rails_integration.md`** — seven Rails-specific FAQs with runnable snippets: where step classes live (`app/contracts/`), initializer setup, background jobs, `around_call` observability, RSpec/Minitest stubs, error handling in controllers, CI gate wiring.
- **README adoption-friction pass** — added a short "Do I need this?" block after Install, a reading-order hint (`README → why.md → getting_started.md`), and outcome-based labels in the docs index ("Prevent silent prompt regressions" instead of "Eval-First", etc.).
- **TL;DR box at the top of every guide** — single-sentence orientation for readers who land via search; "Skip if" clause added where real confusion exists (`eval_first.md`, `testing.md`, `migration.md`).
- **API coverage gaps closed** — `estimate_cost` / `estimate_eval_cost`, `max_cost on_unknown_pricing: :warn`, `run_eval(..., concurrency:)`, `around_call` testing patterns now documented in `getting_started.md`, `eval_first.md`, `testing.md`.
- **Industry-standard terminology** — `temperature-locked` → `fixed-temperature`, `variance-induced` → `sampling variance`, `severity signals` → `severity keywords`, `takeaway drift` → `tone/takeaways mismatch`.
- **`docs/architecture.md` refresh** — diagram now reflects the current class layout: added `Step::RetryPolicy`, `Pipeline::Result`, `Eval::AggregatedReport`, `Eval::BaselineDiff`, `Eval::PromptDiffComparator`, `Eval::EvalHistory`, `Eval::RetryOptimizer`, `OptimizeRakeTask`. Replaced the outdated `Eval::TraitEvaluator` entry with `Eval::ExpectationEvaluator`.
- **Business framing added to guides** — every guide opens with a concrete production scenario or "why it matters" hook before the API reference.

### Examples — consolidated on `SummarizeArticle`, renumbered 00-06

The previous 12-file set mixed a private Reddit promo planner, customer support, meetings, keyword extraction, and translation. The new set is seven runnable files, each answering one adopter question on the README's `SummarizeArticle` case.

| # | File | Answers |
|---|------|---------|
| 00 | `00_basics.rb` | How do I start? (seven incremental layers + real-LLM pointer) |
| 01 | `01_fallback_showcase.rb` | Show me the gem in 30 seconds (zero API keys) |
| 02 | `02_real_llm_minimal.rb` | How do I plug in a real LLM? (~30 lines) |
| 03 | `03_summarize_with_keywords.rb` | How does the contract evolve? (growing prompt) |
| 04 | `04_summarize_and_translate.rb` | Pipeline composition + pipeline-level `run_eval` |
| 05 | `05_eval_dataset.rb` | How do I stop silent prompt regressions? |
| 06 | `06_retry_variants.rb` | `attempts: 3`, `reasoning_effort` escalation, cross-provider (Ollama → Anthropic → OpenAI) |

Every file carries an "Expected output" block in its header so readers see the result without running the script. The `docs/ideas/` directory is now fully untracked (already in `.gitignore`; one stray file removed from version control).

### Examples — bug fixes carried along

- **Schema pitfall fixed in 5 files** — `array :x do; string :y; ...; end` silently produces `items: string` and drops every declaration after the first, matching the documented pitfall in `spec/ruby_llm/contract/nested_schema_spec.rb:71`. Every affected array block is now wrapped in `object do...end`.
- **`examples/05_eval_dataset.rb` (pre-renumber: `09_eval_dataset.rb`) `result[:passed]` → `result.passed?`** — the previous code called `[]` on an `Eval::CaseResult` and raised `NoMethodError` at runtime.

### Testing

- **New `spec/integration/pipeline_eval_spec.rb`** — three cases guaranteeing pipeline-level `run_eval` stays functional: happy path, final-step mismatch, and fail-fast propagation when an intermediate `validate` rejects. Closes the "09 STEP 5 pipeline evaluation" known issue flagged in the 0.7.2 release. The fail-fast case asserts `step_status == :validation_failed` and the validate's label in `details`, so a regression that short-circuits on schema instead of validate would fail loudly.

### Deleted (private-project cleanup)

- `examples/01_classify_threads.rb`, `02_generate_comment.rb`, `03_target_audience.rb`, `10_reddit_full_showcase.rb`, `spec/integration/reddit_pipeline_spec.rb` — Reddit Promo Planner was a separate private project; its examples do not belong in the gem's public repo.
- `examples/02_output_schema.rb` — fully covered by `docs/guide/output_schema.md`; deleting avoids duplication.

## 0.7.2 (2026-04-22)

### Changed

- **Terminal output labels renamed for consistency with README narrative.** `print_summary` now prints `Hardest eval` (was `Constraining eval`), `Suggested fallback list` (was `Suggested chain`), and the production-mode table uses `first-attempt` / `fallback %` as column headers (was `single-shot` / `escalation`). Programmatic metric names unchanged: `single_shot_cost`, `single_shot_latency_ms`, `escalation_rate`. `RetryOptimizer::Result` exposes `hardest_eval` as an alias for `constraining_eval`.

### Documentation

- **`docs/guide/optimizing_retry_policy.md` rewritten** — 17.7k → 6.4k characters. Continues the `SummarizeArticle` narrative from README. Offline mode clearly positioned as wiring-check; real optimization runs via `LIVE=1 RUNS=3`. Output samples match actual `print_summary` format.
- **`docs/guide/getting_started.md` rewritten** — 8.7k → 6.1k. Every example uses `SummarizeArticle`. Evals + CI gates section moved before Budget caps. Structured Prompts / Dynamic Prompts / "Already using ruby_llm?" / Reasoning effort sections removed; content delegated to `prompt_ast.md` and README.
- **`docs/guide/eval_first.md` refined** — 6.3k → 5.0k. Switched to `SummarizeArticle` case. Team workflow section compressed with links back to `getting_started.md` for the matcher chain.
- **`docs/guide/testing.md` refined** — 10.7k → 7.4k. Switched to `SummarizeArticle` case. Threshold gating / Rake task / baseline walkthrough / prompt A/B sections delegated back to `getting_started.md` and `eval_first.md`.
- **`docs/guide/output_schema.md` DSL bug fix** — the Supported constraints table documented JSON Schema camelCase keys (`minLength`, `minItems`, `additionalProperties`) that are not valid DSL arguments. Every copy-paste from the previous table would have raised `ArgumentError`. Switched to snake_case (`min_length`, `min_items`, `additional_properties`) as the DSL actually expects; added a short note on the internal camelCase conversion.
- **`docs/guide/best_practices.md`, `pipeline.md`, `migration.md` sanity pass** — terminology alignment (model escalation → model fallback where narrative; `escalate` DSL method unchanged) and `SummarizeArticle` case where the guide is not inherently multi-step.

## 0.7.1 (2026-04-22)

### Changed (behavioral, follow-up to v0.7.0)

- **`Step::Base#run_once` no longer swallows adapter-phase `ArgumentError` as `:input_error`.** The previous blanket `rescue ArgumentError` was there to convert DSL misconfiguration (e.g. missing `prompt`) into an `:input_error` Result. Side effect: programmer bugs in adapter code that raised `ArgumentError` (wrong arity, bad config argument) were silently coerced into `:input_error` and retried as if the user had given bad input. Now the rescue is narrowed to the Runner-construction phase only — DSL configuration errors still produce `:input_error` (the `prompt has not been set` case is regression-tested), but `ArgumentError` raised from adapter code during `Runner#call` propagates to the caller. Input-type validation failures continue to produce `:input_error` through `InputValidator`'s own scoped rescue, unchanged.

## 0.7.0 (2026-04-21)

### Breaking changes

- **`:adapter_error` removed from `DEFAULT_RETRY_ON`.** New default: `[:validation_failed, :parse_error]`. `ruby_llm` already retries transport errors (`RateLimitError`, `ServerError`, `ServiceUnavailableError`, `OverloadedError`, timeouts) at the Faraday layer, so the previous default re-ran the same model on errors the HTTP middleware already retried with backoff. To restore pre-0.7 behavior: `retry_on :validation_failed, :parse_error, :adapter_error`. Recommended pattern: pair `:adapter_error` with `escalate "model_a", "model_b"` — a different model/provider can bypass what transport retry could not.
- **`AdapterCaller` narrows `rescue` from `StandardError` to `RubyLLM::Error` + `Faraday::Error`.** Provider errors and transport errors that escape ruby_llm's Faraday retry middleware (`Faraday::TimeoutError`, `Faraday::ConnectionFailed`) still produce `:adapter_error` as before. Programmer errors that are neither (`NoMethodError`, adapter code bugs) now propagate instead of being silently converted to `:adapter_error` and retried. **Known limitation:** adapter code raising `ArgumentError` is still coerced into `:input_error` by `Step::Base#run_once` (which rescues `ArgumentError` for input-type validation). Disambiguating adapter-ArgumentError vs input-validation-ArgumentError requires a `run_once` refactor and is tracked as a follow-up.

### Migration

If you rely on the old behavior, opt in explicitly:

```ruby
retry_policy do
  attempts 3
  retry_on :validation_failed, :parse_error, :adapter_error
end
```

Or better, with a model fallback chain:

```ruby
retry_policy do
  escalate "gpt-4.1-nano", "gpt-4.1-mini"
  retry_on :validation_failed, :parse_error, :adapter_error
end
```

## 0.6.4 (2026-04-20)

### Features

- **`production_mode:` on `compare_models` and `optimize_retry_policy`** — measures retry-aware, end-to-end cost per successful output. Pass `production_mode: { fallback: "gpt-5-mini" }` and each candidate runs with a runtime-injected `[candidate, fallback]` retry chain. The report exposes `escalation_rate`, `single_shot_cost`, and `effective_cost` so "the cheaper candidate" decision matches production cost rather than first-attempt cost.
- **New Report metrics** — `escalation_rate`, `single_shot_cost`, `effective_cost`, `single_shot_latency_ms`, `effective_latency_ms`, `latency_percentiles` (p50/p95/max). `AggregatedReport` averages all of them across `runs:`.
- **Extended `ModelComparison#table`** — when `production_mode:` is set, renders a `Chain` column (`candidate → fallback`) with `single-shot`, `escalation`, `effective cost`, `latency`, `score`. Edge case `candidate == fallback` renders as a single model and `—` in the escalation column, with retry injection skipped entirely so `effective == single-shot` by construction, not by coincidence.
- **`context[:retry_policy_override]`** — new context key that nullifies or replaces class-level `retry_policy` for a single call. Used internally by production-mode injection; safe to use directly when you need a transient override that doesn't mutate the step class.

### Scope

- Single-fallback (2-tier) chains only. Multi-tier chains can be inspected post-hoc via `trace.attempts` but aren't summarized in the optimize table.
- Costs with `runs: 3 + production_mode: { fallback: "gpt-5-mini" }` are ≈3× a single-shot eval plus the actual retry attempts — not 6×. Production-mode metrics come from a single pass.
- **Step-only.** Calling `compare_models` with `production_mode:` on a `Pipeline::Base` subclass raises `ArgumentError` — retry injection is Step-level and pipeline-wide fallback semantics aren't defined yet. Benchmark individual steps.

### Documentation

- **Guide: [Production-mode cost measurement](docs/guide/optimizing_retry_policy.md#production-mode-cost-measurement)** — API, metric interpretation, 2-tier scope note.

## 0.6.3 (2026-04-20)

### Features

- **`runs:` parameter on `compare_models` and `optimize_retry_policy`** — runs each candidate N times per eval and aggregates the mean score, mean cost per run, and mean latency. Reduces sampling variance in live mode where LLM outputs are non-deterministic (gpt-5 family enforces `temperature=1.0` server-side, so a single unlucky sample can misclassify a viable candidate as "failing"). Default `runs: 1` — backward compatible.
- **`RUNS=N` on `rake ruby_llm_contract:optimize`** — CLI flag for variance-aware optimization.
- **`Eval::AggregatedReport`** — duck-type `Report` exposing `score` (mean), `score_min`/`score_max` (spread), `total_cost` (mean per run), `pass_rate` (clean-pass count x/N), and `clean_passes`.
- **Guide: [Reducing variance with `runs:`](docs/guide/optimizing_retry_policy.md#reducing-variance-with-runs)** — when to use it and why.

## 0.6.2 (2026-04-18)

### Features

- **`Step.optimize_retry_policy`** — runs `compare_models` on ALL evals for the step, builds a score matrix, identifies the constraining eval, and suggests a retry chain. Chain's last model always passes all evals (safe fallback).
- **`rake ruby_llm_contract:optimize`** — one-command retry chain optimization. Prints score table, constraining eval, suggested chain, and copy-paste DSL.
- **Offline by default** — `optimize` uses `sample_response` (zero API calls) unless `LIVE=1` or `PROVIDER=` is set.
- **`EVAL_DIRS=` support** — non-Rails setups can specify eval file directories.
- **Guide: [Optimizing retry_policy](docs/guide/optimizing_retry_policy.md)** — full procedure with prerequisites, troubleshooting, and real-world example.

### Fixes

- Chain semantics aligned with `retry_executor` — retry fires on `validation_failed`/`parse_error`, not on low eval score. Disjoint eval coverage (A passes e1, B passes e2, neither passes both) correctly returns empty chain.
- Removed ActiveSupport dependency from rake task (`.presence` → `.empty?`).
- Added `require "set"` for non-Rails environments.

## 0.6.1 (2026-04-17)

### Features

- **Multi-provider operator tooling** — rake tasks support `PROVIDER=openai|anthropic|ollama`, `CANDIDATES=model@effort,...`, and `REASONING_EFFORT=low|medium|high`.
- **`rake ruby_llm_contract:recommend`** — wraps `Step.recommend` with CLI interface, prints best config, retry chain, DSL, rationale, and savings.
- **Ollama support** — `PROVIDER=ollama` with configurable `OLLAMA_API_BASE`.

## 0.6.0 (2026-04-12)

"What should I do?" — model + configuration recommendation.

### Features

- **`Step.recommend`** — `ClassifyTicket.recommend("eval", candidates: [...], min_score: 0.95)` runs eval on all candidates and returns a `Recommendation` with optimal model, retry chain, rationale, savings vs current config, and `to_dsl` code output.
- **Candidates as configurations** — `candidates:` accepts `{ model:, reasoning_effort: }` hashes, not just model name strings. `gpt-5-mini` with `reasoning_effort: "low"` is a different candidate than with `"high"`.
- **`compare_models` extended** — new `candidates:` parameter alongside existing `models:` (backward compatible). Candidate labels include reasoning effort in output table.
- **Per-attempt `reasoning_effort` in retry policies** — `escalate` accepts config hashes: `escalate({ model: "gpt-4.1-nano" }, { model: "gpt-5-mini", reasoning_effort: "high" })`. Each attempt gets its own reasoning_effort forwarded to the provider.
- **`pass_rate_ratio`** — numeric float (0.0–1.0) on `Report` and `ReportStats`, complementing the string `pass_rate` (`"3/5"`).
- **History entries enriched** — `save_history!` accepts `reasoning_effort:` and stores `model`, `reasoning_effort`, `pass_rate_ratio` in JSONL entries.

### Game changer continuity

```
v0.2: "Which model?"          → compare_models (snapshot)
v0.3: "Did it change?"        → baseline regression (binary)
v0.4: "Show me the trend"     → eval history (time series)
v0.5: "Which prompt is better?" → compare_with (A/B testing)
v0.6: "What should I do?"     → recommend (actionable advice)
```

## 0.5.2 (2026-04-06)

### Features

- **`reasoning_effort` forwarded to provider** — `context: { reasoning_effort: "low" }` now passed through `with_params` to the LLM. Previously accepted as a known context key but silently ignored by the RubyLLM adapter.

## 0.5.0 (2026-03-25)

Data-Driven Prompt Engineering.

### Features

- **`observe` DSL** — soft observations that log but never fail. `observe("scores differ") { |o| o[:a] != o[:b] }`. Results in `result.observations`. Logged via `Contract.logger` when they fail. Runs only when validation passes.
- **`compare_with`** — prompt A/B testing. `StepV2.compare_with(StepV1, eval: "regression", model: "nano")` returns `PromptDiff` with `improvements`, `regressions`, `score_delta`, `safe_to_switch?`. Reuses `BaselineDiff` internally.
- **RSpec `compared_with` chain** — `expect(StepV2).to pass_eval("x").compared_with(StepV1).without_regressions` blocks merge if new prompt regresses any case.

### Game changer continuity

```
v0.2: "Which model?"          → compare_models (snapshot)
v0.3: "Did it change?"        → baseline regression (binary)
v0.4: "Show me the trend"     → eval history (time series)
v0.5: "Which prompt is better?" → compare_with (A/B testing)
```

## 0.4.5 (2026-03-24)

Audit hardening — 18 bugs fixed across 4 audit rounds.

### Fixes

- **RakeTask history before abort** — `track_history` now saves all reports (pass and fail) before gating, so failed runs appear in eval history.
- **RSpec/Minitest stub scoping** — block form `stub_step` uses thread-local overrides with real cleanup. Non-block `stub_all_steps` auto-restored by RSpec `around(:each)` hook and Minitest `setup`/`teardown`.
- **StepAdapterOverride** — handles `context: nil` and respects string key `"adapter"`. Moved to `contract.rb` so both test frameworks share one mechanism.
- **max_cost fail closed output estimate** — preflight uses 1x input tokens as output estimate when `max_output` not set, preventing cost bypass for output-expensive models.
- **reset_configuration! clears overrides** — `step_adapter_overrides` now cleared on reset.
- **CostCalculator.register_model** — validates `Numeric`, `finite?`, non-negative. Rejects NaN, Infinity, strings, nil.
- **Pipeline token_budget** — rejects negative and zero values (parity with `timeout_ms`).
- **track_history model fallback** — uses step DSL `model`, then `default_model` when context has no model. Handles string key `"model"`.
- **estimate_cost / estimate_eval_cost** — falls back to step DSL model when no explicit model arg given.
- **stub_steps string keys** — both RSpec and Minitest normalize string-keyed options with `transform_keys(:to_sym)`.
- **DSL `:default` reset** — `model(:default)`, `temperature(:default)`, `max_cost(:default)` reset inherited parent values.

## 0.4.4 (2026-03-24)

- **`stub_steps` (plural)** — stub multiple steps with different responses in one block. No nesting needed. Works in RSpec and Minitest:
  ```ruby
  stub_steps(
    ClassifyTicket => { response: { priority: "high" } },
    RouteToTeam => { response: { team: "billing" } }
  ) { TicketPipeline.run("test") }
  ```

## 0.4.3 (2026-03-24)

Production feedback release.

### Features

- **`stub_step` block form** — `stub_step(Step, response: x) { test }` auto-resets adapter after block. Works in RSpec and Minitest. Eliminates leaked test state.
- **Minitest per-step routing** — `stub_step(StepA, ...)` now actually routes to StepA only (was setting global adapter, ignoring step class).
- **`track_history` in RakeTask** — `t.track_history = true` auto-appends every eval run (pass and fail) to `.eval_history/`. Drift detection without manual `save_history!` calls.
- **`max_cost` fail closed** — unknown model pricing now refuses the call instead of silently skipping. Set `on_unknown_pricing: :warn` for old behavior.
- **`CostCalculator.register_model`** — register pricing for custom/fine-tuned models: `register_model("ft:gpt-4o", input_per_1m: 3.0, output_per_1m: 6.0)`.

## 0.4.2 (2026-03-24)

- **RakeTask lazy context** — `t.context` now accepts a Proc, resolved at task runtime (after `:environment`). Fixes adapter not being available at Rake load time in Rails apps.

## 0.4.1 (2026-03-24)

- **RakeTask `:environment` fix** — uses `defined?(::Rails)` instead of `Rake::Task.task_defined?(:environment)`. Works in Rails 8 without manual `Rake::Task.enhance`.
- **Concurrent eval deterministic** — `clone_for_concurrency` protocol, `ContextHelpers` extracted.
- **README** — added eval history, concurrency, quality tracking examples.

## 0.4.0 (2026-03-24)

Observability & Scale — see what changed, run it fast, debug it easily.

### Features

- **Structured logging** — `Contract.configure { |c| c.logger = Rails.logger }`. Auto-logs model, status, latency, tokens, cost on every `step.run`.
- **Batch eval concurrency** — `run_eval("regression", concurrency: 4)`. Parallel case execution via Concurrent::Future. 4x faster CI for large eval suites.
- **Eval history & trending** — `report.save_history!` appends to JSONL. `report.eval_history` returns `EvalHistory` with `score_trend`, `drift?`, run-by-run scores.
- **Pipeline per-step eval** — `add_case(..., step_expectations: { classify: { priority: "high" } })`. See which step in a pipeline regressed.
- **Minitest support** — `assert_satisfies_contract`, `assert_eval_passes`, `stub_step` for Minitest users. `require "ruby_llm/contract/minitest"`.

### Game changer continuity

```
v0.2: "Which model?"          → compare_models (snapshot)
v0.3: "Did it change?"        → baseline regression (binary)
v0.4: "Show me the trend"     → eval history (time series)
      "Which step changed?"   → pipeline per-step eval
      "Run it fast"           → batch concurrency
```

## 0.3.7 (2026-03-24)

- **Trait missing key = error** — `expected_traits: { title: 0..5 }` on output `{}` now fails instead of silently passing.
- **nil input in dynamic prompts** — `run(nil)` with `prompt { |input| ... }` correctly passes nil to block.
- **Defensive sample pre-validation** — `sample_response` uses the same parser as runtime (handles code fences, BOM, prose around JSON).
- **Baseline diff excludes skipped** — self-compare with skipped cases no longer shows artificial score delta.
- **Zeitwerk eval/ ignore** — `eager_load_contract_dirs!` ignores `eval/` subdirs before eager load.

## 0.3.6 (2026-03-24)

- **Recursive array/object validation** — nested arrays (`array of array of string`) validated recursively. Object items validated even without `:properties` (e.g. `additionalProperties: false`).
- **Deep symbolize in sample pre-validation** — array samples with string keys (`[{"name" => "Alice"}]`) correctly symbolized before schema validation.

## 0.3.5 (2026-03-24)

- **String constraints in SchemaValidator** — `minLength`/`maxLength` enforced for root and nested strings.
- **Array item validation** — scalar items (string, integer) validated against items schema type and constraints.
- **Non-JSON sample_response fails fast** — `sample_response("hello")` with object schema raises ArgumentError at definition time instead of silently passing.
- **`max_tokens` in KNOWN_CONTEXT_KEYS** — no more spurious "Unknown context keys" warning.
- **Duplicate models deduplicated** — `compare_models(models: ["m", "m"])` runs model once.

## 0.3.4 (2026-03-24)

- **SchemaValidator validates non-object roots** — boolean, integer, number, array root schemas now enforce type, min/max, enum, minItems/maxItems. Previously only object schemas were validated.
- **Removed passing cases = regression** — `regressed?` returns true when baseline had passing cases that are now missing. Prevents gate bypass by deleting eval cases.
- **JSON string sample_response fixed** — `sample_response('{"name":"Alice"}')` correctly parsed for pre-validation instead of double-encoding.
- **`context[:max_tokens]` forwarded** — overrides step's `max_output` for adapter call AND budget precheck.

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
