# TODO — Post-0.9.0 Code Quality Refactor ✅ COMPLETE

**Status: ALL 8 Codex findings addressed.** Sum across batches: 1369 tests / 0 failures. Ready for 0.10.0 release.

---



Plan oparty na audycie Codex'a (8 high-priority findings) + safety map
(`characterization-first` — żaden refactor bez testów charakteryzujących bieżące
zachowanie).

Sekwencja batch'ami. Każdy batch = osobny commit/branch, nie blokujący adopterów.
`main` zostaje shippable po każdym batchu.

---

## Batch 1 — dead code + minor risk ✅ DONE

| # | Ticket | Effort | Status |
|---|--------|--------|--------|
| B1-T1 | Drop `ObjectSpace.each_object` fallback w `concerns/eval_host.rb:194-203` | XS | [x] |
| B1-T2 | New `spec/ruby_llm/contract/concerns/eval_host_spec.rb` (3 tests pinning `register_subclasses`) | XS | [x] |

Verdict: shipped. Suite: 1336 / 0 failures.

---

## Batch 2 — characterization tests, potem refactor (5 ticketów)

### B2-T1: `with_retry_disabled` (GAP coverage — NAJWYŻSZE ryzyko) ✅ DONE

- [x] Added 4 characterization tests pinning original behaviour
- [x] Refactored: `context.merge(retry_policy_override: nil)` instead of singleton mutation
- [x] Replaced characterization tests with 3 new tests pinning context-propagation contract + ensured `with_retry_disabled` private method is dropped

### B2-T2: `stub_step` unification (CHARACTERIZATION coverage) ✅ DONE

- [x] Added pair of sequential tests pinning auto-cleanup contract
- [x] Unified non-block form on thread-local path (dropped `allow`/`receive` branch)
- [x] No extra hook needed — existing `around(:each)` in `rspec.rb:14-28` already restores `step_adapter_overrides` between examples

### B2-T3: `CostCalculator.send(:find_model)` → public expose ✅ DONE

- [x] Added 5 characterization tests pinning `find_model` contract
- [x] Removed `find_model` from `private_class_method`
- [x] Replaced both `CostCalculator.send(:find_model)` calls
- [x] Bonus: dropped `estimated_cost_for` helper, routed through public `CostCalculator.calculate` (removes second `send(:compute_cost)`)

### B2-T4: `Runner.new` 17 kwargs → `RunnerConfig` factory ✅ DONE

- [x] Added `RunnerConfig.build(...)` factory class method (single home for defaults; was duplicated in `Runner#initialize`)
- [x] `Runner#initialize(config: nil, **kwargs)` — value-object form preferred, legacy kwargs forwarded to `RunnerConfig.build` (backward-compat)
- [x] `Step::Base#run_once` extracts `build_runner_config(...)` helper, calls `Runner.new(config: ...)`
- [x] Added 2 specs pinning new construction path + unknown-kwarg rejection
- Net effect: kwarg-set defaults in one place; existing 8 runner_specs (legacy kwargs) keep working unchanged

---

## Batch 3 — DSL surgery (#1 + #4 razem — ten sam plik) ✅ DONE

- [x] B3-T1: 16 characterization tests w `spec/ruby_llm/contract/step/dsl_inheritance_spec.rb`
- [x] B3-T2: Extracted `inherited_value(name)` + `inherited_value_with_reset(name)` helpers w `step/dsl.rb`
- [x] B3-T3: Frozen `UNSET` sentinel object replaces all 5 `_explicitly_unset` shadow ivars

Refactor stats: dsl.rb -71 / +52 LOC net (-19). All 5 resettable attributes (`model`, `temperature`, `max_cost`, `attachment_token_estimate`, `thinking`) collapsed to use `UNSET` sentinel. Bonus: 4 simple-inheritance attributes (`max_input`, `max_output`, `on_unknown_pricing`, `on_unknown_attachment_size`) also routed through `inherited_value` for DRY. Suite: 1362 / 0 failures.

---

## Batch 4 — RakeTask god method extraction ✅ DONE

- [x] B4-T1: 5 characterization tests w `spec/ruby_llm/contract/rake_task_gate_spec.rb` covering all 4 gate dimensions (pass / score-fail / cost-priority / baseline-conditional)
- [x] B4-T2: Extracted `RakeTask::SuiteGate` value object in `lib/ruby_llm/contract/rake_task/suite_gate.rb` (~100 LOC, testable in isolation, returns `Verdict` Data struct with `passed?`, `abort_reason`, `passed_reports`, `suite_cost`)
- [x] `RakeTask#define_task` reduced from ~52 LOC god method to ~25 LOC + extracted `collect_host_reports` helper. Gate logic, regression detection, cost comparison — all delegated.
- Suite: 1369 / 0 failures.

---

## Out-of-scope (zdefer'owane do post-1.0)

- `add_history` multi-turn replay z attachment (ADR-0023 gdy adopter zażąda)
- Streaming + attachment (niche)
- Provider-specific size caps reference w `multimodal_input.md`

---

## Workflow regulamin

1. **One batch = one PR/branch.** `main` zostaje shippable po każdym batchu.
2. **Test-first WSZĘDZIE.** Codex's verdict: 0 z 8 surface'ów ma STRONG coverage.
3. **Suite green po każdym ticketcie.** Run `bundle exec rspec --format progress`.
4. **Wersja bump per batch:** Batch 1 → 0.9.1 (patch). Batch 2 → 0.10.0 (minor).
   Batch 3+4 → 0.11.0 (minor). Po wszystkim 1.0 API freeze ready.
