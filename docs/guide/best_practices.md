# Best Practices

Schema guarantees valid JSON structure. But an LLM can return structurally perfect JSON that is **semantically wrong**. Schema handles _shape_, validates handle _meaning_.

## 1. Guard against garbage output

```ruby
output_schema do
  string :decision
  string :made_by
end

validate("decision must be substantive") do |o|
  o[:decision].to_s.split.length >= 3
end
```

## 2. Cross-validate output against input

```ruby
validate("target language matches request") do |output, input|
  output[:target_lang] == input[:target_lang]
end

validate("all input IDs present in output") do |output, input|
  output[:items].map { |i| i[:id] }.sort == input[:items].map { |i| i[:id] }.sort
end
```

## 3. Catch conditional logic

```ruby
output_schema do
  string :priority, enum: %w[low medium high urgent]
  string :summary
end

validate("urgent must be justified") do |output, input|
  next true unless output[:priority] == "urgent"
  body = input[:body].downcase
  body.include?("data loss") || body.include?("security")
end
```

## 4. Validate content quality

```ruby
validate("not a template response") do |o|
  !o[:body].to_s.include?("[Name]") && !o[:body].to_s.include?("[Date]")
end

validate("minimum meaningful content") do |o|
  o[:body].to_s.split.length >= 20
end

validate("no markdown in plain text output") do |o|
  !o[:comment].to_s.match?(/^\#{2,}/)
end
```

## 5. Pipeline: preserve data between steps

In a pipeline, each step only sees the previous step's output. If step 3 needs data from step 1, step 2 must carry it through.

```ruby
class AnalyzeStep < RubyLLM::Contract::Step::Base
  output_schema do
    # Carry through from step 1
    string :decision
    string :decision_by
    # Add new analysis fields
    string :status, enum: %w[clear ambiguous]
    string :issue
  end

  prompt do
    rule "Pass through decision and decision_by unchanged."
    user "{input}"
  end

  validate("decision preserved") { |o| !o[:decision].to_s.strip.empty? }
end
```

## 6. Model fallback

Small models are cheap but hallucinate. Big models are accurate but expensive. Start cheap, fall back only when validates catch a failure:

```ruby
class AnalyzeCompetitor < RubyLLM::Contract::Step::Base
  output_schema do
    string :company_name
    string :pricing_model, enum: %w[freemium subscription one_time usage_based]
    string :strength_1
    string :weakness_1
  end

  validate("strengths are specific") { |o| o[:strength_1].to_s.split.length >= 5 }
  validate("weaknesses are specific") { |o| o[:weakness_1].to_s.split.length >= 5 }

  retry_policy models: %w[gpt-4.1-nano gpt-4.1-mini gpt-4.1]
end
```

**Key insight:** without contracts, you can't do model fallback — you'd have no way to know if the cheap model's output is good enough. Validates are the quality gate that makes cost optimization possible. See [Optimizing retry_policy](optimizing_retry_policy.md) for how to find the cheapest viable fallback list for your step.

## Summary

| What to validate | Use |
|-----------------|-----|
| Field types, enums, ranges, required fields | `output_schema` |
| Output makes sense given the input | `validate` (2-arity) |
| Conditional business rules | `validate` |
| Content quality (not empty, not template) | `validate` |
| Data preserved across pipeline steps | `validate` + schema carry-through |
| Cost optimization via model fallback | `retry_policy` + `validate` as quality gate |
