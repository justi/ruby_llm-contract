# Why contracts?

> Read this if you're not sure whether `ruby_llm-contract` solves a problem you actually have. It's the fastest way to recognise the production failure modes the gem exists for.

LLMs return JSON that *looks* correct — valid shape, right types, right fields — while being silently wrong in ways that hurt users, burn budget, or break downstream code. Schema validation alone does not catch these. Contracts layer on business rules, retries, evals, and cost caps so the wrong output is caught at the boundary of your system instead of shipping to production.

Below are four failure modes teams actually hit. If one looks familiar, the gem is probably worth 30 minutes of your time.

## Failure 1 — Schema-valid, logically wrong

A `SummarizeArticle` step produces `{ tldr: "...", takeaways: [...], tone: "analytical" }`. Schema passes. The TL;DR is 520 characters long and overflows the UI card. Or the takeaways are all variations of the same sentence. Or the article was a service-outage complaint and `tone` came back `"analytical"` instead of `"negative"` — so customer success's "critical feedback" filter never sees it.

JSON schema enforces **shape**. It cannot enforce *length fits the card*, *takeaways are distinct*, or *tone matches content*. Those are business rules, and without them you find out from a Slack thread or a support ticket.

```ruby
validate("TL;DR fits the card")  { |o, _| o[:tldr].length <= 200 }
validate("takeaways are unique") { |o, _| o[:takeaways].uniq.size == o[:takeaways].size }
validate("negative tone requires concrete risk") do |o, _|
  next true unless o[:tone] == "negative"
  o[:takeaways].any? { |t| t.match?(/fail|break|crash|outage|risk/i) }
end
```

Wrong output never reaches `Article.update!` — the contract refuses before it persists.

## Failure 2 — Silent prompt regression

`SummarizeArticle` ships and works. Two weeks later, someone tweaks the system prompt to emphasise negative sentiment because customer success complained about missed complaints. The tweak fixes that case and silently breaks three neutral product-update articles that now get labelled `"negative"`. Nobody knows for a week.

Without evals, *every prompt change is a blind deploy.* Contracts invert this:

```ruby
SummarizeArticle.define_eval("regression") do
  add_case "outage complaint", input: "...", expected: { tone: "negative" }
  add_case "neutral product update", input: "...", expected: { tone: "neutral" }
end

# In CI — blocks merge when a prompt tweak regresses any previously-passing case
expect(SummarizeArticle).to pass_eval("regression").without_regressions
```

The "tweak helped one case, broke three" scenario is caught at PR review. No Slack-thread surprises.

## Failure 3 — Sampling variance on fixed-temperature models

OpenAI's gpt-5 and o-series run with `temperature=1.0` server-side — you cannot lower it. That means the same prompt on the same model can produce different answers between calls. An outage complaint classified `tone: "negative"` on Monday may come back `tone: "positive"` on Tuesday, with no code change in between. Schema passes both. Your customer-success filter silently misroutes the Tuesday case.

A `validate` block that cross-checks fields against each other turns a one-in-N flaky output into a deterministic retry:

```ruby
validate("tone matches severity keywords") do |o, _|
  severity = /fail|crash|outage|broken|bug|error/i
  flagged = o[:takeaways].any? { |t| t.match?(severity) }
  next true unless flagged
  %w[negative analytical].include?(o[:tone])
end

retry_policy models: %w[gpt-5-nano gpt-5-mini gpt-5]
```

Nano misclassifies the tone on the first attempt → contract rejects → mini gets the call and returns a different sample. Variance absorbed; the user never sees the flaky run. Your logs show the retry rate and the cost delta.

**See it in 30 seconds:** `ruby examples/06_fallback_showcase.rb` — zero API keys required. The Test adapter simulates a tone/takeaways mismatch on the first attempt and a consistent sample on the retry, then prints the per-attempt trace.

`retry_policy` has three other shapes beyond cross-model escalation — same-model `attempts: 3` (absorbs sampling variance without paying for a stronger tier), `reasoning_effort` escalation (low → medium → high on one model), and cross-provider fallback (Ollama → Anthropic → OpenAI — local first because it costs nothing, hosted last because it is the most accurate). `examples/07_retry_variants.rb` runs all three through the Test adapter with the trace printed.

## Failure 4 — Runaway cost and no fallback policy

Someone pastes a 40-page PDF into the endpoint that calls `SummarizeArticle`. The prompt expands to 80k tokens. Your provider bill jumps. Meanwhile, a separate team uses `gpt-4.1` for every single call because "quality matters" — even though 80% of their traffic is trivially handled by `gpt-4.1-nano` at 1/30th the cost. Neither situation is visible until the invoice arrives.

Contracts make cost a first-class concern:

```ruby
max_input  2_000   # refuses before calling the API if tokens exceed budget
max_output 4_000
max_cost   0.01    # refuses if estimated cost exceeds cap
retry_policy models: %w[gpt-4.1-nano gpt-4.1-mini gpt-4.1]  # cheap first, escalate only on failure
```

The 40-page PDF returns `status: :limit_exceeded` — zero tokens spent. The 80/20 traffic pattern resolves on nano; only the hard 20% escalate. [`optimize_retry_policy`](optimizing_retry_policy.md) tells you empirically which fallback list is cheapest for *your* evals.

## Also catches

- **Leaked prompt placeholders** — model echoes `{article}` or `{audience}` into the output because the template string wasn't interpolated. Validate string-equality check stops it before a user sees it.
- **Lazy models echoing input verbatim** — cheap model returns the article text as the "summary". 2-arity `validate("tldr shorter than input")` catches it.
- **Tone mislabel breaking downstream routing** — content says "negative", model labels it "analytical", a customer success filter misses it. Cross-validate catches the label/content drift.

## Failure → contract mechanism

| Failure in production | Contract mechanism |
|---|---|
| Schema-valid but logically wrong output | `validate(...) { |o, i| ... }` with 2-arity for cross-checks |
| Silent prompt regression after a tweak | `define_eval` + `pass_eval(...).without_regressions` in CI |
| Sampling variance on fixed-temperature models (gpt-5 / o-series) | Cross-field `validate(...)` + `retry_policy models: [...]` |
| Runaway cost on pathological inputs | `max_input`, `max_output`, `max_cost` preflight |
| 80/20 traffic paying the premium model rate | `retry_policy` + `optimize_retry_policy` |
| Leaked placeholder / input echo / tone drift | `validate` with content and cross-input checks |

## What next

- **If one of the failures above looks familiar** → [Getting Started](getting_started.md) walks through every feature in order on the same `SummarizeArticle` step.
- **If you're adopting in an existing Rails app** → [Migration](migration.md) shows Before/After for replacing a raw `LlmClient.new.call` service.
- **If you already ship LLM features and want to make them regression-safe** → [Eval-First](eval_first.md) is the workflow that prevents Failure 2 from ever happening again.
