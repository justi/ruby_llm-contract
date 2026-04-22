# Best Practices

Schema guarantees valid JSON structure. An LLM can still return structurally perfect JSON that is **semantically wrong**. Schema handles _shape_, validates handle _meaning_.

All examples extend the `SummarizeArticle` step from the [README](../../README.md).

## 1. Guard against empty / placeholder output

**Why it matters:** a cheap model that answers `{"tldr": "This article discusses...", "takeaways": ["This article discusses X", ...]}` passes the schema but renders a broken UI card that tells the user nothing. The validate catches it before `Article.update!` persists it.

```ruby
output_schema do
  string :tldr
  array  :takeaways, of: :string, min_items: 3, max_items: 5
  string :tone, enum: %w[neutral positive negative analytical]
end

validate("tldr is substantive") do |o, _|
  o[:tldr].to_s.split.length >= 5   # at least five words
end

validate("no boilerplate takeaways") do |o, _|
  o[:takeaways].none? { |t| t.downcase.start_with?("this article") }
end
```

## 2. Cross-validate output against input

**Why it matters:** a lazy model will return the article text verbatim as the "summary", or invent takeaways about topics the article never mentions. The 2-arity form is how you catch answers that are internally consistent but unfaithful to the actual input.

`validate` blocks with 2-arity `|output, input|` compare the model's answer against what was asked:

```ruby
validate("tldr is shorter than the article") do |output, input|
  output[:tldr].length < input.length / 2
end

validate("every takeaway appears, in spirit, in the article") do |output, input|
  output[:takeaways].all? { |t|
    # cheap keyword overlap heuristic
    t.downcase.split.any? { |w| input.downcase.include?(w) && w.length > 4 }
  }
end
```

## 3. Conditional logic schema can't express

**Why it matters:** customer success filters on `tone == "negative"` to route angry users to a human. If the model labels an outage complaint "negative" but the takeaways are all positive-sounding, the filter runs on a label that doesn't match the content — the routing breaks silently.

```ruby
validate("negative tone requires at least one concrete concern") do |output, _input|
  next true unless output[:tone] == "negative"
  output[:takeaways].any? { |t| t.match?(/fail|break|crash|outage|vulnerab|risk/i) }
end
```

A model that picks `tone: "negative"` but gives three upbeat takeaways fails this check. Schema can't catch it because each takeaway is, individually, a valid string.

## 4. Content quality

**Why it matters:** a TL;DR with `## Summary` leaks markdown into a plain-text card. A one-word takeaway ("Fast.") wastes a UI slot. A leaked `{article}` placeholder reveals the prompt template to end users. All pass schema; all embarrass you in front of customers.

```ruby
validate("no markdown headings in the TL;DR") do |o, _|
  !o[:tldr].match?(/^\#{1,6}\s/)
end

validate("takeaways aren't single words") do |o, _|
  o[:takeaways].all? { |t| t.split.length >= 3 }
end

validate("no template placeholders leaked") do |o, _|
  (o[:tldr] + o[:takeaways].join(" ")).exclude?("{") rescue
    !(o[:tldr] + o[:takeaways].join(" ")).include?("{")
end
```

## 5. Pipeline: preserve data between steps

In a pipeline, each step only sees the previous step's output. If a later step needs original article metadata, an intermediate step must carry it through. Suppose a pipeline `SummarizeArticle → GenerateHashtags`, where `GenerateHashtags` needs the `tone` from the summary:

```ruby
class GenerateHashtags < RubyLLM::Contract::Step::Base
  input_type Hash

  output_schema do
    # Carry through the fields a downstream step (or the caller) might need
    string :tone, enum: %w[neutral positive negative analytical]
    array  :hashtags, of: :string, min_items: 2, max_items: 5
  end

  prompt do
    rule "Preserve the tone label from the input unchanged."
    user "Summary: {tldr}\nTone: {tone}\nTakeaways: {takeaways}"
  end

  validate("tone preserved") { |o, input| o[:tone] == input[:tone] }
end
```

The explicit `validate("tone preserved")` catches the case where the model silently rewrites the tone during a downstream transform.

## 6. Model fallback

**Why it matters:** 80% of production articles are short and simple — `gpt-4.1-nano` handles them for ~$0.0001. The remaining 20% are dense, critical, or multi-topic — those need `gpt-4.1-mini` or `gpt-4.1`. Paying `gpt-4.1` rates for every call when nano is enough for most is throwing money away. Contracts tell you when nano wasn't enough, so fallback is cost-aware, not hope-based.

Small models are cheap but hallucinate. Big models are accurate but expensive. Start cheap, fall back only when validates catch a failure:

```ruby
class SummarizeArticle < RubyLLM::Contract::Step::Base
  output_schema do
    string :tldr
    array  :takeaways, of: :string, min_items: 3, max_items: 5
    string :tone, enum: %w[neutral positive negative analytical]
  end

  validate("TL;DR fits the card")  { |o, _| o[:tldr].length <= 200 }
  validate("takeaways are unique") { |o, _| o[:takeaways].uniq.size == o[:takeaways].size }

  retry_policy models: %w[gpt-4.1-nano gpt-4.1-mini gpt-4.1]
end
```

**Key insight:** without contracts, you can't do model fallback — you'd have no way to know if the cheap model's output is good enough. Validates are the quality gate that makes cost optimization possible. See [Optimizing retry_policy](optimizing_retry_policy.md) for how to find the cheapest viable fallback list for your step.

## Summary

| What to validate | Use |
|---|---|
| Field types, enums, ranges, required fields | `output_schema` |
| Output makes sense given the input | `validate` (2-arity `\|output, input\|`) |
| Conditional business rules | `validate` |
| Content quality (not empty, not template) | `validate` |
| Data preserved across pipeline steps | `validate` + schema carry-through |
| Cost optimization via model fallback | `retry_policy` + `validate` as quality gate |
