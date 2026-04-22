# Eval-First

If you change prompts by feel, you ship regressions by feel.

`ruby_llm-contract` works best when you treat evals as the source of truth:

1. Capture real failures from production.
2. Turn them into eval cases.
3. Change the prompt.
4. Re-run the same eval.
5. Merge only if the eval says quality improved or stayed safe.

## Core rule

**Do not start with the prompt. Start with the eval.**

Using the `SummarizeArticle` step from the [README](../../README.md):

```ruby
SummarizeArticle.define_eval("regression") do
  add_case "ruby release",
           input: "Ruby 3.4 shipped with frozen string literals...",
           expected: { tone: "analytical" }  # partial match

  add_case "critical review",
           input: "Mesh networking hardware failed under load...",
           expected: { tone: "negative" }
end
```

Only after the eval exists, touch: `system`, `rule`, `example`, `validate`, prompt versions.

## Three eval kinds

### 1. `smoke` — wiring check, offline

```ruby
SummarizeArticle.define_eval("smoke") do
  default_input "Ruby 3.4 shipped with frozen string literals..."
  sample_response({ tldr: "...", takeaways: [...], tone: "analytical" })
end
```

`sample_response` returns canned data. Zero API calls. Verifies schema + validates parse and the step wiring is intact. **Not a quality signal.**

### 2. `regression` — real quality measurement

Represent real traffic and known failures. Good sources: production logs, bad completions, incidents, QA edge cases, cases a human had to correct.

Every production failure becomes `add_case`. That's the flywheel.

### 3. `ab` — prompt iteration

Compare two prompt versions on the same eval:

```ruby
diff = SummarizeArticleV2.compare_with(
  SummarizeArticleV1,
  eval: "regression",
  model: "gpt-4.1-mini"
)

diff.safe_to_switch?  # => true if no cases regressed
```

This is the cleanest eval-first move: same eval, same cases, two prompt versions, one answer.

## What counts as eval-first

**Good** — eval exists before the prompt change:

```ruby
SummarizeArticle.define_eval("regression") do
  add_case "short article", input: "...", expected: { tone: "neutral" }
end

# Prompt iteration happens afterward
diff = SummarizeArticleV2.compare_with(SummarizeArticleV1, eval: "regression", model: "gpt-4.1-mini")
```

**Bad**:

```ruby
# Tweak prompt for an hour
# Maybe add an example
# Maybe tighten a rule
# Then eyeball one or two responses
```

That's prompt guessing, not eval-first.

## `sample_response`: useful, but not the main thing

Good for: offline smoke tests, local development, testing evaluator wiring, checking schema + validate behavior with zero API calls.

Not enough for real prompt decisions. For those:

- `run_eval(..., context: { model: "..." })` with a real model, or pass an explicit adapter.
- `compare_with(...)` for prompt A/B.

`compare_with` intentionally ignores `sample_response` — canned data would make both sides look the same.

## Team workflow

1. **Build one eval that matters** — 10–30 cases representing real mistakes and important business paths.
2. **Gate CI** — `pass_eval("regression").with_context(model: "...").with_minimum_score(0.8)`. See [Getting Started](getting_started.md) for the full matcher chain.
3. **Save a baseline** — `report.save_baseline!` makes quality drift visible.
4. **Change prompts only through comparison** — `pass_eval(...).compared_with(SummarizeArticleV1)` in CI so any regression blocks the merge.
5. **Feed production failures back** — every miss in prod → new `add_case`, then fix. The eval gets stronger over time.

## Few-shot examples fit naturally

Adding `example input: ..., output: ...` inside the prompt is still a prompt change. The eval-first way:

1. Add examples to the prompt.
2. Rerun the existing regression eval.
3. `compare_with` against the old prompt.

Few-shot isn't the proof. The eval is.

## Model selection comes after prompt stability

Don't optimize cost before you stabilize quality:

1. Build `regression`.
2. Improve the prompt with `compare_with`.
3. Lock quality in CI.
4. Then run `compare_models` (see [Optimizing retry_policy](optimizing_retry_policy.md)).

```ruby
comparison = SummarizeArticle.compare_models(
  "regression",
  candidates: [{ model: "gpt-4.1-nano" }, { model: "gpt-4.1-mini" }, { model: "gpt-4.1" }]
)

comparison.best_for(min_score: 0.95)
```

## Strong defaults for teams

- `smoke` uses `sample_response`.
- `regression` uses real model calls.
- Every prompt change uses `compare_with`.
- Every merge runs `pass_eval`.
- Every production failure becomes a new `add_case`.

## Short version

1. Write `define_eval` before touching the prompt.
2. Treat `sample_response` as smoke only.
3. Use `run_eval("name", context: { model: "..." })` for real quality measurement.
4. Use `compare_with` for every serious prompt change.
5. Gate merges with `pass_eval`.
6. Feed every production miss back into the dataset.

Prompts stop being vibes and start being engineering.
