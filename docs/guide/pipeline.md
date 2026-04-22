# Pipeline

> Read this when one step isn't enough — you need multi-step with fail-fast, automatic data threading, and per-step models.

Chain multiple steps with automatic data threading, fail-fast, per-step models, trace, and timeout.

A pipeline needs more than one step to be interesting. This guide grows the `SummarizeArticle` step from the [README](../../README.md) into a three-step content pipeline that tags and routes the summary to a UI card.

## Full example: article → summary → hashtags → card

```ruby
# Step 1 — the flagship step from README, unchanged.
class SummarizeArticle < RubyLLM::Contract::Step::Base
  prompt <<~PROMPT
    Summarize this article for a UI card. Return a short TL;DR,
    3 to 5 key takeaways, and a tone label.

    {input}
  PROMPT

  output_schema do
    string :tldr
    array  :takeaways, of: :string, min_items: 3, max_items: 5
    string :tone, enum: %w[neutral positive negative analytical]
  end

  validate("TL;DR fits the card") { |o, _| o[:tldr].length <= 200 }
end

# Step 2 — reads SummarizeArticle's output, produces hashtags suitable for social posts.
class GenerateHashtags < RubyLLM::Contract::Step::Base
  input_type Hash

  output_schema do
    # Carry through the summary fields downstream consumers (and the next step) need.
    string :tldr
    array  :takeaways, of: :string
    string :tone, enum: %w[neutral positive negative analytical]
    # Add new field.
    array  :hashtags, of: :string, min_items: 2, max_items: 5
  end

  prompt do
    rule "Preserve tldr / takeaways / tone exactly as given."
    user "Article summary: {tldr}\nTone: {tone}\nGenerate 2 to 5 concise hashtags."
  end

  validate("tone preserved") { |o, input| o[:tone] == input[:tone] }
end

# Step 3 — final shape the UI card consumes.
class BuildArticleCard < RubyLLM::Contract::Step::Base
  input_type Hash

  output_schema do
    string :headline
    string :summary
    array  :hashtags, of: :string
    string :sentiment_icon, enum: %w[😐 🙂 ⚠️ 🧠]
  end

  prompt do
    rule "Headline <= 70 chars. Summary is the incoming tldr reprinted verbatim."
    rule "Pick sentiment_icon from: 😐 neutral, 🙂 positive, ⚠️ negative, 🧠 analytical."
    user "TL;DR: {tldr}\nTone: {tone}\nHashtags: {hashtags}"
  end

  validate("summary is the tldr verbatim") { |o, input| o[:summary] == input[:tldr] }
end

# Pipeline: summarize → hashtags → card
class ArticleCardPipeline < RubyLLM::Contract::Pipeline::Base
  step SummarizeArticle, as: :summarize
  step GenerateHashtags, as: :tag
  step BuildArticleCard, as: :card
end
```

## Running and inspecting

```ruby
result = ArticleCardPipeline.run(article_text, context: { adapter: adapter })
result.ok?                          # => true
result.outputs_by_step[:summarize]  # => { tldr: "...", takeaways: [...], tone: "analytical" }
result.outputs_by_step[:card]       # => { headline: "...", summary: "...", hashtags: [...], sentiment_icon: "🧠" }
result.trace.total_cost             # => 0.000128 (all steps combined)
result.trace.total_latency_ms       # => 2340
```

## Fail-fast behavior

Each step catches hallucinations before they spread:

```ruby
result = ArticleCardPipeline.run("")
result.failed?        # => true
result.failed_step    # => :summarize (empty input fails schema / validate → stops here)
# tag and card never run — no downstream tokens spent on garbage
```

## Per-step model override

```ruby
class ArticleCardPipeline < RubyLLM::Contract::Pipeline::Base
  step SummarizeArticle, as: :summarize, model: "gpt-4.1-mini"
  step GenerateHashtags, as: :tag,       model: "gpt-4.1-nano"
  step BuildArticleCard, as: :card,      model: "gpt-4.1-nano"
end
```

## Timeout

```ruby
result = ArticleCardPipeline.run(article_text, timeout_ms: 30_000)
```

## Pipeline eval

```ruby
ArticleCardPipeline.define_eval("e2e") do
  add_case "ruby 3.4 release",
    input: "Ruby 3.4 ships with frozen string literals by default and better YJIT...",
    expected: { sentiment_icon: "🧠" }
end

report = ArticleCardPipeline.run_eval("e2e", context: { model: "gpt-4.1-mini" })
report.print_summary
```

## Pretty print

```ruby
puts result
# Pipeline: ok  3 steps  1234ms  450+120 tokens  trace=abc12345

result.pretty_print
# Full ASCII table with per-step outputs (Pipeline::Result)

# For eval reports, use print_summary instead:
report.print_summary
# Tabular pass/fail breakdown (Eval::Report)
```

## See also

- [Testing](testing.md) — `ArticleCardPipeline.test(..., responses: { summarize: ..., tag: ..., card: ... })` for pipeline-level spec adapters.
- [Optimizing retry_policy](optimizing_retry_policy.md) — `optimize_retry_policy` runs per-step; pipelines benchmark one step at a time.
