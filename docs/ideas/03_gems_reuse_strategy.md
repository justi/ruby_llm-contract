# Gems Reuse Strategy

## 1. langchainrb

### Reuse
- Provider abstraction (fallback adapter layer, szybkie wsparcie wielu modeli)
- Evaluations — inspiracja API, naming, baseline "co użytkownicy rozumieją jako eval"
- Logging/tracing — quick win zanim własny tracer

### NIE brać
- Chains / Agents / Tools — dynamiczny, nie-deterministyczny, bez kontraktów (sprzeczne z G1–G3)
- Prompt abstractions — stringowe, brak AST, brak immutability

### Rola: "opcjonalny provider backend / adapter" — nie core

---

## 2. ruby_llm (najważniejszy kandydat)

### Reuse
- **Provider layer** — multi-provider, spójne API, aktywnie rozwijany → idealny jako `Adapters::RubyLLMAdapter`
- **Structured output support** — JSON/structured outputs, walidacje → pierwszy parser outputu
- **Async / streaming** — na przyszłość: parallel steps w DAG, streaming
- **Rails integration** — DX, łatwe wejście do Rails ekosystemu

### NIE brać
- Flow / orchestration — ruby_llm nie jest pipeline engine ani contract system
- Evaluation / regression — nie ma tego na potrzebnym poziomie

### Rola: "domyślny adapter modelu (runtime engine)" — **primary dependency**

---

## 3. openai-ruby

### Reuse
- **Structured Outputs** — schema enforcement po stronie modelu, mniej parsowania, większa deterministyczność → fast path dla contract enforcement
- **Niski poziom kontroli** — dokładna kontrola parametrów, raw response, usage tokens → trace, reproducibility
- **Stabilność SDK** — oficjalne, dobrze utrzymywane

### NIE brać
- Logika pipeline — nie istnieje
- Eval / testing / contracts — nie istnieje

### Rola: "low-level adapter / fallback provider / advanced mode"

---

## 4. dry-rb (dry-types, dry-validation) — FUNDAMENT

### Reuse
- **Typy (must-have)**: `Types::String`, `Types::Array.of(...)`, `Types::Hash.schema(...)` → input/output contract, coercion, shape validation
- **Validation rules** — custom rules, constraint logic → podpięcie pod invariants
- **Error system** — strukturalne błędy, czytelne komunikaty

### NIE brać
- Dry-struct jako obowiązkowy model outputu — za ciężkie, za sztywne → opcja, nie default

### Rola: "engine kontraktów i walidacji" — **core dependency**

---

## 5. Architektura warstw

### Warstwa 1: Core (build yourself)
Step, Pipeline, Prompt AST, Contract system, Trace, Eval, Regression

### Warstwa 2: Dependencies
```
ruby_llm-contract
 ├── ruby_llm        (primary adapter)
 ├── openai-ruby     (optional low-level adapter)
 └── dry-rb          (contracts + validation)
```

### Warstwa 3: Adaptery
```ruby
Adapters::Base
Adapters::RubyLLM
Adapters::OpenAI
Adapters::Anthropic  # future
```

---

## 6. Reuse vs Build

### REUSE
| Obszar             | Gem            | Co dokładnie            |
|--------------------|----------------|-------------------------|
| Provider API       | ruby_llm       | call model, params      |
| Structured outputs | openai-ruby    | JSON schema enforcement |
| Types              | dry-types      | input/output            |
| Validation         | dry-validation | invariants              |
| Multi-provider     | ruby_llm       | routing                 |

### BUILD YOURSELF
| Obszar            | Dlaczego                 |
|-------------------|--------------------------|
| Step abstraction  | core value               |
| Prompt AST        | brak w ekosystemie       |
| Contract system   | kluczowy USP             |
| Pipeline engine   | DAG + determinism        |
| Trace system      | potrzebny do debug       |
| Eval engine       | brak sensownego w Ruby   |
| Regression system | praktycznie nie istnieje |

---

## 7. Strategia

### Start
- ruby_llm jako default adapter
- dry-rb jako contracts
- własny Step + Pipeline + Prompt AST

### Dodaj później
- openai-ruby dla strict mode
- fallback adaptery

### NIE rób
- tight coupling do langchainrb
- dependency na agent frameworks

---

## 8. Kluczowy insight

Obecne gemy są poziom niżej (SDK, provider) albo poziom szerzej (framework aplikacyjny).
Ten gem celuje w: **vertical slice — reliability layer dla LLM pipeline**.
