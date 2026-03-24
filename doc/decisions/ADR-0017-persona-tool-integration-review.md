---
id: ADR-0017
decision_type: adr
status: Proposed
created: 2026-03-24
summary: "PersonaTool integration review — eval gaps, test migration, validation hardening"
owners:
  - justi
---

# ADR-0017: PersonaTool Integration Review

## Context

Full audit of ruby_llm-contract integration in PersonaTool — Rails 8.1, 8 contracts, 499 tests, gem v0.4.5. The gem integration is clean (zero monkey-patches, zero workarounds beyond documented thread propagation). But coverage gaps exist in evals, validators, and test patterns.

## Current state

| Contract | Model | Eval | Baseline | Validators | Max limits |
|----------|-------|------|----------|-----------|------------|
| EvaluateStandard | (context) | yes | yes | schema only | max_output, max_cost |
| EvaluateComparative | (context) | yes | yes | schema only | max_output, max_cost |
| GeneratePersonaBatch | gpt-5-nano | yes | yes | 1 (personas not empty) | max_output, max_cost |
| ExpandSeedList | gpt-5-nano | yes | yes | schema only | max_output, max_cost |
| GenerateGateQuestions | gpt-4o-mini | **no** | **no** | schema only | max_input, max_output |
| AnalyzeTestRun | gpt-5.2 | **no** | **no** | 1 (5 MD sections) | max_input, max_output |
| DistillPersonaConfig | gpt-4o-mini | **no** | **no** | schema only | max_output, max_cost |
| AnalyzeContrastivePatterns | gpt-4o-mini | **no** | **no** | schema only | max_output, max_cost |

**Eval coverage: 4/8 (50%).** The 4 without evals have no regression safety net.

**Test patterns: mixed.** Three different stubbing approaches coexist:
- `stub_steps` (gem, recommended) — 4 test files
- `.stub(:run)` (Ruby stdlib) — PersonaGenerator tests, for capturing inputs
- `with_test_adapter` (legacy custom helper) — 5 uses in gate_question_generation_test

## Issue 1: Missing evals (HIGH)

### Problem

4 contracts have no eval, no baseline. A model update or prompt change could silently break them. AnalyzeTestRun is highest risk — complex 5-section markdown output, fragile regex validator, $0.01+ per call.

### Plan

Add offline evals (sample_response, zero API calls) for all 4:

**GenerateGateQuestions:**
```ruby
GenerateGateQuestions.define_eval("smoke") do
  default_input { url: "https://example.com/product", page_content: "Buy now..." }
  sample_response({
    language: "en",
    gate_questions: [{ cta: "Buy now", question: "Would you buy this today?" }]
  })
end
```
Validates: language is ISO code, gate_questions is non-empty array, each has cta + question.

**AnalyzeTestRun:**
```ruby
AnalyzeTestRun.define_eval("smoke") do
  default_input "## Test results\n10 personas evaluated..."
  sample_response("## Sentiment Patterns\n...\n## Barriers\n...\n## Conversion\n...\n## Key Insights\n...\n## Recommendations\n...")
end
```
Validates: 5 markdown sections present, each non-empty.

**DistillPersonaConfig:**
```ruby
DistillPersonaConfig.define_eval("smoke") do
  default_input { personas: [...], field: "skills" }
  sample_response({ values: ["Ruby", "Python"], weights: [0.6, 0.4] })
end
```
Validates: values array non-empty, weights sum to ~1.0.

**AnalyzeContrastivePatterns:**
```ruby
AnalyzeContrastivePatterns.define_eval("smoke") do
  default_input { yes_evaluations: [...], no_evaluations: [...] }
  sample_response({
    archetype: "Early adopter",
    yes_patterns: ["price-sensitive"],
    no_patterns: ["risk-averse"],
    generation_config: { skills: { values: ["Ruby"], weights: [1.0] } }
  })
end
```
Validates: archetype present, patterns non-empty, generation_config has expected structure.

### Effort

~2h for all 4 evals + baselines. Zero API calls needed (offline mode).

## Issue 2: Migrate legacy test helper (MEDIUM)

### Problem

`with_test_adapter` sets a global adapter for all contracts — no per-contract control. 5 uses remain in gate_question_generation_test despite comment "prefer stub_step". Mixed patterns make test suite harder to read.

### Plan

Replace all `with_test_adapter` calls with `stub_step` block form:

```ruby
# Before
with_test_adapter(gate_question_response) do
  result = GenerateGateQuestions.run(input)
end

# After
stub_step(GenerateGateQuestions, response: gate_question_response) do
  result = GenerateGateQuestions.run(input)
end
```

Then remove `with_test_adapter` from test_helper.rb.

### Effort

~30min. 5 call sites, mechanical replacement.

## Issue 3: Add validators to bare contracts (MEDIUM)

### Problem

6/8 contracts rely entirely on output_schema — no semantic validation. Schema catches type errors but not logic errors (e.g. gate question in wrong language, empty patterns array, weights that don't sum to 1.0).

### Plan

Add `validate` blocks where schema alone is insufficient:

**GenerateGateQuestions:**
```ruby
validate("language matches page content") { |o, input|
  # language field should match detected language from page_content
  o[:language].is_a?(String) && o[:language].length == 2
}
validate("gate questions non-empty") { |o|
  o[:gate_questions].is_a?(Array) && !o[:gate_questions].empty?
}
```

**EvaluateStandard:**
```ruby
validate("gate_answer is yes or no") { |o| %w[yes no].include?(o[:gate_answer]&.downcase) }
validate("pain_level in range") { |o| (1..5).include?(o[:pain_level]) }
```

**EvaluateComparative:**
```ruby
validate("scores in range") { |o| (1..10).include?(o[:score_a]) && (1..10).include?(o[:score_b]) }
```

**ExpandSeedList:**
```ruby
validate("responses non-empty") { |o| o[:responses].is_a?(Array) && !o[:responses].empty? }
```

**DistillPersonaConfig:**
```ruby
validate("weights sum to ~1.0") { |o|
  o[:weights].is_a?(Array) && (o[:weights].sum - 1.0).abs < 0.1
}
```

**AnalyzeContrastivePatterns:**
```ruby
validate("has archetype") { |o| o[:archetype].is_a?(String) && !o[:archetype].empty? }
```

### Effort

~1h. Small additions to existing contract files.

## Issue 4: Add max_input to remaining contracts (LOW)

### Problem

6/8 contracts have no `max_input`. Unbounded input → unpredictable cost. AnalyzeTestRun has max_input 30,000 but ReportGenerator doesn't validate input length before calling it.

### Plan

Add `max_input` based on actual usage patterns:

| Contract | Proposed max_input | Rationale |
|----------|-------------------|-----------|
| EvaluateStandard | 2000 | Single persona + product description |
| EvaluateComparative | 3000 | Two propositions + persona |
| GeneratePersonaBatch | 2000 | Seed list + instructions |
| ExpandSeedList | 1000 | Short seed values |
| DistillPersonaConfig | 4000 | Top personas summary |
| AnalyzeContrastivePatterns | 4000 | Yes/no evaluation sets |

### Effort

~15min. One-liner per contract.

## Issue 5: Document .stub(:run) pattern (LOW)

### Problem

PersonaGenerator tests use `.stub(:run)` (Ruby stdlib) to capture inputs passed to contracts. This is a valid pattern — `stub_step` doesn't support input capture. But it's undocumented as a recommended approach.

### Plan

Add note to testing.md guide: "Use `.stub(:run)` when you need to capture inputs for assertions. Use `stub_step`/`stub_steps` when you only need to control the response."

### Effort

~10min. Documentation only.

## Implementation order

| Phase | Issue | Effort | Impact |
|-------|-------|--------|--------|
| 1 | Issue 1: Add 4 missing evals | ~2h | HIGH — regression safety for all contracts |
| 2 | Issue 3: Add validators | ~1h | MEDIUM — catches logic errors at runtime |
| 3 | Issue 2: Migrate with_test_adapter | ~30min | MEDIUM — consistent test patterns |
| 4 | Issue 4: Add max_input | ~15min | LOW — cost protection |
| 5 | Issue 5: Document .stub pattern | ~10min | LOW — team knowledge |

## Success criteria

1. All 8 contracts have at least one eval with committed baseline
2. `bundle exec rake contracts:eval` passes with 100% score
3. Zero uses of `with_test_adapter` in test suite
4. All contracts have at least one `validate` beyond schema
5. All contracts have `max_input` set
