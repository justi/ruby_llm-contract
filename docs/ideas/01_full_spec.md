# Prompt Contract — Full Technical Spec

## 0. Nazwa robocza

`ruby_llm-contract` (alias: `chain_guard`)

---

## 1. Cele systemowe (PRIMARY GOALS)

### G1. Deterministyczność pipeline
- ten sam input → powtarzalny wynik (w granicach LLM)
- pełna kontrola nad: promptem, kontekstem, parametrami

### G2. Izolacja kroków (anti-cascade failure)
- każdy step ma kontrakt i waliduje output
- brak "silent propagation"

### G3. Regression safety (CI-native)
- każda zmiana promptu testowana na datasetach i oceniana jakościowo
- ref: LLM eval frameworks wymagają systematycznego testowania (Helicone.ai)

### G4. Prompt jako asset (nie string)
- wersjonowanie, diff, audyt

### G5. Observability-by-default
- każdy krok: trace, replay, debug

---

## 2. Model mentalny (CORE ABSTRACTIONS)

### 2.1 Step (atom systemu)
```ruby
Step = {
  input_schema,
  output_schema,
  prompt_template,
  constraints,
  evaluator,
  retry_policy
}
```

### 2.2 Pipeline = DAG (nie chain)
Inspirowane: Prompt Flow DAG (Mirascope), AgentForge modular DAG (arXiv)
```ruby
Pipeline = DirectedAcyclicGraph<Step>
```

### 2.3 Execution context
```ruby
ExecutionContext = {
  model,
  temperature,
  top_p,
  tools,
  memory,
  metadata
}
```

---

## 3. Public API (DSL)

### 3.1 Step definition
```ruby
class ExtractEntities < RubyLLM::Contract::Step
  input  Types::String
  output Types::Array.of(Entity)

  prompt do |input|
    system "Extract entities"
    rule   "Return JSON only"
    user   input
  end

  contract do
    invariant "must be valid JSON"
    invariant "each entity has name"
  end

  evaluate do
    llm_judge "Are entities correctly extracted?"
  end
end
```

### 3.2 Pipeline
```ruby
class MyPipeline < RubyLLM::Contract::Pipeline
  step ExtractEntities
  step Normalize, depends_on: ExtractEntities
  step Classify,  depends_on: Normalize
end
```

### 3.3 Run
```ruby
pipeline.run(input, context: { model: "gpt-4.1-mini" })
```

---

## 4. CONTRACT SYSTEM (kluczowa innowacja)

### 4.1 Typy
- dry-struct / dry-types
```ruby
input  Types::String
output Types::Hash.schema(...)
```

### 4.2 Invariants
```ruby
contract do
  invariant "price >= 0"
  invariant "response length < 500"
end
```

### 4.3 Enforcement
- FAIL → retry / fallback / abort

---

## 5. TESTING SYSTEM

### 5.1 Dataset-first
```ruby
dataset "entity_extraction" do
  case input: "Apple is a company", expected: [...]
end
```

### 5.2 Snapshot testing
```ruby
expect(step.run(input)).to match_snapshot("v1")
```

### 5.3 Regression testing
Inspirowane PromptFoo — porównania outputów, scoring jakości (Comet)
```ruby
regression do
  compare old: v1, new: v2
  reject_if score_drop > 0.03
end
```

### 5.4 Multi-step eval
```ruby
evaluate_pipeline do
  step_score :extract
  step_score :normalize
end
```

---

## 6. PROMPT SYSTEM (AST, nie string)

### 6.1 Prompt AST
```ruby
prompt do
  system "..."
  rule   "..."
  example input: "...", output: "..."
  user   "{input}"
end
```

### 6.2 Immutability
Komponenty: SYSTEM, RULE, EXAMPLES, USER — nieedytowalne w runtime

### 6.3 Diffing
```ruby
prompt.diff(old, new)
```

---

## 7. TRACE & DEBUGGING

### 7.1 Trace schema
```ruby
Trace = {
  step,
  input,
  prompt,
  output,
  latency,
  tokens,
  cost
}
```

### 7.2 Replay
```ruby
trace.replay(run_id)
```

### 7.3 Diff runs
```ruby
trace.compare(run_a, run_b)
```

---

## 8. FAILURE HANDLING

### 8.1 Retry policy
```ruby
retry do
  attempts 3
  on_failure :format_error
end
```

### 8.2 Fallbacks
```ruby
fallback do
  prompt alternative_prompt
end
```

### 8.3 Guardrails
- JSON parser, regex, schema validation

---

## 9. EVALUATION ENGINE

### 9.1 LLM-as-judge
```ruby
evaluate do
  judge "Is output correct?"
end
```

### 9.2 Heurystyki
- exact match, regex, semantic similarity

### 9.3 Score aggregation
```ruby
score = weighted(step_scores)
```

---

## 10. PROMPT CHANGE SAFETY

### 10.1 Diff guard
```ruby
on_prompt_change do
  run_eval_dataset
  reject_if quality_drop > threshold
end
```

### 10.2 CI integration
```bash
ruby_llm-contract eval
```

---

## 11. ARCHITEKTURA GEMa
```
lib/
  ruby_llm-contract/
    step.rb
    pipeline.rb
    contract.rb
    prompt_ast.rb
    evaluator.rb
    tracer.rb
    dataset.rb
    regression.rb
    adapters/
      openai.rb
      anthropic.rb
```

---

## 12. INTEGRACJE
- langchainrb → provider layer
- ruby-openai → fallback
- dry-rb → types + validation

---

## 13. INSPIROWANE SYSTEMY
- **PromptFoo** → eval + regression
- **Mirascope** → code-first prompt design
- **DSPy** → pipeline jako graph + optymalizacja
- **Prompt Flow** → DAG orchestration

---

## 14. NON-GOALS
- ❌ agent framework (ReAct, tools, etc.)
- ❌ chat UI
- ❌ low-code builder

Budujesz: **"testable prompt pipeline system"**

---

## 15. USP (co wyróżnia)
1. Contract-first LLM pipeline (unikalne)
2. Step-level eval (nie tylko end-to-end)
3. Prompt immutability
4. Built-in regression gating
5. DAG zamiast chain

---

## Final insight

> **"RSpec + ActiveModel + Airflow dla promptów"**
