# Eval-First

If you change prompts by feel, you ship regressions by feel.

`ruby_llm-contract` works best when you treat evals as the source of truth:

1. Capture real failures from production.
2. Turn them into eval cases.
3. Change the prompt.
4. Re-run the same eval.
5. Merge only if the eval says quality improved or stayed safe.

That is the practical version of `eval-first`.

## Core Rule

**Do not start with the prompt. Start with the eval.**

In this gem, that means:

```ruby
ClassifyTicket.define_eval("regression") do
  add_case "billing dispute",
           input: "I was charged twice this month",
           expected: { priority: "high", category: "billing" }

  add_case "outage",
           input: "Database is down for all customers",
           expected: { priority: "urgent", category: "technical" }
end
```

Then and only then:
- add or change `system`
- tighten `rule`
- add `example`
- change `validate`
- compare prompt versions

## The Right Mental Model

Use the gem in three layers:

### 1. `smoke`

Fast, local, often offline.

Purpose:
- verify that the step still parses
- verify schema and validates
- catch obvious contract breakage

```ruby
ClassifyTicket.define_eval("smoke") do
  default_input "My invoice is wrong"
  sample_response({ priority: "high", category: "billing" })
end
```

`sample_response` is good here.

It is **not** your main quality signal.

### 2. `regression`

This is your real eval-first dataset.

Purpose:
- represent real user traffic
- capture known failures and expensive mistakes
- gate merges and prompt changes

Good sources:
- support tickets
- bad completions from logs
- incidents
- edge cases found in QA
- cases where a human had to correct the output

Every time the model fails in production, the default response should be:

`add_case`, then fix.

### 3. `ab`

Prompt iteration.

Purpose:
- compare old prompt vs new prompt on the same dataset
- block regressions before rollout

```ruby
diff = ClassifyTicketV2.compare_with(
  ClassifyTicketV1,
  eval: "regression",
  model: "gpt-4.1-mini"
)

diff.safe_to_switch?
```

This is the cleanest `eval-first` move in the gem: same eval, same cases, two prompt versions.

## What Counts As Eval-First In This Gem

### Good

```ruby
ClassifyTicket.define_eval("regression") do
  add_case "refund", input: "Refund me", expected: { category: "billing" }
end

# Prompt changes happen after the eval exists
diff = NewPrompt.compare_with(OldPrompt, eval: "regression", model: "gpt-4.1-mini")
```

### Bad

```ruby
# Tweak prompt for an hour
# Maybe add an example
# Maybe tighten a rule
# Then manually eyeball one or two responses
```

That is not eval-first. That is prompt guessing.

## `sample_response`: Useful, But Not The Main Thing

`sample_response` is excellent for:
- offline smoke tests
- local development
- testing evaluator wiring
- verifying schema + validate behavior with zero API calls

It is **not** enough for real prompt decisions.

For real eval-first work:
- use `run_eval(..., context: { model: "..." })`
- or pass an explicit adapter

And for prompt A/B:
- use `compare_with`
- with a real `model:` or explicit adapters

`compare_with` intentionally ignores `sample_response`, because canned data would make both sides look the same.

## The Minimal Team Workflow

### Step 1. Build one eval that matters

Start with 10 to 30 cases that represent real mistakes and important business paths.

```ruby
ClassifyTicket.define_eval("regression") do
  add_case "invoice", input: "Invoice is wrong", expected: { category: "billing" }
  add_case "feature", input: "Please add dark mode", expected: { priority: "low" }
  add_case "outage", input: "Everything is down", expected: { priority: "urgent" }
end
```

### Step 2. Gate it in CI

```ruby
expect(ClassifyTicket).to pass_eval("regression")
  .with_context(model: "gpt-4.1-mini")
  .with_minimum_score(0.8)
```

Now prompt changes stop being opinion-based.

### Step 3. Save a baseline

```ruby
report = ClassifyTicket.run_eval("regression", context: { model: "gpt-4.1-mini" })
report.save_baseline!(model: "gpt-4.1-mini")
```

This makes quality drift visible.

### Step 4. Change prompts only through comparison

```ruby
expect(ClassifyTicketV2).to pass_eval("regression")
  .with_context(model: "gpt-4.1-mini")
  .compared_with(ClassifyTicketV1)
  .with_minimum_score(0.8)
```

If the new prompt regresses, the change does not merge.

### Step 5. Add every production failure back into the eval

This is the flywheel:

- failure in prod
- add a case
- improve prompt
- rerun eval
- lock it with CI

That is how the eval gets stronger over time.

## Few-Shot Examples Fit Naturally

If you add:

```ruby
example input: "My invoice is wrong", output: '{"priority":"high","category":"billing"}'
```

that is still just a prompt change.

The eval-first way to use few-shot is:

1. add examples to the prompt
2. rerun the existing regression eval
3. compare against the old prompt with `compare_with`

Few-shot is not the proof.
The eval is the proof.

## Model Selection Comes After Prompt Stability

Do not optimize model cost before you stabilize prompt quality.

Recommended order:

1. Build `regression`
2. Improve prompt with `compare_with`
3. Lock quality in CI
4. Then run `compare_models`

```ruby
comparison = ClassifyTicket.compare_models(
  "regression",
  models: %w[gpt-4.1-nano gpt-4.1-mini gpt-4.1]
)

comparison.best_for(min_score: 0.95)
```

This keeps cost optimization downstream from quality.

## Strong Defaults For Teams

If you want one simple standard:

- `smoke` uses `sample_response`
- `regression` uses real model calls
- every prompt change uses `compare_with`
- every merge runs `pass_eval`
- every production failure becomes a new `add_case`

That is enough to make the gem work in a real eval-first loop.

## Short Version

Use the gem like this:

1. Write `define_eval` before touching the prompt.
2. Treat `sample_response` as smoke only.
3. Use `run_eval(..., model: ...)` for real quality measurement.
4. Use `compare_with` for every serious prompt change.
5. Gate merges with `pass_eval`.
6. Feed every production miss back into the eval dataset.

If you do that consistently, prompts stop being vibes and start being engineering.
