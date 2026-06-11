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

### Both together (Tribunal in CI → then Contract in prod)

```
CI (before merge):
  define_eval(frozen dataset) ──► run Step ──► [Tribunal grades each case]
                                                       │
                                                       ▼
                                                regression gate
                                           (prevents quality drift over time)
                                                       │
                                                       ▼
                                              ✅ merge allowed
                                                       │
                                                       ▼
PROD (every request):
  your code ──► Step.run ──► LLM ──► [contract] ──► output ──► your code
                                         ▲
                                         │ keeps bad outputs out of prod
```

Tribunal grades **a fixed set of cases on every PR** to catch quality regressions before merge. Once merged, Contract gates **every production call** to keep bad outputs from reaching users. Each gem owns the layer it is best at — and they run in the order developers experience them.

## When to use which

**Just Contract.** You ship LLM features whose output drives downstream code, money, or user trust. You need the bad-output-doesn't-reach-prod guarantee, retry escalation, and budget refusal. You are happy to write your own `validate` blocks for content checks; you don't need a 10-judge catalog yet.

**Just Tribunal.** You have a stable production path you don't want to wrap, but you want a CI safety net that grades LLM output for faithfulness, hallucination, PII, jailbreak resistance, etc. You're testing a RAG pipeline or chatbot whose runtime is owned by other code.

**Both.** You ship contracts in prod (Contract) AND want stronger CI signal beyond schema regression — judge-quality grading on a frozen dataset, plus adversarial red-team probes. Use Contract's `Step` to make the call, run it in `define_eval` over your dataset, and grade each case with Tribunal helpers in your spec or via the dataset's `evaluator:` proc.

### Tribunal's catalog vs Contract's `llm_judge.md` — concrete decision tree

If you specifically need an **LLM-as-judge** (a second LLM grading the first one's output), the decision is:

- **Reach for Tribunal's catalog** when your check is one of the well-defined, domain-general categories Tribunal ships: *"is this faithful to the retrieved context?"*, *"is this a refusal?"*, *"does this contain PII?"*, *"is this jailbreak-resistant?"*, *"hallucinated?"*, *"toxic?"*, *"biased?"*. One line in a spec, default threshold, no judge code to write or maintain. The judge prompt is baked into the gem.
- **Build a custom judge per [`llm_judge.md`](llm_judge.md)** when:
  - **Your criterion is domain-specific** — *"does this medical advice match our internal safety policy?"*, *"is this reply in our brand voice?"*, *"does this summary preserve the legal disclaimer verbatim?"*. No off-the-shelf judge knows your policy; you write the prompt.
  - **You need the verdict inside a `define_eval` regression gate** (the `evaluator:` lambda pattern) — Tribunal's surface is spec-time assertions, not eval-framework evaluators.
  - **You need a per-claim breakdown** (sentence-level *"this claim → unsupported, that claim → contradicted"* output) for PR debugging — Tribunal returns one score per assertion.
  - **You need to iterate the judge prompt** because it over-flags on your data — Tribunal's prompts are fixed per assertion.
- **Use both** for the same project even when your check is in Tribunal's catalog: Tribunal's `assert_faithful` for spec-time grade on individual responses, plus a calibrated custom judge wired as `evaluator:` in a regression `define_eval` over a frozen dataset for CI merge-gating. They cover different lifecycle stages.

Either way, the **methodology** in [`llm_judge.md`](llm_judge.md) — calibrate the judge against human-labeled production samples before trusting any score, watch for the six anti-patterns, refine the prompt when it over-flags — applies equally to Tribunal's built-ins, Tribunal's custom registered judges, and Contract `Step::Base` judges. Tribunal's `default_threshold = 0.8` is a starting point, not a calibrated bar for your data.

## What Tribunal documents — and what it doesn't

Tribunal's README ships an **implementation catalog** (`assert_faithful`, `assert_hallucination`, `assert_refusal`, `assert_no_pii`, `assert_no_toxicity`, `assert_no_bias`, `assert_jailbreak_resistant`, etc., plus a `register_judge` API for custom ones). What it currently leaves to the adopter:

| Tribunal ships | Tribunal's README doesn't document (Contract's [`llm_judge.md`](llm_judge.md) does) |
|---|---|
| `default_threshold = 0.8` (fixed) | How to **calibrate** the threshold against your human-labeled production data |
| Judge prompt baked in per assertion | How to **iterate the judge prompt** when it over-flags stylistic courtesy as drift |
| Single score per assertion | **Per-claim breakdown** schema for sentence-level PR debugging |
| `assert_faithful` in a spec | **Judge as `evaluator:` lambda** in a Contract `define_eval` regression gate |
| Custom Judge mechanism (`register_judge`) | **Anti-patterns** (stubbing the verdict, calibrating on synthetic data, calibrating once and shipping) |

This is a **complementary gap**, not a competition. Tribunal owns the implementation catalog; Contract's `llm_judge.md` owns the methodology. A typical production setup uses both layers: pick (or build) the implementation, then calibrate it against your humans **before** trusting any score.

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
    evaluator: ->(output) {
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
