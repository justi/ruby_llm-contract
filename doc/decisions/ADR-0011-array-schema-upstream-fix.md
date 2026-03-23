---
id: ADR-0011
decision_type: adr
status: Proposed
created: 2026-03-23
summary: "Fix array-of-objects DSL in ruby_llm-schema — errorless data loss"
owners:
  - justi
---

# ADR-0011: Array Schema Upstream Fix

## Problem

`ruby_llm-schema` silently drops fields in array blocks:

```ruby
# User writes (intuitive):
array :questions do
  string :cta_label
  string :question
end
# Produces: {type: "array", items: {type: "string"}}
# Only FIRST string is kept. :question is silently lost.

# Correct (non-obvious):
array :questions do
  object do
    string :cta_label
    string :question
  end
end
```

Root cause: `determine_array_items` calls `collect_schemas_from_block.first` — takes first schema, discards rest. No warning.

## Impact

- **Errorless data loss** — schema validates against wrong structure, LLM returns wrong shape, user gets `validation_failed` with confusing message
- **Found in production** — persona_tool gate_question_generator migration
- **Blocks adoption** — every user with array-of-objects hits this

## Proposed fix (PR to ruby_llm-schema)

Option A (breaking): When block produces > 1 schema, auto-wrap in `object`:
```ruby
array :questions do
  string :cta_label    # produces object wrapper automatically
  string :question
end
```

Option B (safe): When block produces > 1 schema, raise ArgumentError:
```ruby
# ArgumentError: array block produced 2 schemas (string, string).
# Wrap in `object do...end` for array of objects.
```

**Recommendation: Option B.** Fail-fast is safer than magic. User gets clear error with fix instruction.

## Action items

1. Check ruby_llm-schema issues for existing report
2. PR with Option B + tests
3. If rejected, document workaround prominently in our README/output_schema.md (already done)
