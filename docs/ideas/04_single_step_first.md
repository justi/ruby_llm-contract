# Single-Step First — nadrzędna zasada projektowa

## Kluczowy warunek powodzenia

Jeśli gem jest użyteczny dopiero przy chainie → próg wejścia za wysoki, adopcja słaba, ludzie uznają "framework enterprise do rzeczy, których jeszcze nie mam".

**Musi działać już dla: "mam jeden prompt, chcę mieć nad nim kontrolę, testy i spokój przy zmianach".**

Single prompt = first-class use case. Pipeline/DAG = warstwa wyżej.

---

## Model mentalny

NIE: podstawowa jednostka = pipeline
TAK: podstawowa jednostka = **PromptStep**, pipeline = kompozycja wielu stepów

Nawet z jednym promptem user dostaje pełną wartość:
typed input/output, prompt definition, contract, trace, eval dataset, regression check.

---

## Minimalny use case który musi być świetny

```ruby
class ClassifyIntent < RubyLLM::Contract::Step::Base
  input_type  Types::String
  output_type Types::Hash

  prompt do
    system "Classify the user's intent."
    rule   "Return JSON only."
    rule   "Allowed intents: sales, support, billing."
    user   "{input}"
  end

  contract do
    parse :json

    invariant("must include intent") do |output|
      output["intent"].to_s != ""
    end

    invariant("intent must be allowed") do |output|
      %w[sales support billing].include?(output["intent"])
    end
  end
end

result = ClassifyIntent.run(
  "I want to change my invoice details",
  context: { model: "gpt-4.1-mini", temperature: 0.0 }
)
```

---

## Co user zyskuje nawet przy jednym promcie

### 1. Prompt przestaje być stringiem w kodzie
Zdefiniowany asset — wersjonowalny, czytelny, testowalny.

### 2. Output ma kontrakt
Zamiast "czasem zwraca dziwny JSON" → parser, invariants, czytelny failure mode.

### 3. Zmiana promptu nie jest ruletką
Dataset → czy nowa wersja poprawia jakość, czy nie zepsuła starych przypadków.

### 4. Trace i replay
Co dokładnie wysłaliśmy, co model zwrócił, dlaczego kontrakt padł.

---

## Hierarchia poziomów

### Poziom 1 — Step (produkt bazowy)
### Poziom 2 — PromptSet / Dataset / Eval (bezpieczeństwo zmian)
### Poziom 3 — Pipeline (kompozycja stepów)

Nie odwrotnie.

---

## Co to zmienia w API

Promować najpierw:
```ruby
MyPrompt.run(...)
MyPrompt.eval(...)
MyPrompt.trace(...)
```

Pipeline jest dopiero rozszerzeniem.

---

## Naming

Jeśli centralnym use case jest też single prompt, `Pipeline` nie może dominować przekazu.

- `Step` / `PromptStep` = podstawowa jednostka
- `Workflow` / `Pipeline` = opcjonalna kompozycja

Inaczej user z jednym promptem pomyśli "to nie dla mnie".

---

## MVP dla single prompt

### Musi być:
- `Step::Base`
- prompt DSL / AST
- input/output contract
- parser
- invariants
- `run`
- trace
- dataset eval
- snapshot / baseline compare

### Niepotrzebne na start:
- DAG
- dependency graph
- parallel execution
- cross-step scoring

---

## Entry pointy gema

```ruby
RubyLLM::Contract::Step      # ← start tutaj
RubyLLM::Contract::Eval
RubyLLM::Contract::Pipeline  # ← dopiero potem
```

README zaczyna od `Step`, nie od `Pipeline`.

---

## Value proposition

NIE: "framework do budowy multi-step pipelines"
TAK: "bezpieczny, testowalny sposób definiowania promptów i składania ich w pipeline'y, gdy ich potrzebujesz"

---

## Test produktu

Ktoś ma jeden prompt do klasyfikacji/ekstrakcji/routing/generowania.
Powinien pomyśleć: "to mi daje porządek, testy i regresję bez overengineeringu"
NIE: "fajne, ale za ciężkie jak na mój przypadek"

---

## Zasada

**Single-step first, pipeline second.**
