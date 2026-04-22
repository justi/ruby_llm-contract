# Find the cheapest viable fallback list

You defined `SummarizeArticle` in the [README](../../README.md) with `retry_policy models: %w[gpt-4.1-nano gpt-4.1-mini gpt-4.1]`. That list was a guess. `optimize_retry_policy` tells you which models your evals actually need, so you stop paying for the strong model when `nano` was enough — or stop shipping `nano` when the hardest eval proves it isn't.

## Requirements

- **`SummarizeArticle` already has `retry_policy`.** If your step has none, add one first ([getting started](getting_started.md)).
- **2–3 evals per step.** One eval optimizes for one scenario; with only `smoke`, you get a recommendation that passes smoke but may miss production edge cases. See [eval-first](eval_first.md).
- **Rake tasks.** The standard `RubyLLM::Contract::RakeTask` includes `ruby_llm_contract:optimize`. Non-Rails projects: set `EVAL_DIRS=...`.

For this guide, assume `SummarizeArticle` has three evals:

```ruby
SummarizeArticle.define_eval("smoke")          { ... }  # short news article
SummarizeArticle.define_eval("dense_article")  { ... }  # long form, 5 takeaways required
SummarizeArticle.define_eval("critical_tone")  { ... }  # negative review, tone must match
```

## Offline check first

Run once offline to verify the wiring:

```bash
rake ruby_llm_contract:optimize \
  STEP=SummarizeArticle \
  CANDIDATES=gpt-4.1-nano,gpt-4.1-mini@low,gpt-4.1-mini,gpt-4.1
```

Offline uses each eval's `sample_response` — zero API calls. **Every candidate gets the same score** because they all receive the canned response. That's fine for a smoke test (verifying evals load, candidates parse, output renders) but it doesn't compare model quality. For real optimization, go live.

## Optimize against real models

```bash
LIVE=1 RUNS=3 rake ruby_llm_contract:optimize \
  STEP=SummarizeArticle \
  CANDIDATES=gpt-4.1-nano,gpt-4.1-mini@low,gpt-4.1-mini,gpt-4.1
```

`LIVE=1` makes real API calls. `RUNS=3` averages each `(candidate, eval)` pair over three runs — necessary because OpenAI forces `temperature=1.0` on gpt-5 / o-series and the same pair can score `0.00` on one run and `1.00` on the next.

Output (illustrative):

```
SummarizeArticle — retry chain optimization

  eval             4.1-nano  4.1-mini@low  4.1-mini   4.1
  ---------------------------------------------------------
  smoke                1.00          1.00      1.00  1.00
  dense_article        0.67 ←        1.00      1.00  1.00
  critical_tone        0.50 ←        0.67 ←    1.00  1.00

  Hardest eval: critical_tone

  Suggested fallback list:
    gpt-4.1-nano         — covers 1 eval(s)
    gpt-4.1-mini         — passes all 3 evals

  DSL:
    retry_policy models: %w[gpt-4.1-nano gpt-4.1-mini]
```

Reading the table:
- **`←` marks scores below threshold in the hardest eval.** Not a selection hint — just "this candidate fails the constraining row".
- **Hardest eval** = the one that forces the strong fallback. Here, `critical_tone` demands `gpt-4.1-mini`.
- **Suggested fallback list** = the shortest chain where each step covers more evals, built greedy-cheapest-first. Stops when all evals pass. Order matters: `gpt-4.1-nano` is tried first; on validation failure, the gem falls back to `gpt-4.1-mini`.

Copy the DSL, paste into your step, verify with `rake ruby_llm_contract:eval`. You just dropped `gpt-4.1` from the chain — most requests finish on nano, mini handles what nano misses, and the strong model was never needed.

## Measure effective cost before shipping

`optimize` shows **first-attempt** cost. In production, a candidate whose validator rejects 20% of outputs actually costs `first_try_cost + fallback_cost × 0.20` per successful output. The first-attempt number hides this.

`production_mode: { fallback: "..." }` runs each candidate with a runtime `[candidate, fallback]` chain and reports effective cost:

```ruby
SummarizeArticle.compare_models(
  "dense_article",
  candidates: [{ model: "gpt-4.1-nano" }, { model: "gpt-4.1-mini", reasoning_effort: "low" }],
  production_mode: { fallback: "gpt-4.1-mini" }
).print_summary
```

Output (live mode, illustrative):

```
dense_article — model comparison

  Chain                                      first-attempt  fallback %  effective cost  latency   score
  -----------------------------------------------------------------------------------------------------
  gpt-4.1-nano → gpt-4.1-mini                $0.0010        33%         $0.0018         164ms     1.00
  gpt-4.1-mini (effort: low) → gpt-4.1-mini  $0.0015         5%         $0.0016         210ms     1.00
  gpt-4.1-mini                               $0.0030         —          $0.0030         220ms     1.00
```

- **first-attempt** — cost of the first run alone.
- **fallback %** — fraction of cases where the validator rejected and the fallback ran.
- **effective cost** — total per successful output including retries.
- **`—`** — candidate equals fallback, no chain to observe.

Run this before finalizing: a candidate saving 3× on first-attempt but escalating 60% of the time may save only 1.2× in production.

**Scope.** Single-fallback (2-tier) chains only. Multi-tier inspect via `trace.attempts`. Step-level — calling on `Pipeline::Base` raises `ArgumentError`.

## When results look wrong

- **"No viable chain" from a single live run.** Re-run with `RUNS=3`. If scores jump, the first run was noise. Never trust single-run results with gpt-5 / o-series in the pool — `temperature=1.0` is server-enforced.
- **Every candidate fails the same eval**, including the strongest. The eval is rejecting correct answers. Run the step directly (`context: { retry_policy_override: nil, model: "gpt-4.1" }`), inspect the output, compare with the `verify` block. Loosen the eval if the output is correct but not one of the accepted values.
- **Testing one specific hypothesis.** (e.g. "does `mini@medium` help on `critical_tone`?") Use `SummarizeArticle.compare_models("critical_tone", candidates: [{ model: "gpt-4.1-mini", reasoning_effort: "medium" }], runs: 3)` directly — three calls instead of rerunning the whole optimize pass.

## Programmatic API names

Metrics exposed on `Report` / `AggregatedReport` keep their original names: `single_shot_cost`, `single_shot_latency_ms`, `escalation_rate`. The optimize Result struct also exposes `hardest_eval` as an alias for `constraining_eval`.
