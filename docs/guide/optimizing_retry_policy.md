# Optimizing retry_policy

How to find the cheapest retry chain that passes all your evals.

## Prerequisites

This guide assumes your app already has:

**1. A Step with `retry_policy`.** This is the escalation chain that runs progressively stronger models when validation fails:

```ruby
class ClassifyThread < RubyLLM::Contract::Step::Base
  output_schema do
    string :classification, enum: %w[PROMO FILLER SKIP]
  end

  validate("PROMO has matched page") { |o| o[:classification] != "PROMO" || o[:matched_page].present? }

  retry_policy models: %w[gpt-5-mini gpt-5-mini gpt-4.1]
end
```

If your step has no `retry_policy`, add one first. See [Getting Started](getting_started.md).

**2. At least 2–3 evals per step.** Each eval is a scenario with input, sample response, and verify checks that assert correctness:

```ruby
ClassifyThread.define_eval("smoke") do
  default_input({ threads: [...], url: "https://example.com" })
  sample_response({ threads: [{ id: "t1", classification: "PROMO" }, ...] })

  verify "relevant thread is PROMO", ->(o) { o[:threads].find { |t| t[:id] == "t1" }[:classification] == "PROMO" }
  verify "spam thread is SKIP",      ->(o) { o[:threads].find { |t| t[:id] == "t2" }[:classification] == "SKIP" }
end
```

**Why 2–3 evals minimum?** One eval tests one scenario. `recommend` optimizes for the eval you give it — if you only have `smoke`, you'll get a recommendation that passes smoke but may fail edge cases in production. The more evals, the safer the recommendation.

See [Eval-First Development](eval_first.md) for how to write evals.

**3. Rake tasks for `recommend` and `compare_models`.** If you use the standard `RakeTask`, these are included. If not, you need a way to run `Step.recommend(eval_name, candidates: [...])` — see the [testing guide](testing.md) for programmatic usage.

## The problem

`recommend` runs on **one eval at a time**. If you optimize for `smoke` alone, you may pick a cheap model that fails harder evals like `topic_mismatch`. The cheapest model per eval varies — the retry chain must satisfy the **constraining eval** (the hardest one).

## One command: `optimize`

```bash
rake ruby_llm_contract:optimize STEP=MyStep CANDIDATES=cheap-model,mid-model@low,mid-model,expensive-model
```

By default this runs **offline** using each eval's `sample_response` (zero API calls). To run against real models:

```bash
# Live mode — makes real API calls:
LIVE=1 rake ruby_llm_contract:optimize STEP=MyStep CANDIDATES=...

# Non-Rails projects — specify where eval files live:
EVAL_DIRS=lib/steps/eval rake ruby_llm_contract:optimize STEP=MyStep CANDIDATES=...
```

This runs `compare_models` on **every eval** for the step, builds the score table, finds the constraining eval, and prints a suggested retry chain with copy-paste DSL:

```
MyStep — retry chain optimization

  eval                 cheap   mid@low   mid    expensive
  -------------------------------------------------------
  smoke                 1.00      1.00   1.00       1.00
  edge_cases            0.67 ←    0.67   1.00       1.00
  locale                1.00      1.00   1.00       1.00

  Constraining eval: edge_cases

  Suggested chain:
    cheap    — passes 2/3 evals
    mid      — passes 3/3 evals

  DSL:
    retry_policy models: %w[cheap mid]
```

Copy the DSL, paste into your step, run `rake ruby_llm_contract:eval` to verify.

## Reducing variance with `runs:`

In **live mode** the LLM is non-deterministic. The same `(candidate, eval)` pair can score `0.00`, `0.50`, or `1.00` across runs even with identical prompts. `optimize` runs each candidate exactly once by default, so one unlucky sample can flip a viable candidate to "failing" and trigger a misleading **"no viable chain"** result.

### Why you can't just lower temperature

OpenAI enforces `temperature=1.0` for the gpt-5 / o-series models server-side (ruby_llm normalizes any other value to 1.0 per provider requirement). You cannot request `temperature: 0.3` to reduce variance. **Averaging over N runs is the only reliable way to get stable eval scores.**

### When to use it

Use `runs: > 1` when:

- You're running **live** (`LIVE=1` / real API calls), AND
- The candidate pool includes a gpt-5 / o-series model, OR
- You've seen inconsistent `optimize` results across re-runs ("it said no viable chain, but a manual re-run passed").

Skip it when:

- Running **offline** with `sample_response` — outputs are deterministic, `runs > 1` wastes cycles with no benefit.
- You only care about a ballpark signal and budget matters more than precision.

### How to use it

```bash
# CLI — optimize with 3 runs per candidate per eval:
LIVE=1 RUNS=3 rake ruby_llm_contract:optimize STEP=MyStep CANDIDATES=gpt-5-nano,gpt-5-mini@low,gpt-5-mini
```

```ruby
# Programmatic:
MyStep.optimize_retry_policy(
  candidates: [{ model: "gpt-5-nano" }, { model: "gpt-5-mini", reasoning_effort: "low" }],
  runs: 3
)

# Or directly on compare_models:
MyStep.compare_models("edge_cases", candidates: [...], runs: 3)
```

### What you pay

Cost scales linearly: `runs: 3` makes 3× the API calls. Start with `runs: 3` — enough signal to separate stable candidates from variance, without breaking the budget on large candidate pools.

### What the report contains

Each candidate's aggregated report exposes:

- `score` — **mean** across runs (used in the table and chain-building)
- `score_min`, `score_max` — spread across runs (inspect for high-variance candidates)
- `total_cost` — **mean total eval cost per run** (sum of all case costs, averaged across runs; divide by case count for an approximate per-call cost)
- `pass_rate` — `"x/N"` where `x` is the count of runs that passed cleanly (every case passing)
- `pass_rate_ratio` — `clean_passes / N` as a float (run-level reliability, consistent with `pass_rate`)
- `clean_passes` — the same `x` as an integer

With `runs: 1` (default), `compare_models` returns a plain `Report` — no wrapping, no behavior change.

## Manual procedure (if you need more control)

### 1. List evals for the step

```ruby
MyStep.eval_names  # => ["smoke", "edge_cases", "locale"]
```

### 2. Run recommend on every eval

```bash
rake ruby_llm_contract:recommend STEP=MyStep EVAL=smoke         CANDIDATES=cheap-model,mid-model@low,mid-model,expensive-model
rake ruby_llm_contract:recommend STEP=MyStep EVAL=edge_cases    CANDIDATES=cheap-model,mid-model@low,mid-model,expensive-model
rake ruby_llm_contract:recommend STEP=MyStep EVAL=locale        CANDIDATES=cheap-model,mid-model@low,mid-model,expensive-model
```

Running on only one eval gives a misleadingly cheap recommendation.

### 3. Build the score table

Collect results into a table. The **constraining eval** is the row that needs the strongest model.

### 4. Build the escalation chain

Read column by column, cheapest first. Each step covers more evals. Stop when all evals pass.

### 5. Verify

```bash
rake ruby_llm_contract:eval
```

## Troubleshooting: "no recommendation"

When `recommend` returns "no recommendation" for all candidates on an eval, the issue is usually the eval, not the models.

**Check the eval's verify blocks.** If every model — including the strongest — scores below threshold, a verify check likely expects an overly strict answer. Common case: an eval expects `SKIP` when `FILLER` is also a correct classification.

**Diagnose:** run the step directly on the eval input, inspect the output, and compare with what verify expects.

**Fix the eval to accept all valid outputs**, then re-run recommend. Do not loosen evals to make cheap models pass — fix evals that reject correct answers.

## Example: real optimization

Before:

```ruby
# Every attempt uses the same mid-tier model
retry_policy models: %w[gpt-5-mini gpt-5-mini gpt-4.1]
```

After running recommend on 6 evals:

```
                        nano   mini@low   mini   4.1
smoke                   0.67   1.00       1.00   1.00
same_locale_page_fit    1.00   1.00       1.00   1.00
hostile_recommendation  1.00   1.00       1.00   1.00
non_promo_same_domain   1.00   1.00       1.00   1.00
locale_mismatch         1.00   1.00       1.00   1.00
topic_mismatch          0.67   0.67       1.00   1.00  ← constraining
```

Result:

```ruby
retry_policy do
  escalate(
    { model: "gpt-5-nano" },                           # $0.001, passes 4/6
    { model: "gpt-5-mini", reasoning_effort: "low" },  # $0.002, passes 5/6
    { model: "gpt-5-mini" }                            # $0.003, passes 6/6
  )
end
```

First attempt 4× cheaper. Worst case 2.7× cheaper. Same eval coverage.

## Production-mode cost measurement

The default `compare_models` / `optimize_retry_policy` output shows **single-shot** cost — what each candidate costs when it runs alone on the first attempt. In production, a cheaper candidate whose validator rejects 20% of outputs actually costs `first_try_cost + fallback_cost × 0.20` per successful output. The single-shot number understates this.

Pass `production_mode: { fallback: "..." }` to measure the true effective cost:

```ruby
ClassifyTicket.compare_models(
  "edge_cases",
  candidates: [{ model: "gpt-5-nano" }, { model: "gpt-5-mini", reasoning_effort: "low" }],
  production_mode: { fallback: "gpt-5-mini" }
).print_summary
```

Output:

```
  Chain                        single-shot  escalation  effective cost  latency    score
  -----------------------------------------------------------------------------------------
  gpt-5-nano → gpt-5-mini      $0.0010      20%         $0.0016         164ms       1.00
  gpt-5-mini (effort: low) → …  $0.0015      5%          $0.0016          210ms       1.00
  gpt-5-mini                    $0.0030      —           $0.0030          220ms       1.00
```

**Reading the table:**

- **`single-shot`** — cost of the 1st attempt alone (matches the classic table).
- **`escalation`** — fraction of cases where the candidate's validator rejected the first output and the fallback ran as a retry.
- **`effective cost`** — sum of all attempted costs per case, averaged. This is what you actually pay per successful output in production.
- **`—` in escalation** (em-dash, not 0%) — appears when the candidate equals the fallback. The row is a pure single-shot eval; there's no escalation chain to observe. `effective == single-shot` by construction.

**Interaction with `runs:`.** `production_mode: { fallback: } + runs: 3` averages every metric — including `escalation_rate` — across runs. A single-run escalation rate inherits the same variance as a single-run score (cf. [Reducing variance with `runs:`](#reducing-variance-with-runs)).

**Scope.** `production_mode:` supports **single-fallback (2-tier)** chains only. Multi-tier chains can still be inspected post-hoc via `trace.attempts`, but the table summarizes 2-tier. Empirically, 2-tier covers the common case where one cheap model handles easy inputs and one safe model catches the rest.

**When to use it.** Run it before finalizing a retry chain: a candidate that saves 3× on single-shot but escalates 60% of the time may save only 1.2× in production. The classic table hides this; production-mode surfaces it.

**Programmatic access.** All metrics are exposed on `Report` / `AggregatedReport`: `escalation_rate`, `single_shot_cost`, `effective_cost`, `single_shot_latency_ms`, `effective_latency_ms`, `latency_percentiles` (`{p50:, p95:, max:}`).
