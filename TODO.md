# TODO — Post-0.9.0 Code Quality Refactor

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

### B2-T4: `Runner.new` 17 kwargs → `RunnerConfig` factory

- [ ] Add test w `spec/ruby_llm/contract/step/runner_spec.rb`:
      "`Runner.new(bogus_kwarg: 1)` raises ArgumentError"
      (rescue w `base.rb:261` obecnie tłumi taki błąd na `:input_error`)
- [ ] Refactor: `RunnerConfig` built in factory method (np.
      `Base.build_runner_config(context)`)
- [ ] `Runner#initialize(config)` zamiast 17 kwargs
- [ ] `run_once(input, config:)` zamiast 11 kwargs

---

## Batch 3 — DSL surgery (#1 + #4 razem — ten sam plik)

⚠️ **MUSZĄ iść w jednym commicie/PR.** Split = half-refactored `dsl.rb` z mieszanką
patternów. Diff staje się nieczytelny.

### B3-T1: Characterization tests dla DSL inheritance

- [ ] Stwórz `spec/ruby_llm/contract/step/dsl_inheritance_spec.rb` z 3 testami:
  1. 3-level chain: grandparent.model = "x", parent nic, child nic → child.model == "x"
  2. `model(nil)` explicit vs `:default` — różne semantyki (nil vs unset)
  3. Falsy edge case: `temperature 0` → child.temperature == 0 (nie `nil`)

### B3-T2: Extract `inherited_attr` / `inherited_resettable_attr` macros

- [ ] Wprowadź macros prywatnie na górze `step/dsl.rb`
- [ ] Refactor każdy attribute (model, temperature, max_input, max_output,
      max_cost, on_unknown_pricing, thinking, attachment_token_estimate,
      on_unknown_attachment_size, around_call, observe, validate)
- [ ] Jeden commit per attribute (atomowość)

### B3-T3: Replace `_explicitly_unset` shadow vars z sentinel `UNSET`

- [ ] Frozen sentinel object jako stała w `Dsl` module
- [ ] Reader returns `nil` (nie `UNSET`) gdy zresetowane
- [ ] Usuń wszystkie 21 wystąpień `@foo_explicitly_unset`

---

## Batch 4 — RakeTask god method extraction

### B4-T1: Characterization tests dla gate logic

- [ ] Stwórz `spec/ruby_llm/contract/rake_task_gate_spec.rb` z 4 testami:
  1. Gate passes when all reports pass → abort NOT called
  2. Gate fails on score threshold → abort called z "FAILED" message
  3. `suite_cost > maximum_cost` → abort z cost message BEFORE score gate
  4. Baselines saved tylko gdy gate_passed (nie gdy report fails)

### B4-T2: Extract `SuiteGate` value object

- [ ] Stwórz `lib/ruby_llm/contract/rake_task/suite_gate.rb`
- [ ] Otrzymuje results array, zwraca `{passed:, reason:}`
- [ ] `define_task` redukuje się do ~10 linii: run evals → build results → delegate

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
