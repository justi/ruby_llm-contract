# Output Schema

Declare the expected output structure using [ruby_llm-schema](https://github.com/danielfriis/ruby_llm-schema) DSL. The schema serves **two purposes**:

1. **Output validation** — replaces structural validates (enums, ranges, required fields). One declaration instead of many.
2. **Provider-side enforcement** — with the RubyLLM adapter, the schema is sent to the LLM provider via `chat.with_schema(...)`, so the model is **forced** to return JSON matching the schema.

## Schema replaces structural validates

```ruby
# WITHOUT schema — many validates:
validate("must include intent") { |o| o[:intent].to_s != "" }
validate("intent must be allowed") { |o| %w[sales support billing].include?(o[:intent]) }
validate("confidence must be a number") { |o| o[:confidence].is_a?(Numeric) }
validate("confidence in range") { |o| o[:confidence]&.between?(0.0, 1.0) }

# WITH schema — one declaration:
output_schema do
  string :intent, enum: %w[sales support billing]
  number :confidence, minimum: 0.0, maximum: 1.0
end
```

## Nested objects in arrays

Use `object do...end` inside `array`:

```ruby
output_schema do
  string :locale
  array :groups, min_items: 1, max_items: 3 do
    object do
      string :who
      array :use_cases do
        string
      end
      array :tags do
        string
      end
    end
  end
end
```

## Schema pattern reference

| Your output looks like | Schema pattern | Example |
|------------------------|---------------|---------|
| `{"intent": "billing", "score": 0.9}` | Flat fields | `string :intent; number :score` |
| `{"tags": ["ruby", "llm"]}` | Array of primitives | `array :tags do; string; end` |
| `{"groups": [{"who": "...", "tags": [...]}]}` | Array of objects | `array :groups do; object do; string :who; end; end` |

The schema tells the LLM provider **exactly** what JSON structure to return. Without `object do...end`, `array :groups do; string :who; end` tells the provider "groups is an array of strings" — and that's what you get back.

## Why schema alone is not enough

Schema validates **shape** — correct types, allowed values, field presence. But LLMs can return structurally valid JSON that is **logically wrong**. Validates catch what schema can't:

```ruby
output_schema do
  string :intent, enum: %w[sales support billing]
  number :confidence, minimum: 0.0, maximum: 1.0
end

# Schema says lang must be a string — but doesn't know what language you ASKED for.
validate("language must match requested") { |output, input| output[:lang] == input[:lang] }

# Schema says confidence is 0.0-1.0 — but can't express conditional logic.
validate("high confidence for extreme sentiments") do |o|
  next true if o[:intent] == "other"
  o[:confidence] >= 0.7
end
```

## Supported constraints

| Constraint | Types | Example |
|-----------|-------|---------|
| `enum` | string, integer | `string :status, enum: %w[active inactive]` |
| `minimum` / `maximum` | number, integer | `number :score, minimum: 0, maximum: 100` |
| `min_length` / `max_length` | string | `string :name, min_length: 1, max_length: 100` |
| `min_items` / `max_items` | array | `array :tags, min_items: 1, max_items: 10` |
| `additional_properties` | object | Set to `false` in schema to reject extra keys |

Keyword args use Ruby snake_case (`min_length`, `min_items`). The DSL converts them internally to JSON Schema's camelCase (`minLength`, `minItems`) before sending the schema to the provider — you do not need to write camelCase in Ruby.
