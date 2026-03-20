# Examples

## 00_basics.rb — From zero to ruby_llm-contract

Step-by-step tutorial covering every feature. Start here.

| Step | Feature | What it shows |
|------|---------|---------------|
| 1 | Plain string prompt | Simplest case — `user "{input}"` and nothing else |
| 2 | System + user | Separate instructions from data |
| 3 | Rules + output_schema | Requirements as statements + declarative output structure |
| 4 | Invariants | Custom business logic on top of schema |
| 5 | Examples | Few-shot (example input/output pairs) |
| 6 | Sections | Labeled context blocks (heredoc replacement, with before/after) |
| 7 | Hash input | Multiple fields with auto-interpolation |
| 8 | 2-arity invariants | Cross-validate output against input |
| 9 | Context override | Per-run adapter and model switching |
| 10 | StepResult | Full inspection: status, output, errors, trace |
| 11 | Pipeline | Chain steps with fail-fast data threading |

Every step has a corresponding test in `spec/integration/examples_00_basics_spec.rb`.

## 01_classify_threads.rb — Thread classification

Real-world before/after: classify Reddit threads as PROMO/FILLER/SKIP.
Shows ID matching, enum validation, score consistency invariants.

## 02_generate_comment.rb — Comment generation

Real-world before/after: generate Reddit comments with persona.
Shows sections, banned openings, link presence, length constraints, 2-arity invariants.

## 03_target_audience.rb — Audience profiling

Real-world before/after: generate target audience profiles.
Shows cascade failure prevention, locale validation, structural invariants.

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

Replace manual invariants with a schema DSL (ruby_llm-schema).

| Step | Feature | What it shows |
|------|---------|---------------|
| 1 | Before (invariants) | Manual enum, range, required checks |
| 2 | After (schema) | Same constraints in declarative DSL |
| 3 | Schema + invariants | Schema for structure, invariants for business logic |
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

## 06_reddit_promo.rb — Real-world Reddit promo pipeline

3-step pipeline from the reddit_promo_planner case study:

| Step | Role | Invariants catch |
|------|------|------------------|
| 1 | TargetAudience | `locale: "USA"` instead of `"en"`, vague summary |
| 2 | ClassifyThreads | PROMO with score 2, SKIP with score 8 |
| 3 | GenerateComment | `{PRODUCT}` instead of URL, banned openings |

Runs with test adapter by default. `REAL_LLM=1` for Ollama, `MODEL=gemma:latest` to pick model.

## 07_keyword_extraction.rb — Keyword extraction with probability

Extract up to 15 keywords from an article, each with relevance probability.

| Feature | What it shows |
|---------|---------------|
| Array schema | `min_items: 1, max_items: 15` with nested objects |
| Number range | `probability: 0.0–1.0` |
| Sorting invariant | Schema can't express "sorted descending" |
| Uniqueness invariant | Schema can't express "no duplicates" |
| Cross-validation | Keywords must appear in source text (catches hallucination) |
| Pipeline | Keywords → Related Topics |

## 08_translation.rb — Translation pipeline with quality review

3-step pipeline: extract segments → translate → review quality.

| Step | LLM Skill | Invariants catch |
|------|-----------|------------------|
| Extract | Analysis | Duplicate keys, wrong target_lang |
| Translate | Creative | Missing segments, too long, echoed back untranslated |
| Review | Evaluation | Inconsistent counts, failed reviews without issues |

## Running

```bash
# Test adapter — no API keys needed:
ruby examples/00_basics.rb
ruby examples/01_classify_threads.rb
ruby examples/02_generate_comment.rb
ruby examples/03_target_audience.rb
ruby examples/05_output_schema.rb
ruby examples/06_reddit_promo.rb
ruby examples/07_keyword_extraction.rb
ruby examples/08_translation.rb

# Real LLM — requires Ollama or API key:
ruby examples/04_real_llm.rb
REAL_LLM=1 ruby examples/06_reddit_promo.rb
REAL_LLM=1 MODEL=llama3.2:3b ruby examples/06_reddit_promo.rb
```

Examples 00–03, 05–06 use the test adapter by default — no API keys needed.
Example 04 and 06 with `REAL_LLM=1` require Ollama or an API key.
