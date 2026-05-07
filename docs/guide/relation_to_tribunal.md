# Relation to `ruby_llm-tribunal`

> Read this when you've seen [`ruby_llm-tribunal`](https://github.com/Alqemist-labs/ruby_llm-tribunal) and want to know how it relates to `ruby_llm-contract` — and which one (or both) you need.

Both gems sit on top of `ruby_llm`. The space they cover overlaps in vocabulary (both talk about "evals") but they live in different layers and answer different questions. They are not alternatives — they compose.

## The core distinction

| | `ruby_llm-tribunal` | `ruby_llm-contract` |
|---|---|---|
| Layer | **Test framework** | **Runtime contract** |
| When it runs | After the LLM call returns, typically in a spec | Before the LLM result reaches your code |
| Where the output lives at evaluation time | Already in your variable, returned to caller | Still inside the gem's runner, not yet released |
| What "fail" means | Red test in CI | Trigger retry/escalate on a stronger model, or fail closed |
| Strongest features | Rich LLM-as-judge (faithful, relevant, hallucination, refusal, bias, toxicity, jailbreak, PII), red-team adversarial prompts, deterministic helpers (`assert_contains`, `assert_levenshtein`, …), RSpec/Minitest matchers, HTML/JUnit/GH reporters | Schema DSL with constraints, `validate` business rules, `retry_policy escalate(...)` model escalation, `max_cost` pre-flight refusal, regression-eval framework (frozen dataset + baseline + min_score gate), pipeline composition |
| What it does NOT cover | No retry, no model escalation, no pre-flight cost cap, no contract layer between LLM and your code | No 10-judge LLM-as-judge catalog, no red-team generation, no rich deterministic assertion library, no test-framework matchers |

## Visual: where each gem sits in your call

### Tribunal alone (test-time, in CI)

```
your code ──► LLM ──► output ──► variable ──► [Tribunal assert_*] ──► ✅ / ❌ red test
                                                       ▲
                                              runs in your spec, not in prod
```

The output **already exists in your code** by the time Tribunal sees it. Tribunal grades it after the fact. A failed grade is a red test — production is unaffected, you fix the prompt or model and re-run.

### Contract alone (runtime, in prod)

```
your code ──► Step.run ──► LLM ──► [schema + validate]
                                          │
                                          ├── valid ────────────► output ──► your code
                                          │
                                          └── invalid ──► retry/escalate ──► next model
                                                                                 │
                                                              all attempts fail ─┘
                                                                                 ▼
                                                                  Result(:validation_error)
```

The output **never reaches your code** until the contract passes. A failed validation either fixes itself (the retry policy escalates to a stronger model) or fails closed with `Result(:validation_error)` — your call site sees a deterministic failure status, never schema-invalid data.

### Both together (Contract in prod + Tribunal in CI)

```
PROD:  your code ──► Step.run ──► LLM ──► [contract] ──► output ──► your code
                                              ▲
                                              │ keeps bad outputs out of prod

CI:    define_eval(frozen dataset) ──► run Step ──► [Tribunal grades each case]
                                                          │
                                                          ▼
                                                   regression gate
                                              (prevents quality drift over time)
```

Contract gates **every production call**. Tribunal grades **a fixed set of cases periodically** to catch silent quality regressions on prompt/model changes. Each gem owns the layer it is best at.

## When to use which

**Just Contract.** You ship LLM features whose output drives downstream code, money, or user trust. You need the bad-output-doesn't-reach-prod guarantee, retry escalation, and budget refusal. You are happy to write your own `validate` blocks for content checks; you don't need a 10-judge catalog yet.

**Just Tribunal.** You have a stable production path you don't want to wrap, but you want a CI safety net that grades LLM output for faithfulness, hallucination, PII, jailbreak resistance, etc. You're testing a RAG pipeline or chatbot whose runtime is owned by other code.

**Both.** You ship contracts in prod (Contract) AND want stronger CI signal beyond schema regression — judge-quality grading on a frozen dataset, plus adversarial red-team probes. Use Contract's `Step` to make the call, run it in `define_eval` over your dataset, and grade each case with Tribunal helpers in your spec or via the dataset's `evaluator:` proc.

## Integration patterns

These work today without any code changes in either gem — both use plain Ruby blocks/procs as extension points.

### Tribunal helpers inside Contract `validate`

```ruby
class ChatReply < RubyLLM::Contract::Step::Base
  prompt "Answer this question grounded in the docs:\n{input}"

  validate("no PII in answer") do |output, _ctx|
    test_case = RubyLLM::Tribunal::TestCase.new(actual_output: output[:answer])
    RubyLLM::Tribunal::Assertions.evaluate(:pii, test_case, {}).first == :pass
  end
end
```

A failed Tribunal grade triggers Contract's retry/escalate just like any other validation failure. You get LLM-as-judge **runtime gating**, not just CI testing.

### Tribunal as `evaluator:` in a Contract dataset

```ruby
ChatReply.define_eval "rag_regression" do
  add_case "policy",
    input: "What is the return policy?",
    evaluator: ->(output, _expected, _input) {
      tc = RubyLLM::Tribunal::TestCase.new(
        actual_output: output[:answer],
        context: ["Returns accepted within 30 days with receipt."]
      )
      result = RubyLLM::Tribunal::Assertions.evaluate(:faithful, tc, {})
      score = result.last[:score] || 0.0
      RubyLLM::Contract::Eval::EvaluationResult.new(score: score, passed: result.first == :pass)
    }
end
```

Each case is graded by a Tribunal judge; baseline + min_score gate then fails the build on regression. You write the judge once, get the regression gate for free.

### Contract `Step` as Tribunal's `opts[:llm]` injection

Tribunal's built-in judges call `RubyLLM.chat(...).ask(...)` and naively `JSON.parse` the result. If you want **schema-validated, retried, cost-capped judge calls**, inject a Contract `Step` as the LLM caller via `opts[:llm]`. This is an advanced pattern; sketch it from `Tribunal::Assertions::Judge#run_judge`'s injection point and your own judge wrapping a `Step.run`.

This is a recipe, not a shipped adapter. Tribunal's `opts[:llm]` API is at v0.x — recipes survive minor changes; a shipped adapter would not.

## What we are NOT doing

- **No `Contract::ContainsAssertion` or similar 16-helper deterministic library.** Tribunal owns that layer well. Contract's evaluator surface is intentionally minimal (`Exact`, `Regex`, `JsonIncludes`, `ProcEvaluator`, `TraitEvaluator`); for richer deterministic checks, drop a Tribunal helper into your `evaluator:` proc.
- **No built-in LLM-as-judge catalog.** `Faithful`, `Hallucination`, `Refusal`, etc. are Tribunal's domain. We provide the runtime contract; they provide the grading vocabulary.
- **No Tribunal as a hard or soft dependency.** Both gems work standalone. Recipes above are documentation, not code in this gem.

## Summary

Three questions, three owners:

- **"Is this output good?"** — Tribunal, in CI, on outputs you already hold.
- **"What do we do when it isn't?"** — Contract, at runtime, before outputs reach your code (retry/escalate, or fail-closed with `Result(:validation_failed)`).
- **"What do we do when it _is_ good?"** — your application code. Once Contract returns `:ok`, you persist, render, hand off downstream. The gem deliberately doesn't touch the happy path; it owns failure semantics, not domain logic.

Use Tribunal, Contract, or both — whichever questions your application needs to answer.
