# Prompt Contract — Expanded Spec, Risks & MVP Plan

## 1. Ocena specyfikacji — co jest mocne

### Contract-first
Centralna przewaga. Step ma wejście, wyjście, invariants i enforcement.
Zmienia prompt z "stringa z magicznym zachowaniem" na coś bliższego service object / policy object / typed boundary.

### Step-level eval zamiast end-to-end
W realnych pipeline'ach końcowy błąd często jest skutkiem psucia się kroku 1 albo 2, ale end-to-end tego nie lokalizuje.

### Prompt AST
Ważniejsze niż wygląda — bez tego nie ma sensownego diffu, immutability ani audytu zmian.

### DAG zamiast linear chain
Dobra decyzja, o ile nie przesadzić z orkiestracją w v0.1. Na początku prosty topological execution bez pełnego "workflow engine".

### CI-native regression gating
Coś za co zespoły realnie płacą. Bez tego prompt engineering kończy się na "wydaje się lepiej".

---

## 2. Główne ryzyka architektoniczne

### R1. Zbyt szerokie "evaluation"
Rozdzielić na osobne warstwy:
- `Validator` → czy output jest formalnie poprawny
- `Evaluator` → czy output jest jakościowo dobry
- `Regression` → czy nowa wersja pogorszyła wynik względem baseline
- `Gate` → czy build ma przejść

### R2. "Deterministyczność" jako obietnica absolutna
Realnie zapewniamy:
- deterministyczność konfiguracji, prompt assembly, danych wejściowych
- powtarzalność śladu wykonania, możliwość replay
- **NIE** pełną deterministyczność modelu zamkniętego API

W kodzie używać: `reproducibility`, `execution reproducibility`, `config determinism`

### R3. Za dużo DSL naraz
Najpierw jawne makra klasowe, prosty execution engine, prosty prompt builder. Dopiero potem syntactic sugar.

### R4. Za dużo w pierwszej wersji
DAG + retry + fallback + eval + tracing to za dużo jako jeden release.

---

## 3. Granice produktu

### Co gem powinien być
Frameworkiem do budowy testowalnych, kontraktowych kroków LLM i prostych pipeline'ów.

### Czego NIE powinien robić w v0.1
- orchestration distributed / background jobs
- agent loops
- tool calling framework
- memory framework
- vector/RAG stack
- auto-optimization promptów
- UI
- observability backend jako SaaS

---

## 4. Rekomendowany model domenowy

### 4.1 Step definition — rozdzielone odpowiedzialności
- `StepDefinition` → co to jest za krok (name, input_type, output_type, prompt_definition, validators)
- `ExecutionPolicy` → jak go wykonywać (retry, fallback, timeout)
- `EvaluationProfile` → jak go oceniać w testach (judge, scoring)

To pozwoli odpalać ten sam step: w runtime produkcyjnym bez judge'a, w eval mode z judge'em, w CI z regresją.

### 4.2 StepResult
```ruby
StepResult = {
  status,        # :ok, :validation_failed, :model_error, :aborted
  raw_output,
  parsed_output,
  validation_errors,
  attempts,
  trace_id,
  metadata
}
```

### 4.3 PipelineResult
```ruby
PipelineResult = {
  status,
  step_results,
  outputs_by_step,
  started_at,
  finished_at,
  trace_id
}
```

---

## 5. MVP Plan

### v0.1 — musi umieć
1. **Definicja Step** — input type, output type, prompt builder, basic validator, provider adapter, structured result
2. **Linear pipeline** — step list, depends_on do walidacji topologii, wykonanie sekwencyjne
3. **Contract enforcement** — type coercion/validation inputu, parse output, validate invariants, fail fast
4. **Trace** — prompt finalny, raw output, parsed output, latency, token usage
5. **Dataset-based eval** — cases z input/expected, evaluator exact/regex/custom proc, CLI
6. **Snapshot / baseline** — zapis JSON wyników, porównanie baseline vs current

### v0.2
- retry policy, fallback prompt, prompt diff, lepszy regression score

### v0.3
- prawdziwy DAG, partial recomputation, parallel execution niezależnych node'ów

### v1.0
- step-level + pipeline-level eval profiles, CI gating, richer tracing / replay, multi-provider parity

---

## 6. Proponowana architektura katalogów

```text
lib/
  ruby_llm-contract.rb
  ruby_llm-contract/
    types.rb
    error.rb
    version.rb

    step/
      base.rb
      definition.rb
      result.rb
      runner.rb

    pipeline/
      base.rb
      definition.rb
      result.rb
      runner.rb
      graph.rb

    prompt/
      ast.rb
      builder.rb
      nodes.rb
      renderer.rb
      diff.rb

    contract/
      schema.rb
      invariant.rb
      validator.rb
      output_parser.rb

    eval/
      dataset.rb
      case.rb
      runner.rb
      result.rb
      evaluators/
        exact_match.rb
        regex.rb
        json_semantic.rb
        llm_judge.rb

    regression/
      baseline.rb
      comparer.rb
      gate.rb

    trace/
      span.rb
      store.rb
      replay.rb

    adapters/
      base.rb
      openai.rb
      anthropic.rb

    cli/
      eval_command.rb
      trace_command.rb
```

---

## 7. Kluczowe decyzje implementacyjne

### 7.1 Typy: dry-types ostrożnie
- input/output contract jako dry-types
- parsed output może być zwykłym Hash/Array
- Dwa poziomy: shape validation + opcjonalnie domain object mapping

### 7.2 Prompt AST — deterministycznie renderowalny
Każdy node: typ, payload, stable serialization
```ruby
[
  { type: :system, text: "Extract entities" },
  { type: :rule, text: "Return JSON only" },
  { type: :user, template: "{input}" }
]
```
Umożliwia: diff, hash promptu, snapshot, audit.

### 7.3 Provider adapter — zunifikowany response
```ruby
ModelResponse = Struct.new(
  :content, :raw, :usage, :finish_reason, :model, :provider,
  keyword_init: true
)
```

### 7.4 Invariants jako callable, nie tylko string
```ruby
contract do
  invariant "must be valid JSON"
  invariant("price >= 0") { |output| output["price"] >= 0 }
end
```
Opis dla trace/debug, blok dla wykonania.

---

## 8. Rekomendowany DSL

### Step
```ruby
class ExtractEntities < RubyLLM::Contract::Step::Base
  input_type  Types::String
  output_type Types::Array.of(Types::Hash)

  prompt do
    system "Extract named entities from the user text."
    rule   "Return JSON only."
    rule   "Each entity must include a name and type."
    user   "{input}"
  end

  contract do
    parse :json

    invariant("output must be an array") do |output|
      output.is_a?(Array)
    end

    invariant("each entity must include name") do |output|
      output.all? { |e| e["name"].to_s.strip != "" }
    end
  end
end
```

### Pipeline
```ruby
class EntityPipeline < RubyLLM::Contract::Pipeline::Base
  step ExtractEntities, as: :extract
  step NormalizeEntities, as: :normalize, depends_on: :extract
  step ClassifyEntities, as: :classify, depends_on: :normalize
end
```

### Run
```ruby
result = EntityPipeline.run(
  "Apple acquired Beats",
  context: { model: "gpt-4.1-mini", temperature: 0.0 }
)
result.outputs_by_step[:classify]
```

---

## 9. Runtime flow (od początku)

```text
1. validate input
2. build prompt AST
3. render prompt
4. call adapter
5. capture raw output
6. parse output
7. validate schema
8. validate invariants
9. return StepResult
```

Jeśli walidacja pada: status != ok, pełen trace zachowany, retry/fallback dopiero jako policy layer.

---

## 10. Trace format

```json
{
  "trace_id": "trc_123",
  "run_id": "run_456",
  "step": "ExtractEntities",
  "input": "Apple acquired Beats",
  "rendered_prompt": [...],
  "rendered_prompt_text": "...",
  "raw_output": "...",
  "parsed_output": [...],
  "validation": { "passed": true, "errors": [] },
  "model": "gpt-4.1-mini",
  "provider": "openai",
  "temperature": 0.0,
  "usage": { "input_tokens": 120, "output_tokens": 48 },
  "latency_ms": 982
}
```

---

## 11. Evaluation engine — protokół

```ruby
class Evaluator
  def call(output:, expected:, context:); end
end

EvaluationResult = Struct.new(:score, :passed, :label, :details, keyword_init: true)
```

Minimalny zestaw: ExactMatch, RegexMatch, JsonIncludes, ProcEvaluator, LlmJudge (opcjonalny).

---

## 12. Regression model

### Baseline — zapis wyników eval datasetu
```json
{
  "dataset": "entity_extraction",
  "version": "v1",
  "cases": [{ "id": "case_1", "score": 1.0, "output": [...] }],
  "aggregate_score": 0.94
}
```

### Compare — zwraca: aggregate delta, case deltas, newly failing cases
Fail jeśli aggregate_score spada o więcej niż threshold lub liczba failed cases rośnie powyżej limitu.

---

## 13. CLI — minimum

```bash
ruby_llm-contract eval path/to/dataset.rb
ruby_llm-contract baseline:update path/to/dataset.rb
ruby_llm-contract trace:show trace_id
```

---

## 14. RSpec integration

```ruby
RSpec.describe ExtractEntities do
  it "matches entity extraction baseline" do
    result = described_class.run("Apple acquired Beats", context: test_context)
    expect(result.parsed_output).to satisfy_contract
  end
end
```

Matchery: `satisfy_contract`, `pass_eval`, `match_baseline`

---

## 15. Co wyciąć z pierwszego release
- pełny DAG executor z równoległością
- LLM judge jako domyślny evaluator
- prompt fallback trees
- automatyczne threshold tuning
- memory/tool abstractions
- fancy observability backend

---

## 16. Ważne rozróżnienie: Definition-time vs Run-time

### Definition-time
step class, input/output types, prompt AST, invariants, evaluator profile

### Run-time
model, temperature, metadata, trace store, retry policy override

Jawnie opisać, żeby użytkownicy nie mieszali kontraktu domenowego z polityką wykonania i konfiguracją środowiska.

---

## 17. Prompt immutability — doprecyzowanie

Lepiej: **definition immutability at execution time**

Prompt może być wersjonowany i zmieniany między release'ami, ale w trakcie jednego uruchomienia, po zbudowaniu stepu, po zapisaniu trace — musi być niezmienny.

---

## 18. One-liner

> Define LLM steps with typed contracts, run them in reproducible pipelines, and protect prompt changes with evals and regression checks.

---

## 19. Rekomendowana kolejność implementacji

1. `Prompt::AST` + renderer
2. `Step::Base` + input/output contract
3. adapter OpenAI
4. parser + invariants
5. `StepResult` + trace zapis
6. `Pipeline::Base` sekwencyjny
7. dataset + basic evaluators
8. baseline compare
9. CLI
10. retry/fallback
