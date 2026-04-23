# Examples

## 00_basics.rb — From zero to ruby_llm-contract

Step-by-step tutorial covering every feature. Start here.

| Step | Feature | What it shows |
|------|---------|---------------|
| 1 | Plain string prompt | Simplest case — `user "{input}"` and nothing else |
| 2 | System + user | Separate instructions from data |
| 3 | Rules + output_schema | Requirements as statements + declarative output structure |
| 4 | Validate blocks | Custom business logic on top of schema |
| 5 | Examples | Few-shot (example input/output pairs) |
| 6 | Sections | Labeled context blocks (heredoc replacement, with before/after) |
| 7 | Hash input | Multiple fields with auto-interpolation |
| 8 | 2-arity validates | Cross-validate output against input |
| 9 | Context override | Per-run adapter and model switching |
| 10 | StepResult | Full inspection: status, output, errors, trace |
| 11 | Pipeline | Chain steps with fail-fast data threading |

Every step has a corresponding test in `spec/integration/examples_00_basics_spec.rb`.

## 01_classify_threads.rb — Thread classification

Real-world before/after: classify Reddit threads as PROMO/FILLER/SKIP.
Shows ID matching, enum validation, score consistency validates.

## 02_generate_comment.rb — Comment generation

Real-world before/after: generate Reddit comments with persona.
Shows sections, banned openings, link presence, length constraints, 2-arity validates.

## 03_target_audience.rb — Audience profiling

Real-world before/after: generate target audience profiles.
Shows cascade failure prevention, locale validation, cross-field validates.

## 04_real_llm.rb — Real LLM calls via ruby_llm

Connect to real LLM providers (OpenAI, Anthropic, Google, etc.) using Adapters::RubyLLM.
Shows configuration, model switching, temperature/max_tokens control, provider-agnostic steps.

| Step | Feature | What it shows |
|------|---------|---------------|
| 1 | Configure ruby_llm | Set API keys for your provider |
| 2 | Set RubyLLM adapter | Swap Test adapter for production |
| 3 | Define a step | Identical to Test adapter — provider-agnostic |
| 4 | Run with real LLM | Real call, real tokens, full contract enforcement |
| 5 | Compare models | A/B test different models per call |
| 6 | Generation params | Temperature, max_tokens forwarding |
| 7 | Switch providers | Same step, different provider — just change model name |
| 8 | Error handling | Contract enforcement with real LLM responses |
| 9 | Full power | Every feature combined in AnalyzeTicket |
| 10 | Pipeline | Chain steps with real LLM calls |

**Requires:** `export OPENAI_API_KEY=sk-...` (or another provider key)

## 05_output_schema.rb — Declarative output schema

Replace manual validate blocks with a schema DSL (ruby_llm-schema).

| Step | Feature | What it shows |
|------|---------|---------------|
| 1 | Before (validates) | Manual enum, range, required checks |
| 2 | After (schema) | Same constraints in declarative DSL |
| 3 | Schema + validates | Schema for structure, validates for business logic |
| 4 | Complex schema | Nested objects, arrays, constraints |
| 5 | Provider-agnostic | Same schema works with Test and RubyLLM adapters |
| 6 | Pipeline + schemas | Fully typed multi-step composition |

## Running

```bash
# Test adapter — no API keys needed:
ruby examples/00_basics.rb
ruby examples/01_classify_threads.rb
ruby examples/02_generate_comment.rb
ruby examples/03_target_audience.rb
ruby examples/05_output_schema.rb

# Real LLM — requires API key:
ruby examples/04_real_llm.rb
```

## 07_keyword_extraction.rb — Keyword extraction with probability

Extract up to 15 keywords from an article, each with relevance probability.

| Feature | What it shows |
|---------|---------------|
| Array schema | `min_items: 1, max_items: 15` with nested objects |
| Number range | `probability: 0.0–1.0` |
| Sort validate | Schema can't express "sorted descending" |
| Uniqueness validate | Schema can't express "no duplicates" |
| Cross-validation | Keywords must appear in source text (catches hallucination) |
| Pipeline | Keywords → Related Topics |

## 08_translation.rb — Translation pipeline with quality review

3-step pipeline: extract segments → translate → review quality.

| Step | LLM Skill | Validates catch |
|------|-----------|------------------|
| Extract | Analysis | Duplicate keys, wrong target_lang |
| Translate | Creative | Missing segments, too long, echoed back untranslated |
| Review | Evaluation | Inconsistent counts, failed reviews without issues |

## 09_eval_dataset.rb — Dataset-driven eval workflow

Shows `define_eval` + `add_case` + `compare_models` end-to-end against a small hand-curated dataset.

## 10_reddit_full_showcase.rb — Full showcase across the gem

Multi-step pipeline exercising schema, validates, retry with fallback, evals, and baseline regression detection on a single realistic case.

## 11_fallback_showcase.rb — See contracts work in 30 seconds

The shortest possible "why does this gem exist" demo, runnable with zero API keys. Uses the Test adapter to simulate output variance from gpt-5-nano (where `temperature=1.0` is server-enforced and the same prompt can produce a tone label that contradicts the takeaways). Watches the contract reject the flaky sample via a cross-field validate, then shows `retry_policy` escalating to gpt-5-mini — with the per-attempt trace printed. Start here if you want to feel the fallback loop before reading docs.

Expected output (Part B, after the schema-only pain point in Part A):

```
attempt 1  model=gpt-5-nano   status=validation_failed
attempt 2  model=gpt-5-mini   status=ok

Final parsed_output:
  tone:       "negative"
```

## 12_retry_variants.rb — Three other retry_policy shapes, runnable

Covers the three patterns example 11 does not: `attempts: 3` on the same model (sampling-variance absorption, replaces the typical `begin/rescue/retry` loop), `reasoning_effort` escalation (low → medium → high on one model), and cross-provider fallback (Ollama → Anthropic → OpenAI; local first because it costs nothing, hosted last because it is the most accurate). Zero API keys — every variant runs through the Test adapter so you see the trace without configuring providers.

Expected output (abridged — each variant ends at attempt 3 = ok):

```
A — attempts: 3 (same model, sampling-variance absorption)
    attempt 1  model=gpt-5-nano  status=validation_failed
    attempt 3  model=gpt-5-nano  status=ok

B — reasoning_effort escalation (low → medium → high)
    attempt 1  effort=low     status=validation_failed
    attempt 3  effort=high    status=ok

C — cross-provider fallback (Ollama → Anthropic → OpenAI)
    attempt 1  model=gemma3:4b         status=validation_failed
    attempt 3  model=gpt-5-nano        status=ok
```

## Running

```bash
# Test adapter — no API keys needed:
ruby examples/00_basics.rb
ruby examples/01_classify_threads.rb
ruby examples/02_generate_comment.rb
ruby examples/03_target_audience.rb
ruby examples/05_output_schema.rb
ruby examples/07_keyword_extraction.rb
ruby examples/08_translation.rb
ruby examples/09_eval_dataset.rb
ruby examples/10_reddit_full_showcase.rb
ruby examples/11_fallback_showcase.rb
ruby examples/12_retry_variants.rb

# Real LLM — requires a provider API key (OpenAI, Anthropic, Gemini, etc.)
# or a local Ollama server (no key needed):
ruby examples/04_real_llm.rb
```

Examples 00–03, 05, 07–12 use the test adapter by default — no API keys needed.
Example 04 needs a real backend: either a provider API key or a local Ollama instance.
