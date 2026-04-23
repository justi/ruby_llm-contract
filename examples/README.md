# Examples

Five runnable examples, every one using the `SummarizeArticle` step from the [README](../README.md) — a Rails app turning article text into a UI card with TL;DR, takeaways, and tone. Zero API keys (Test adapter is the default).

Each file maps to a concrete adoption question. Open the one that matches yours.

| # | File | Answers |
|---|------|---------|
| 00 | `00_basics.rb` | **"How do I start?"** — seven incremental layers: plain prompt → output_schema → validate → structured prompt → Hash input → cross-input validate → retry_policy → trace inspection → swap Test adapter for a real LLM. |
| 01 | `01_summarize_with_keywords.rb` | **"How does the contract evolve when the product grows?"** — marketing wants a "topic pills" row, so `SummarizeArticle` gains a keywords field with probability and cross-validation. Shows prompt, schema, and validates staying in lockstep. |
| 02 | `02_eval_dataset.rb` | **"How do I stop silent prompt regressions?"** — define_eval with real cases, baseline vs regressed adapter, the regression detection signal, inline eval_case. |
| 03 | `03_fallback_showcase.rb` | **"Show me the gem in 30 seconds."** — Part A: schema-only ships a flaky sample. Part B: full contract rejects it and retry_policy escalates to the next model. Per-attempt trace printed inline. |
| 04 | `04_retry_variants.rb` | **"What retry shapes exist beyond cross-model?"** — `attempts: 3` (variance absorption), `reasoning_effort` escalation (low→medium→high), cross-provider fallback (Ollama → Anthropic → OpenAI). |

Every example has an "Expected output" section in the file header — you can read what each one prints without running it.

## Running

```bash
ruby examples/00_basics.rb
ruby examples/01_summarize_with_keywords.rb
ruby examples/02_eval_dataset.rb
ruby examples/03_fallback_showcase.rb
ruby examples/04_retry_variants.rb
```

## Schema patterns and pipeline composition

Dropped as standalone examples because the guides cover them in depth:

- Schema patterns (flat, nested objects, enums, constraints) — see [Output Schema guide](../docs/guide/output_schema.md).
- Pipeline composition (multi-step, fail-fast, per-step models) — see [Pipeline guide](../docs/guide/pipeline.md).

## Real LLM

Point `ruby_llm` at your provider (OpenAI, Anthropic, Gemini, a local Ollama server) and swap `Adapters::Test` for `Adapters::RubyLLM`. See the final layer of `00_basics.rb` for the one-liner and the [Getting Started guide](../docs/guide/getting_started.md) for end-to-end configuration.
