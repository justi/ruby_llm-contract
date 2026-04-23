# Examples

Seven runnable examples, every one using the `SummarizeArticle` step from the [README](../README.md) — a Rails app turning article text into a UI card with TL;DR, takeaways, and tone. Zero API keys (Test adapter is the default). Only `02_real_llm_minimal.rb` needs a provider key.

Pedagogical order: hook → activation → evolution → composition → quality → advanced.

| # | File | Answers |
|---|------|---------|
| 00 | `00_basics.rb` | **"How do I start?"** — seven incremental layers: plain prompt → output_schema → validate → structured prompt → Hash input → cross-input validate → retry_policy → trace inspection, plus real-LLM swap pointer. |
| 01 | `01_fallback_showcase.rb` | **"Show me the gem in 30 seconds."** — Part A: schema-only ships a flaky sample. Part B: full contract rejects it and retry_policy escalates to the next model. Per-attempt trace printed inline. |
| 02 | `02_real_llm_minimal.rb` | **"How do I plug in a real LLM?"** — ~30 lines. `Adapters::RubyLLM.new` in context, same step. Also shows per-call provider switch (OpenAI → Anthropic → Ollama). |
| 03 | `03_summarize_with_keywords.rb` | **"How does the contract evolve when the product grows?"** — marketing wants a "topic pills" row, so `SummarizeArticle` gains a keywords field with probability and cross-validation. Prompt, schema, and validates stay in lockstep. |
| 04 | `04_summarize_and_translate.rb` | **"How do steps compose into a pipeline?"** — 3 steps threaded by `Pipeline::Base`: English summary → translate to French → quality review. Fail-fast: a rejected summary means translate and review never run. |
| 05 | `05_eval_dataset.rb` | **"How do I stop silent prompt regressions?"** — define_eval with real cases, baseline vs regressed adapter, regression detection signal, inline eval_case. |
| 06 | `06_retry_variants.rb` | **"What retry shapes exist beyond cross-model?"** — `attempts: 3` (variance absorption), `reasoning_effort` escalation (low→medium→high), cross-provider fallback (Ollama → Anthropic → OpenAI). |

Every example has an "Expected output" section in the file header — you can read what each one prints without running it.

## Running

```bash
# Test adapter — no API keys needed:
ruby examples/00_basics.rb
ruby examples/01_fallback_showcase.rb
ruby examples/03_summarize_with_keywords.rb
ruby examples/04_summarize_and_translate.rb
ruby examples/05_eval_dataset.rb
ruby examples/06_retry_variants.rb

# Real LLM — requires a provider API key or a local Ollama server:
ruby examples/02_real_llm_minimal.rb
```
