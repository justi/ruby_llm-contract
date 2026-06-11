# LLM-judge pattern

> **Cursor, April 2025.** A support chatbot named "Sam" confidently told customers their subscription was limited to one device — a security policy the company never had. Reddit and Hacker News picked it up within hours. Some customers cancelled. Anysphere (Cursor's creator — an AI-tooling company) had to issue a public apology and refund the user who blew the whistle.
>
> Every Sam response was schema valid. JSON parsed, structured output, validate blocks green.
>
> Your schemas check shape, not meaning. This guide adds the missing layer: a second LLM that reads the answer and decides whether it's faithful to your source of truth.

> ⚠️ **Limit of this layer.** The judge keeps the model **consistent with the source you give it** — nothing more. It does NOT verify the source itself. If your policy document is incomplete or out of date, a consistent answer can still be wrong: the gate passes, the customer wins in court. Treat the source with the same versioning discipline as your code.

> 📊 **The pattern repeats.** By May 2025, **129 court cases** involved LLM-generated fake citations submitted as evidence — averaging $4,713 in sanctions per case. **Klarna reversed** its 2024 decision to replace customer service with AI after a year of hallucination complaints. This is not a long-tail risk — it's a systemic, recurring failure mode of LLM applications.

## When you need a judge

Most outputs can be checked deterministically: the schema matches, an enum is in range, a string fits a length limit. Those go in `validate` blocks or `output_schema`.

Some questions cannot be checked that way:

- *"Is this summary accurate to the source article?"*
- *"Does this support reply actually answer the customer's question?"*
- *"Is this translation faithful to the original tone?"*

Reading the LLM's output character-by-character will not tell you. You need a second model to read it and decide. That second model is the **judge**.

The catch: a judge is just another LLM. If you trust its scores before you verify it agrees with humans, you have replaced one black box with two.

## The pattern in three steps

The running example is `SummarizeArticle` from [Getting Started](getting_started.md) — a Step that produces a TL;DR plus a few takeaways. We want to detect when a prompt change makes the summary less accurate to the source article.

### Step 1 — Build the judge as a Contract Step

The judge is just another Step. The benefit of using `ruby_llm-contract`: you get the same retry, cost cap, and structured-output guarantees that any other Step in this gem provides.

The judge takes **two** inputs in a single Hash: the SOURCE you want the answer to be faithful to (here: the article), and the ANSWER under review (here: the summary). Both are required — without the source, the judge has nothing to verify against.

The `prompt do` DSL uses a small template syntax: `{key}` placeholders are interpolated from the input. With `input_type Hash`, every top-level key of the hash becomes available as `{key}` — here `{article}` and `{summary}` map to `input[:article]` and `input[:summary]` when you later call `AccuracyJudge.run(article: ..., summary: ...)`. With `input_type String`, you use the special `{input}` placeholder (one input, one slot). It is the gem's own syntax — not ERB, not `String#%`, not string interpolation — and it is what makes the judge inputs visible inside the prompt.

```ruby
# A cheap model reads the summary against its source and decides if the
# summary's claims all come from the article. Structured boolean +
# reason so we can debug failures later.
class AccuracyJudge < RubyLLM::Contract::Step::Base
  input_type Hash             # { summary:, article: }
  model "gpt-5-nano"

  prompt do
    system "You decide whether a summary is accurate to the article."
    user <<~MSG
      Article:
      {article}

      Summary:
      {summary}

      Answer two things:
      - accurate: true if every claim in the summary comes from the article
        (no added facts, no contradictions). false otherwise.
      - reason: one short sentence explaining your decision.
    MSG
  end

  output_schema do
    boolean :accurate
    string  :reason
  end

  retry_policy models: %w[gpt-5-nano gpt-5-mini]
  max_cost 0.001
end
```

The `retry_policy` escalates to `gpt-5-mini` if the cheaper `gpt-5-nano` fails schema/validate (e.g., returns malformed JSON) — the judge stays reliable without paying for the bigger model on every call. `max_cost 0.001` bounds each call: the judge runs N× per eval suite (one call per case), so capping per-call cost prevents calibration runs from blowing the budget.

This is small on purpose: one boolean, one reason. Easy to read, easy to disagree with.

> 💡 **When the judge needs to point at a specific sentence, not just say "drift".**
>
> *Drift* here means the answer adds facts not in the source, contradicts the source, or extends scope beyond what the source covers — even though schema and validate blocks pass.
>
> Boolean + reason is fine for binary regression checks. When you want the judge to be a debugging tool — telling you which exact claim in the answer drifted — swap the output schema for a per-claim breakdown:
>
> ```ruby
> output_schema do
>   array :claims do
>     object do
>       string :claim
>       string :status, enum: %w[supported contradicted unsupported]
>     end
>   end
>   string :verdict, enum: %w[pass fail]
>   string :reason
> end
> ```
>
> Now a failed eval gives you a per-claim breakdown like `"Ruby 3.4 has a new pattern matching syntax" → unsupported` (the source article doesn't mention pattern matching) or `"Released in January 2025" → contradicted` (the article says December 2024). Three statuses, each grounded in the SOURCE you passed: **supported** (the article says so), **contradicted** (the article says the opposite), **unsupported** (the article doesn't mention it either way). That's a sentence-level pointer your PR review can act on, not just "score dropped". Costs slightly more tokens per call; pays off the first time you debug a regression. (Reminder: `array :x do object do ... end end` — without the inner `object do`, the schema silently degrades to `items: string`.)

### Step 2 — Calibrate the judge against humans on real production data

Before the judge can gate anything, you need to know it agrees with a human reviewer. Pull a handful of real production summaries (not synthetic, not edge cases you imagined) and have a human label each one as accurate or not.

```ruby
AccuracyJudge.define_eval("calibration") do
  add_case "prod_a",
           input:    { article: PROD_A_ARTICLE, summary: PROD_A_SUMMARY },
           expected: { accurate: true }    # the human said: looks accurate

  add_case "prod_b",
           input:    { article: PROD_B_ARTICLE, summary: PROD_B_SUMMARY },
           expected: { accurate: false }   # the human said: summary added a date not in the source

  # ... 30 to 50 cases, sampled from real production traffic
end
```

Run it. The score tells you how often the judge agrees with the human:

```ruby
report = AccuracyJudge.run_eval("calibration")
report.score   # => 0.92  → judge agrees with humans 92% of the time
```

A reasonable bar is `score >= 0.85` — an empirical baseline from LLM-eval field practice ([Eugene Yan on evals](https://eugeneyan.com/writing/evals/), [Hamel Husain field guide](https://hamel.dev/blog/posts/field-guide/)). Below that, judge-human agreement drops into a band where the judge's confident percentages stop matching what a human reviewer would say, and gate decisions become unreliable. If your domain is high-stakes (medical, legal, financial), raise the bar to 0.90+. Iterate the judge's prompt, or escalate to a stronger model, until the score on real production data crosses your bar.

**What "iterate the judge's prompt" actually looks like.** The first judge prompt almost always over-flags. Two or three iterations are normal before the judge is ready to gate anything. The common pattern:

| Addition in the answer | Naive judge marks | Should be |
|---|---|---|
| "Happy to help with anything else" (small talk) | unsupported | supported (stylistic) |
| "We'll find a flexible solution" (commitment) | unsupported | unsupported (out of policy) |

When the per-claim breakdown shows the judge can't distinguish those two categories, refine its prompt to make the distinction explicit:

```
Distinguish two kinds of additions outside the source:
  a) Stylistic courtesy (greetings, empathy, small talk) — treat as supported.
  b) Out-of-policy commitments (offers, promises, gestures) — unsupported.
```

Re-run calibration. Score recovers from 0.6 to 0.92 not because the judge got smarter, but because you taught it your distinction between "polite filler" and "business commitment". Calibration is itself an eval-first loop — not a one-time qualification gate.

### Step 3 — Use the calibrated judge as the eval gate

Only now, after the judge has earned trust on real data, do you use it as the oracle in a regression eval on the Step you actually care about. The evaluator lambda receives two arguments:

- `output` — `parsed_output` of the Step under test. Here `output[:tldr]` is the summary `SummarizeArticle` produced (the same field declared in its `output_schema`).
- `input` — whatever you passed to `add_case input:`. Here it's the original article string.

The lambda must return a `Float` in `[0.0, 1.0]` — the eval framework averages per-case scores into the suite score. Map `true → 1.0`, `false → 0.0`, or use weighted partial scores if your judge returns gradations.

> ⚠️ **Heads-up before you copy the snippet below.** Smoke evals on `SummarizeArticle` (per [Getting Started](getting_started.md)) typically run with `RubyLLM::Contract::Adapters::Test` for determinism — canned summaries, no API calls. **The `AccuracyJudge.run(...)` inside the evaluator does NOT inherit that Test adapter.** Each Step picks its adapter independently (from `RubyLLM::Contract.configure`, `context: { adapter: }`, or `LIVE=1` env). Run accuracy-regression evals as live (`LIVE=1` or explicit `context:`), and rely on `max_cost` on the judge to bound the bill.
>
> This is intentional: the judge IS the oracle, so faking its verdicts would defeat the purpose. Keep the Test-adapter smoke evals for schema/wiring checks only.

```ruby
SummarizeArticle.define_eval("accuracy_regression") do
  add_case "prod_article_42",
           input: PROD_ARTICLE_42,
           evaluator: ->(output, input) {
             verdict = AccuracyJudge.run({
               summary: output[:tldr],
               article: input
             })
             verdict.parsed_output[:accurate] ? 1.0 : 0.0
           }

  # ... one case per real production article you want to defend
end
```

Now `SummarizeArticle.run_eval("accuracy_regression")` is your real before/after signal:

- Run it before a prompt change → baseline score.
- Run it after the prompt change → if the score drops, the new prompt made the summary less accurate (and a calibrated judge says so, which means a human would likely say so too).

## Anti-patterns

Each of these has been observed in real production projects.

**Stubbing the judge's verdict in unit tests.** Your spec replaces `AccuracyJudge.run` with a canned `{ accurate: true }` and then checks that the eval scoring math adds up. The math is correct; you have learned nothing about whether the judge's real verdicts agree with reality. Calibrate the judge against humans (Step 2). Do not stub it.

**Calibrating on synthetic data.** You ask another LLM to generate 50 summary+article pairs labeled accurate or not, then check the judge against those labels. The calibration only proves your judge agrees with the labeling LLM. Use real production samples reviewed by a human.

**Per-language regex instead of a judge.** "If the summary contains the word 'unfortunately' AND the article does not, flag it as a hallucination." This works once, drifts the moment the prompt changes the tone, and silently breaks on a new locale. A single LLM-judge with one prompt covers all locales; a per-language regex set does not.

**Running the judge on the production request path.** The judge adds an extra LLM call per output. On the eval suite (on-demand or CI), that is fine. On every production request, that is double the latency and double the cost. Keep judges in the eval suite.

**Calibrating once and shipping.** First calibration gives you a baseline. Production drifts — new product lines, new customer behaviors, seasonal patterns, provider model updates — and the calibration drifts with it. A judge calibrated against Q1 customer-support logs may silently misjudge Q3 traffic after a new return policy launched.

What to do operationally:

- **Re-calibrate** against a fresh human-labeled sample every quarter, or after any material business change (new SKU category, prompt rewrite on the gated Step, model version bump).
- **Store** calibration scores per run — a DB column, a log line, or a CI artifact.
- **Alert** when the 30-day rolling average drops more than 10 points. 30 days smooths daily judge-call noise; 10 points crosses noise floor while staying sensitive to real drift. Adjust the window down for high-volume Steps (7-day) or up for slow-drift business contexts (60-day).

The drop is your signal to refine the judge's prompt, not to lower the gate.

## When to escalate to Tribunal's catalog

If you find yourself building three or four judges that all rhyme — "faithful?", "hallucination?", "refusal?", "PII leakage?" — you are reinventing what [`ruby_llm-tribunal`](https://github.com/Alqemist-labs/ruby_llm-tribunal) ships as a built-in catalog. See [Relation to Tribunal](relation_to_tribunal.md) for the integration recipe: Contract Steps make the LLM calls, Tribunal supplies the grading vocabulary, and the two compose in a single `define_eval`.

## See also

- [Eval-First](eval_first.md) — when to write evals, the three kinds, the oracle-validation rule that this guide implements in code.
- [Best Practices](best_practices.md) — keeping evals cheap, real, and trustworthy over time.
- [Optimizing retry_policy](optimizing_retry_policy.md) — once your eval is honest, find the cheapest model chain that still passes it.
