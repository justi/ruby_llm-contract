# Optimizing retry_policy

How to find the cheapest retry chain that passes all your evals.

## The problem

`recommend` runs on **one eval at a time**. If you optimize for `smoke` alone, you may pick a cheap model that fails harder evals like `topic_mismatch`. The cheapest model per eval varies — the retry chain must satisfy the **constraining eval** (the hardest one).

## Procedure

### 1. List evals for the step

```ruby
# Check which evals exist
MyStep.eval_names  # => ["smoke", "edge_cases", "locale"]
```

Or from the command line — run smoke and look at the output labels:

```bash
rake ruby_llm_contract:eval
```

### 2. Run recommend on every eval

```bash
rake ruby_llm_contract:recommend STEP=MyStep EVAL=smoke         CANDIDATES=cheap-model,mid-model@low,mid-model,expensive-model
rake ruby_llm_contract:recommend STEP=MyStep EVAL=edge_cases    CANDIDATES=cheap-model,mid-model@low,mid-model,expensive-model
rake ruby_llm_contract:recommend STEP=MyStep EVAL=locale        CANDIDATES=cheap-model,mid-model@low,mid-model,expensive-model
```

Running on only one eval gives a misleadingly cheap recommendation.

### 3. Build the score table

Collect results into a table:

```
                 cheap   mid@low   mid    expensive
smoke            0.67    1.00      1.00   1.00
edge_cases       0.67    0.67      1.00   1.00       ← constraining
locale           1.00    1.00      1.00   1.00
```

The **constraining eval** is the row that needs the strongest model.

### 4. Build the escalation chain

Read the table column by column, cheapest first. Each step in the chain covers more evals:

- `cheap` passes 1/3 evals → viable first attempt for easy cases
- `mid@low` passes 2/3 → catches one more edge case
- `mid` passes 3/3 → catches the constraining eval

The chain is: `cheap → mid@low → mid`. No need for `expensive` if `mid` already clears everything.

```ruby
retry_policy do
  escalate(
    { model: "cheap" },
    { model: "mid", reasoning_effort: "low" },
    { model: "mid" }
  )
end
```

### 5. Verify

```bash
rake ruby_llm_contract:eval   # smoke evals must still pass
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
