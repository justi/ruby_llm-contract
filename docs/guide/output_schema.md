# Output Schema

Declare the expected output structure using [ruby_llm-schema](https://github.com/danielfriis/ruby_llm-schema) DSL. The schema serves **two purposes**:

1. **Output validation** — replaces type and shape checks (enums, ranges, required fields). One declaration instead of many.
2. **Provider-side request** — with the RubyLLM adapter, the schema is sent to the LLM provider via `chat.with_schema(...)`, asking the model to return JSON matching the shape. Cheaper models sometimes ignore the request, which is why client-side validation (point 1) still matters.

All examples below extend the `SummarizeArticle` step from the [README](../../README.md).

## Schema replaces type and shape checks

```ruby
# WITHOUT schema — many validates:
validate("tldr must be a string")          { |o| o[:tldr].is_a?(String) }
validate("takeaways must be an array")     { |o| o[:takeaways].is_a?(Array) }
validate("takeaways 3 to 5")               { |o| (3..5).cover?(o[:takeaways].size) }
validate("tone must be an allowed label")  { |o| %w[neutral positive negative analytical].include?(o[:tone]) }

# WITH schema — one declaration:
output_schema do
  string :tldr
  array  :takeaways, of: :string, min_items: 3, max_items: 5
  string :tone, enum: %w[neutral positive negative analytical]
end
```

## Nested objects in arrays

Use `object do...end` inside `array` when you need more than a primitive per element. If `SummarizeArticle` grows to attach confidence per takeaway:

```ruby
output_schema do
  string :tldr
  array :takeaways, min_items: 3, max_items: 5 do
    object do
      string :text
      number :confidence, minimum: 0.0, maximum: 1.0
    end
  end
  string :tone, enum: %w[neutral positive negative analytical]
end
```

## Schema pattern reference

| Your output looks like | Schema pattern | Example |
|---|---|---|
| `{"tldr": "...", "tone": "positive"}` | Flat fields | `string :tldr; string :tone, enum: [...]` |
| `{"takeaways": ["...", "..."]}` | Array of primitives | `array :takeaways, of: :string, min_items: 3, max_items: 5` |
| `{"takeaways": [{"text": "...", "confidence": 0.9}]}` | Array of objects | `array :takeaways do; object do; string :text; number :confidence; end; end` |

Without `object do...end`, `array :takeaways do; string :text; end` tells the provider "takeaways is an array of strings" — not objects. That's what you get back.

## Why schema alone is not enough

Schema validates **shape** — correct types, allowed values, field presence. But LLMs can return structurally valid JSON that is **logically wrong**. Validates catch what schema can't:

```ruby
output_schema do
  string :tldr
  array  :takeaways, of: :string, min_items: 3, max_items: 5
  string :tone, enum: %w[neutral positive negative analytical]
end

# Schema allows any string for :tldr — but a 500-char "summary" breaks the UI card.
validate("TL;DR fits the card") { |o, _| o[:tldr].length <= 200 }

# Schema enforces 3–5 takeaways — but says nothing about them being distinct.
validate("takeaways are unique") { |o, _| o[:takeaways].uniq.size == o[:takeaways].size }

# Schema can't express cross-field rules.
validate("critical tone requires at least one concrete risk") do |o, _|
  next true unless o[:tone] == "negative"
  o[:takeaways].any? { |t| t.match?(/fail|break|crash|outage|vulnerab/i) }
end
```

## Supported constraints

| Constraint | Types | Example |
|---|---|---|
| `enum` | string, integer | `string :tone, enum: %w[neutral positive negative analytical]` |
| `minimum` / `maximum` | number, integer | `number :confidence, minimum: 0.0, maximum: 1.0` |
| `min_length` / `max_length` | string | `string :tldr, min_length: 1, max_length: 200` |
| `min_items` / `max_items` | array | `array :takeaways, of: :string, min_items: 3, max_items: 5` |
| `additional_properties` | object | Set to `false` in the schema to reject extra keys |

Keyword args use Ruby snake_case (`min_length`, `min_items`). The DSL converts them internally to JSON Schema's camelCase (`minLength`, `minItems`) before sending the schema to the provider — you don't need to write camelCase in Ruby.
