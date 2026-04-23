# Examples

Every example uses the same `SummarizeArticle` step from the [README](../README.md) — a Rails app turning article text into a UI card with TL;DR, takeaways, and a tone label. Files are numbered in reading order: 00 builds the step up layer by layer, then each subsequent file adds one capability to that same step.

Every example runs with the **Test adapter** (zero API keys). Only `01_real_llm.rb` needs a provider key.

## 00_basics.rb — From zero to full contract

Seven incremental layers of `SummarizeArticle`, each adding exactly one capability:

| Step | Adds | What it unlocks |
|------|------|-----------------|
| 1 | `prompt` + `output_schema` | JSON shape enforcement |
| 2 | `validate` | Business rules schema cannot express |
| 3 | Structured prompt (system, rule, section, user) | Reorderable, diffable prompt |
| 4 | Hash input | Multi-field interpolation |
| 5 | 2-arity `validate` | Cross-validate output against input |
| 6 | `retry_policy` | Automatic model fallback on validate fail |
| 7 | `Result` inspection | Status, parsed_output, per-attempt trace |

Read top to bottom, stop at the layer that matches your project.

## 01_real_llm.rb — Swap Test adapter for real LLM

Same `SummarizeArticle`, `Adapters::RubyLLM` instead of `Adapters::Test`. Shows provider configuration, model switching via context, and real trace data (latency, tokens, cost). Also illustrates cross-provider calls: OpenAI, Anthropic Claude, local Ollama — same step, different `model:` string.

**Requires:** `export OPENAI_API_KEY=sk-...` or another provider key (Anthropic, Gemini, Mistral), or a local Ollama server.

## 02_output_schema.rb — Schema patterns

Three schema patterns on `SummarizeArticle`: flat fields with constraints, nested objects in arrays (takeaway + confidence score for a UI confidence bar), and schema + cross-field `validate` for rules the shape cannot capture. Includes the pattern reference table.

## 03_summarize_with_keywords.rb — Growing the prompt

Marketing wants a "topic pills" row under the UI card. Instead of a second step, extend `SummarizeArticle` with a `keywords` field (array of `{text, probability}`). Demonstrates how the contract grows: prompt, schema, and validates in lockstep. Adds array-of-objects pattern, sorting rule, uniqueness rule, and cross-validation against the source article (hallucination catch).

Expected output:

```
Status:    ok
TL;DR:     Ruby 3.4 brings frozen string literals, YJIT speedups, parser fixes.
Tone:      analytical

Keywords (sorted by probability):
  0.95  ###################  Ruby 3.4
  0.9   ##################   frozen string literals
  0.85  #################    YJIT
  0.7   ##############       Rails workloads
  0.6   ############         parser fixes
```

## 04_summarize_and_translate.rb — Pipeline: summarize → translate → review

The UI card ships in English; the product launches in a French region. Rather than prompt the model to summarise directly in French (quality drops), split into three steps threaded by `Pipeline::Base`: English summary → translate to French → quality review. Each step uses a different LLM skill. Fail-fast: if the summary step fails, translate and review never run — no downstream tokens wasted.

Expected output:

```
Pipeline: ok
Final TL;DR (FR):  Ruby 3.4 arrive avec les littéraux de chaînes figés, ...
Review verdict:    pass
```

## 05_eval_dataset.rb — Dataset-driven evals

The workflow that stops silent prompt regressions. Define a dataset with expected outcomes, run it on the current config to establish a baseline, re-run after a change, block the merge on a score drop. Shows `define_eval`, `add_case`, `run_eval`, regression detection between a good and a bad adapter, and the inline `eval_case` helper.

Expected output:

```
Run 1 — good configuration (baseline)
  Score: 1.0, Pass rate: 3/3

Run 2 — a prompt tweak broke tone classification on complaints
  Score: 0.67, Pass rate: 2/3
    ✓ ruby release         all expected keys present and matching
    ✗ outage complaint     tone: expected "negative", got "analytical"
    ✓ product launch       all expected keys present and matching

Regression detected: 1.0 → 0.67 (33% drop)
```

## 06_fallback_showcase.rb — See contracts work in 30 seconds

The "why does this gem exist" demo. Part A runs a schema-only step and shows the flaky output shipping. Part B runs the full contract with `retry_policy` and shows the cross-field `validate` rejecting the flaky attempt and `retry_policy` escalating to the next model. Per-attempt trace printed inline.

Expected output — Part A (schema-only pain point):

```
status:        :ok            # schema passes — no guard
tone shipped:  "positive"
takeaway 1:    "Mesh networking hardware failed under load"
               ^^ takeaways describe a failure; tone says positive
               ^^ customer-success "critical feedback" filter misses this case
```

Expected output — Part B (full contract):

```
status:             :ok
final model:        "gpt-5-mini"
total attempts:     2

Per-attempt trace:
  attempt 1  model=gpt-5-nano   status=validation_failed
  attempt 2  model=gpt-5-mini   status=ok

Final parsed_output:
  tone:       "negative"
```

## 07_retry_variants.rb — Three retry_policy shapes

Beyond cross-model escalation (covered in 06). Each variant runs `SummarizeArticle` with the Test adapter so the trace is visible:

- **A. `attempts: 3`** — same model, sampling-variance absorption. Replaces the typical `begin/rescue/retry` loop.
- **B. `reasoning_effort` escalation** — low → medium → high on one model. Cheaper than model escalation when the model needs more thinking, not a stronger backbone.
- **C. Cross-provider fallback** — Ollama → Anthropic → OpenAI. Local first (costs nothing); hosted last (most accurate). Same DSL; ruby_llm resolves the provider from the model name.

Expected output (abridged):

```
A — attempts: 3 (same model, sampling-variance absorption)
    attempt 1  model=gpt-5-nano  status=validation_failed
    attempt 3  model=gpt-5-nano  status=ok

B — reasoning_effort escalation (low → medium → high)
    attempt 1  effort=low     status=validation_failed
    attempt 3  effort=high    status=ok

C — cross-provider fallback (Ollama → Anthropic → OpenAI)
    attempt 1  model=gemma3:4b          status=validation_failed
    attempt 3  model=gpt-5-nano         status=ok
```

## Running

```bash
# Test adapter — no API keys needed:
ruby examples/00_basics.rb
ruby examples/02_output_schema.rb
ruby examples/03_summarize_with_keywords.rb
ruby examples/04_summarize_and_translate.rb
ruby examples/05_eval_dataset.rb
ruby examples/06_fallback_showcase.rb
ruby examples/07_retry_variants.rb

# Real LLM — requires a provider API key or a local Ollama server:
ruby examples/01_real_llm.rb
```
